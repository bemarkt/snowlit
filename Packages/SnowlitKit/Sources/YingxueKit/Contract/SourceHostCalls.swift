import Foundation

extension SourceOperationGate {
    public struct HostTicket: Sendable {
        public let call: YingxueWire.HostCall
        let operation: Ticket
    }

    /// A repeated call ID cannot replay an HTTP write or a native interaction.
    /// Completed IDs stay reserved until the containing operation ends.
    public func acceptHostCall(_ bytes: Data, for ticket: Ticket, policy: SourceHostPolicy) throws -> HostTicket {
        try check(ticket)
        let call = try YingxueWireCodec.decode(YingxueWire.HostCall.self, from: bytes)
        guard call.context == ticket.call.context else { throw SourceHostFailure.wrongContext }
        try policy.check(call.context)
        switch call.request {
        case .http: try policy.check(call.context, capability: .http)
        case .dom: try policy.check(call.context, capability: .dom)
        case .readCredential: try policy.check(call.context, capability: .credentialsRead)
        case .interact, .decodeText: break
        }
        let key = ticket.call.context.requestID + "/" + call.id
        guard hostCallIDs.insert(key).inserted else { throw SourceHostFailure.duplicateHostCall }
        hostCalls[key] = call
        return .init(call: call, operation: ticket)
    }

    public func check(_ ticket: HostTicket) throws {
        try check(ticket.operation)
        let key = ticket.call.context.requestID + "/" + ticket.call.id
        guard hostCalls[key] == ticket.call else { throw SourceHostFailure.staleHostCall }
    }

    /// Reply validation is separate from completion so the backend can recheck
    /// immediately before delivering across an asynchronous WebKit bridge.
    public func validateHostReply(_ bytes: Data, for ticket: HostTicket) throws -> YingxueWire.HostReply {
        try check(ticket)
        let reply = try YingxueWireCodec.decode(YingxueWire.HostReply.self, from: bytes)
        guard reply.identity.id == ticket.call.id, reply.identity.context == ticket.call.context,
              reply.identity.method == ticket.call.request.method else { throw SourceHostFailure.wrongContext }
        return reply
    }

    public func finish(_ ticket: HostTicket) throws {
        try check(ticket)
        hostCalls.removeValue(forKey: ticket.call.context.requestID + "/" + ticket.call.id)
    }

    func discardHostCalls(for requestID: String) {
        let prefix = requestID + "/"
        hostCalls = hostCalls.filter { !$0.key.hasPrefix(prefix) }
        hostCallIDs = hostCallIDs.filter { !$0.hasPrefix(prefix) }
    }
}

extension YingxueWire.HostRequest {
    public var method: YingxueWire.HostMethod {
        switch self {
        case .http: .http
        case .dom: .dom
        case .decodeText: .decodeText
        case .readCredential: .readCredential
        case .interact: .interact
        }
    }
}

private extension YingxueWire.HostReply {
    var identity: (id: String, context: YingxueWire.OperationContext, method: YingxueWire.HostMethod) {
        switch self {
        case .http(let reply): (reply.id, reply.context, .http)
        case .dom(let reply): (reply.id, reply.context, .dom)
        case .decodeText(let reply): (reply.id, reply.context, .decodeText)
        case .readCredential(let reply): (reply.id, reply.context, .readCredential)
        case .interact(let reply): (reply.id, reply.context, .interact)
        case .failure(let reply): (reply.id, reply.context, reply.method)
        }
    }
}
