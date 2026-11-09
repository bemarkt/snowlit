import Foundation
import Testing
@testable import Snowlit

@MainActor
struct StartupModelTests {
    @Test func readyStartupDoesNotPrepareAgain() async {
        let preparation = Preparation()
        let model = StartupModel { try await preparation.run() }

        await model.start()
        await model.start()

        #expect(model.state == .ready)
        #expect(await preparation.calls == 1)
    }

    @Test func failureRemainsVisibleUntilARetrySucceeds() async {
        let preparation = Preparation(failFirst: true)
        let model = StartupModel { try await preparation.run() }

        await model.start()
        guard case .failed = model.state else {
            Issue.record("A storage error must not appear as a ready application")
            return
        }

        await model.start()
        #expect(model.state == .ready)
        #expect(await preparation.calls == 2)
    }

    @Test func cancellationDoesNotBecomeFailureOrPublishReady() async {
        let preparation = SuspendedFirstPreparation()
        let model = StartupModel { try await preparation.run() }
        // The test owns and joins this task, including its deliberately late completion.
        let first = Task { await model.start() }
        await preparation.waitUntilSuspended()
        #expect(model.state == .preparing)

        first.cancel()
        await preparation.finishFirst(failing: false)
        await first.value
        #expect(model.state == .idle)

        await model.start()
        #expect(model.state == .ready)
    }

    @Test func lateFailureCannotReplaceANewerSuccessfulAttempt() async {
        let preparation = SuspendedFirstPreparation()
        let model = StartupModel { try await preparation.run() }
        // Hold the first attempt so completion order differs from request order.
        let first = Task { await model.start() }
        await preparation.waitUntilSuspended()

        await model.start()
        #expect(model.state == .ready)
        await preparation.finishFirst(failing: true)
        await first.value

        #expect(model.state == .ready)
    }
}

private enum TestFailure: Error { case unavailable }

private actor Preparation {
    private(set) var calls = 0
    private let failFirst: Bool

    init(failFirst: Bool = false) {
        self.failFirst = failFirst
    }

    func run() throws {
        calls += 1
        if failFirst && calls == 1 {
            throw TestFailure.unavailable
        }
    }
}

private actor SuspendedFirstPreparation {
    private var calls = 0
    private var completion: CheckedContinuation<Void, any Error>?
    private var observer: CheckedContinuation<Void, Never>?
    private var hasSuspended = false

    func run() async throws {
        calls += 1
        guard calls == 1 else { return }
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            hasSuspended = true
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        if hasSuspended { return }
        await withCheckedContinuation { continuation in
            observer = continuation
        }
    }

    func finishFirst(failing: Bool) {
        if failing {
            completion?.resume(throwing: TestFailure.unavailable)
        } else {
            completion?.resume()
        }
        completion = nil
    }
}
