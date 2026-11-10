import Foundation
import Observation
import SnowlitCore
import YingxueKit

/// Owns native forms and their temporary credentials for exactly one operation.
/// The backend supplies work to run; it still owns its network/JavaScript cancellation.
@MainActor
@Observable
final class SourceFormSession {
    enum Failure: Error { case alreadyStarted, closed, interactionPending, cleanupRequired }
    enum Phase { case idle, active, closing, cleanupRequired, finished }
    private(set) var form: SourceFormModel?
    private(set) var phase: Phase = .idle
    @ObservationIgnored private let gate: SourceOperationGate
    @ObservationIgnored private let ticket: SourceOperationGate.Ticket
    @ObservationIgnored private let store: any CredentialStore
    @ObservationIgnored private let sourceName: String
    @ObservationIgnored private let sourceID: String
    @ObservationIgnored private var captures: [UUID: SourceFormCapture] = [:]
    @ObservationIgnored private var presenting = false
    @ObservationIgnored private var cleanup: Task<Void, any Error>?

    init(gate: SourceOperationGate, ticket: SourceOperationGate.Ticket, store: any CredentialStore,
         sourceName: String, sourceID: String) {
        self.gate = gate; self.ticket = ticket; self.store = store
        self.sourceName = sourceName; self.sourceID = sourceID
    }

    /// Returning from the backend is not enough: the gate must still be current,
    /// and every form credential must be removed before this returns success.
    func run<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        guard phase == .idle else { throw Failure.alreadyStarted }
        phase = .active
        let value: Value
        do {
            try await gate.check(ticket)
            value = try await operation()
            try Task.checkCancellation()
            guard phase == .active else { throw Failure.closed }
            guard !presenting else { throw Failure.interactionPending }
            try await gate.finish(ticket)
        } catch {
            // Revocation precedes cleanup and does not inherit cancellation.
            // A stale backend response can no longer use a captured handle.
            await gate.cancel(ticket)
            try await close()
            throw error
        }
        try await close()
        return value
    }

    func present(_ presentation: YingxueWire.InteractionPresentation) async throws -> YingxueWire.InteractionResult {
        guard phase == .active else { throw Failure.closed }
        guard !presenting else { throw Failure.interactionPending }
        presenting = true
        defer { presenting = false }
        let allowed = try await gate.allowsCredentialRead(for: ticket)
        guard phase == .active else { throw Failure.closed }
        let capture = try SourceFormCapture(presentation: presentation, gate: gate, ticket: ticket, store: store)
        let model = try SourceFormModel(presentation: presentation, sourceName: sourceName, sourceID: sourceID,
            allowsCredentialRead: allowed, submit: { try await capture.submit($0) }, cancel: { try await capture.cancel() })
        captures[UUID()] = capture
        form = model
        defer { if form === model { form = nil } }
        let result = try await model.response()
        try await gate.check(ticket)
        guard phase == .active else { throw Failure.closed }
        return result
    }

    /// Called for source invalidation or an explicit enclosing-operation cancel.
    /// Cleanup failures remain on this owner until retryCleanup succeeds.
    func cancel() async throws {
        await gate.cancel(ticket)
        try await close()
    }

    func retryCleanup() async throws {
        guard phase == .cleanupRequired else { return }
        try await close()
    }

    private func close() async throws {
        if let cleanup { return try await cleanup.value }
        if phase == .finished { return }
        phase = .closing
        form?.invalidate(); form = nil
        // A finite, awaited cleanup belongs to this owner even when the parent
        // task is cancelled. Each capture waits for its own pending writes.
        let task = Task { @MainActor [self] in
            var failed = false
            for (id, capture) in captures {
                do { try await capture.finish(); captures.removeValue(forKey: id) }
                catch { failed = true }
            }
            if failed { throw Failure.cleanupRequired }
        }
        cleanup = task
        defer { cleanup = nil }
        do { try await task.value; phase = .finished }
        catch { phase = .cleanupRequired; throw Failure.cleanupRequired }
    }
}
