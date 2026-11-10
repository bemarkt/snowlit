import Foundation
import SnowlitCore
import YingxueKit

/// Owns only the credentials created by one native form. The operation owner
/// retains this capture through HTTP/credential use and calls finish afterward.
@MainActor
final class SourceFormCapture {
    enum Failure: Error { case invalidSubmission, closed, cleanupPending }
    private let presentation: YingxueWire.InteractionPresentation
    private let form: YingxueWire.FormInteraction
    private let gate: SourceOperationGate
    private let ticket: SourceOperationGate.Ticket
    private let store: any CredentialStore
    private let installationID: SourceInstallationID
    private var records: Set<StoredCredentialID> = []
    private var work: Task<YingxueWire.InteractionResult, any Error>?
    private var cleanupWork: Task<Void, any Error>?
    private var isClosed = false
    private var formCompleted = false

    init(presentation: YingxueWire.InteractionPresentation, gate: SourceOperationGate,
         ticket: SourceOperationGate.Ticket, store: any CredentialStore) throws {
        _ = try YingxueWireCodec.encode(presentation)
        guard presentation.context == ticket.call.context, case .form(let form) = presentation.request,
              let installation = UUID(uuidString: presentation.context.installationID) else { throw Failure.invalidSubmission }
        self.presentation = presentation; self.form = form; self.gate = gate; self.ticket = ticket; self.store = store
        installationID = .init(installation)
    }

    func submit(_ submission: SourceFormModel.Submission) async throws -> YingxueWire.InteractionResult {
        guard !isClosed, !formCompleted, work == nil else { throw Failure.closed }
        guard records.isEmpty, cleanupWork == nil else { throw Failure.cleanupPending }
        let fields = try validate(submission)
        // Owned finite capture; cancellation waits for an in-flight storage write
        // before deleting records so a late write cannot resurrect a secret.
        let task = Task { @MainActor [self] in
            try await gate.check(ticket)
            var reply: [YingxueWire.FieldSubmission] = []
            for field in fields {
                guard !isClosed else { throw Failure.closed }
                switch field {
                case .publicText(let key, let value):
                    reply.append(.publicText(.init(kind: .publicText, key: key, value: value)))
                case .secret(let key, let value):
                    let record = StoredCredentialID(installationID: installationID)
                    // Record ownership before the await, including stores that
                    // write successfully and then report an uncertain failure.
                    records.insert(record)
                    try await store.write(value, for: record)
                    try await gate.check(ticket)
                    guard !isClosed else { throw Failure.closed }
                    let handle = try await gate.issueCredential(record, origins: form.credentialOrigins, for: ticket)
                    reply.append(.credential(.init(kind: .credential, key: key, handle: handle)))
                }
            }
            return try await gate.completeInteraction(.init(id: presentation.id,
                result: .submitted(.init(kind: .submitted, fields: reply))), for: ticket)
        }
        work = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !isClosed else { throw Failure.closed }
            formCompleted = true; work = nil
            return result
        } catch {
            work = nil
            // An overlapping close owns cleanup after awaiting the worker.
            if !isClosed { try await cleanRecords() }
            throw error
        }
    }

    func cancel() async throws {
        try await close()
        guard !formCompleted else { return }
        do {
            _ = try await gate.completeInteraction(.init(id: presentation.id,
                result: .cancelled(.init(kind: .cancelled))), for: ticket)
            formCompleted = true
        } catch SourceOperationGate.Failure.closed {
            // The enclosing operation already revoked the interaction.
        } catch SourceOperationGate.Failure.disabled {
        } catch SourceOperationGate.Failure.staleOperation {
        } catch SourceHostFailure.missingInteraction {
            // Submission can consume it immediately before native cancellation.
        }
    }

    /// Also called after failure, logout or operation cancellation. A failure
    /// retains the exact pending IDs so the same owner can retry cleanup.
    func finish() async throws { try await close() }

    private func close() async throws {
        isClosed = true
        if let work { work.cancel(); _ = await work.result }
        try await cleanRecords()
    }

    private func cleanRecords() async throws {
        if let cleanupWork { return try await cleanupWork.value }
        // Cleanup deliberately has its own finite task: a cancelled caller must
        // not cause Keychain's cancellation check to skip removal. The owner
        // awaits it; failures remain retryable, never swallowed or logged raw.
        let task = Task { @MainActor [self] in
            var failed = false
            for record in records {
                do { try await store.remove(record); records.remove(record) }
                catch { failed = true }
            }
            if failed { throw Failure.cleanupPending }
        }
        cleanupWork = task
        defer { cleanupWork = nil }
        try await task.value
    }

    private func validate(_ submission: SourceFormModel.Submission) throws -> [SourceFormModel.Submission.Field] {
        guard submission.presentationID == presentation.id else { throw Failure.invalidSubmission }
        var fields: [Data: SourceFormModel.Submission.Field] = [:]
        for field in submission.fields {
            let key: String
            switch field { case .publicText(let value, _), .secret(let value, _): key = value }
            guard fields.updateValue(field, forKey: Data(key.utf8)) == nil else { throw Failure.invalidSubmission }
        }
        let ordered = try form.fields.compactMap { expected -> SourceFormModel.Submission.Field? in
            guard let value = fields.removeValue(forKey: Data(expected.formKey.utf8)) else {
                if expected.formRequired { throw Failure.invalidSubmission }
                return nil
            }
            switch (expected, value) {
            case (.publicText, .publicText(_, let text)):
                guard !expected.formRequired || !text.isEmpty else { throw Failure.invalidSubmission }
            case (.secret, .secret(_, let secret)):
                guard !expected.formRequired || !secret.bytes.isEmpty else { throw Failure.invalidSubmission }
            default: throw Failure.invalidSubmission
            }
            return value
        }
        guard fields.isEmpty else { throw Failure.invalidSubmission }
        return ordered
    }
}
