import Foundation
import Observation

@MainActor
@Observable
final class StartupModel {
    enum State: Equatable {
        case idle
        case preparing
        case ready
        case failed(operationID: UUID)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let prepare: @Sendable () async throws -> Void
    @ObservationIgnored private var currentAttempt: UUID?

    init(prepare: @escaping @Sendable () async throws -> Void) {
        self.prepare = prepare
    }

    /// The caller owns cancellation. Only the latest attempt may publish state.
    func start() async {
        guard state != .ready, !Task.isCancelled else { return }
        let attempt = UUID()
        currentAttempt = attempt
        state = .preparing

        do {
            try await prepare()
            try Task.checkCancellation()
            guard currentAttempt == attempt else { return }
            state = .ready
        } catch {
            guard currentAttempt == attempt else { return }
            if error is CancellationError || Task.isCancelled {
                state = .idle
            } else {
                // Filesystem error descriptions can contain private paths.
                state = .failed(operationID: attempt)
            }
        }
    }
}
