import Foundation

/// Experimental result ownership, not a JavaScript termination mechanism.
/// Kept internal until the runtime feasibility gate has an observed conclusion.
@MainActor
final class ProbeResultRegistry<Value: Sendable> {
    struct Ticket: Hashable, Sendable {
        fileprivate let generation: UUID
        fileprivate let operation: UUID
    }

    enum Interruption: Error, Equatable {
        case cancelled
        case timedOut
        case sourceChanged
        case sessionChanged
        case contextRebuilt
        case webContentTerminated
        case staleGeneration
        case closed
    }

    private struct Pending {
        let continuation: CheckedContinuation<Value, any Error>
        let deadline: Task<Void, Never>
    }

    private var generation = UUID()
    private var pending: [Ticket: Pending] = [:]
    private var isClosed = false
    private(set) var discardedResults = 0

    var pendingCount: Int { pending.count }

    /// Registration and settlement share the main actor with WebKit callbacks.
    /// `start` must return promptly; it may start asynchronous work and later call resolve.
    func perform(
        timeout: Duration,
        start: @MainActor (Ticket) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !isClosed else { throw Interruption.closed }
        let ticket = Ticket(generation: generation, operation: UUID())

        let value: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A cancellation before registration must not start external work.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: Interruption.cancelled)
                    return
                }
                // One owned timer per pending operation. Every settlement cancels it.
                // No task group waits for an uncooperative JavaScript child to finish.
                let deadline = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return // The owning operation settled and cancelled its timer.
                    }
                    self?.interrupt(ticket, because: .timedOut)
                }
                pending[ticket] = Pending(continuation: continuation, deadline: deadline)
                start(ticket)
            }
        } onCancel: {
            // A bounded hop to the actor that owns the continuation; no persistent worker.
            Task { @MainActor [weak self] in
                self?.interrupt(ticket, because: .cancelled)
            }
        }
        // Cancellation can race a successful callback before the cancellation hop
        // reaches this actor. Never hand that value back to an already-cancelled caller.
        try Task.checkCancellation()
        guard !isClosed else { throw Interruption.closed }
        guard ticket.generation == generation else { throw Interruption.staleGeneration }
        return value
    }

    /// Returns true only for the first still-current result. The continuation is
    /// resumed in this same actor turn, so invalidation cannot interleave with acceptance.
    @discardableResult
    func resolve(_ ticket: Ticket, with result: Result<Value, any Error>) -> Bool {
        guard ticket.generation == generation,
              let operation = pending.removeValue(forKey: ticket) else {
            discardedResults += 1
            return false
        }
        operation.deadline.cancel()
        operation.continuation.resume(with: result)
        return true
    }

    func invalidate(because reason: Interruption) {
        generation = UUID()
        let operations = pending.values
        pending.removeAll()
        for operation in operations {
            operation.deadline.cancel()
            operation.continuation.resume(throwing: reason)
        }
    }

    func close() {
        isClosed = true
        invalidate(because: .closed)
    }

    private func interrupt(_ ticket: Ticket, because reason: Interruption) {
        guard let operation = pending.removeValue(forKey: ticket) else { return }
        operation.deadline.cancel()
        operation.continuation.resume(throwing: reason)
    }
}
