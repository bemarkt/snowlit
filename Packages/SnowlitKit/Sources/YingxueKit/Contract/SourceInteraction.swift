import Foundation

extension SourceOperationGate {
    /// Returns an intent for native presentation. It does not show UI or treat
    /// dismissing a browser as successful website authentication.
    public func beginInteraction(_ request: YingxueWire.InteractionRequest, for ticket: Ticket,
                                 policy: SourceHostPolicy) throws -> YingxueWire.InteractionPresentation {
        try check(ticket)
        try policy.check(ticket.call.context)
        _ = try YingxueWireCodec.encode(request)
        guard !interactions.values.contains(where: { $0.context.requestID == ticket.call.context.requestID }) else {
            throw SourceHostFailure.invalidInteraction
        }
        switch request {
        case .web(let web):
            try policy.check(ticket.call.context, capability: .browser)
            if web.purpose == .signIn, !policy.manifest.authentication.contains(.web) { throw SourceHostFailure.undeclaredCapability }
            _ = try policy.resolve(web.target)
        case .form(let form):
            guard policy.manifest.authentication.contains(.form), !form.fields.isEmpty else { throw SourceHostFailure.invalidInteraction }
            var keys = Set<Data>()
            var hasSecret = false
            for field in form.fields {
                guard keys.insert(Data(field.key.utf8)).inserted else { throw SourceHostFailure.duplicateKey }
                if case .secret = field { hasSecret = true }
            }
            let origins = Set(form.credentialOrigins.map(SourceFileHeader.originKey))
            guard origins.count == form.credentialOrigins.count, origins.isSubset(of: policy.origins),
                  hasSecret ? !origins.isEmpty : origins.isEmpty else { throw SourceHostFailure.invalidInteraction }
        }
        let presentation = YingxueWire.InteractionPresentation(id: UUID().uuidString.lowercased(), context: ticket.call.context, request: request)
        interactions[presentation.id] = presentation
        return presentation
    }

    /// Native form submissions use handles for secret fields. Invalid/mismatched
    /// submissions leave the presentation pending; a successful reply consumes it.
    public func completeInteraction(_ completion: YingxueWire.InteractionCompletion,
                                    for ticket: Ticket) throws -> YingxueWire.InteractionResult {
        try check(ticket)
        _ = try YingxueWireCodec.encode(completion)
        guard let presentation = interactions[completion.id], presentation.context == ticket.call.context else {
            throw SourceHostFailure.missingInteraction
        }
        switch (presentation.request, completion.result) {
        case (_, .cancelled): break
        case (.web, .completed): break
        case (.form(let form), .submitted(let submitted)):
            let expected = Dictionary(uniqueKeysWithValues: form.fields.map { (Data($0.key.utf8), $0) })
            var seen = Set<Data>()
            for field in submitted.fields {
                let key = Data(field.key.utf8)
                guard seen.insert(key).inserted, let wanted = expected[key] else { throw SourceHostFailure.mismatchedInteraction }
                switch (wanted, field) {
                case (.publicText(let input), .publicText(let result)):
                    guard !input.required || !result.value.isEmpty else { throw SourceHostFailure.mismatchedInteraction }
                case (.secret, .credential(let result)):
                    let lease = try credentialLease(result.handle, for: ticket)
                    guard lease.origins.isSubset(of: Set(form.credentialOrigins.map(SourceFileHeader.originKey))) else {
                        throw SourceHostFailure.mismatchedInteraction
                    }
                default: throw SourceHostFailure.mismatchedInteraction
                }
            }
            for field in form.fields where field.required {
                guard seen.contains(Data(field.key.utf8)) else { throw SourceHostFailure.mismatchedInteraction }
            }
        default: throw SourceHostFailure.mismatchedInteraction
        }
        interactions.removeValue(forKey: completion.id)
        return completion.result
    }

    func discardInteractions(for requestID: String) {
        interactions = interactions.filter { $0.value.context.requestID != requestID }
    }
}

private extension YingxueWire.InteractionField {
    var key: String {
        switch self { case .publicText(let field): field.key; case .secret(let field): field.key }
    }
    var required: Bool {
        switch self { case .publicText(let field): field.required; case .secret(let field): field.required }
    }
}

private extension YingxueWire.FieldSubmission {
    var key: String {
        switch self { case .publicText(let field): field.key; case .credential(let field): field.key }
    }
}
