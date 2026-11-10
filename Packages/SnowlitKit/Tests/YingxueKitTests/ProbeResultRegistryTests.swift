import Foundation
import Testing
@testable import YingxueKit

@MainActor
struct ProbeResultRegistryTests {
    typealias Registry = ProbeResultRegistry<String>

    @Test func completionIsDeliveredOnceAndReleasesTheWaiter() async throws {
        let registry = Registry()
        let value = try await registry.perform(timeout: .seconds(2)) { ticket in
            #expect(registry.resolve(ticket, with: .success("first")))
            #expect(!registry.resolve(ticket, with: .success("second")))
        }
        #expect(value == "first")
        #expect(registry.pendingCount == 0)
        #expect(registry.discardedResults == 1)
    }

    @Test(arguments: [Registry.Interruption.sourceChanged, .sessionChanged, .contextRebuilt,
                      .webContentTerminated])
    func invalidationRejectsLateResultsAndAllowsNewWork(reason: Registry.Interruption) async throws {
        let registry = Registry()
        var oldTicket: Registry.Ticket?
        await #expect(throws: reason) {
            try await registry.perform(timeout: .seconds(2)) { ticket in
                oldTicket = ticket
                registry.invalidate(because: reason)
            }
        }
        let stale = try #require(oldTicket)
        let value = try await registry.perform(timeout: .seconds(2)) { ticket in
            #expect(!registry.resolve(stale, with: .success("old data")))
            #expect(registry.resolve(ticket, with: .success("current data")))
        }
        #expect(value == "current data")
        #expect(registry.pendingCount == 0)
    }

    @Test func cancellationSettlesOnlyItsOwnConsumer() async throws {
        let registry = Registry()
        let (started, signal) = AsyncStream<Registry.Ticket>.makeStream()
        let cancelled = Task {
            try await registry.perform(timeout: .seconds(2)) { signal.yield($0) }
        }
        let surviving = Task {
            try await registry.perform(timeout: .seconds(2)) { signal.yield($0) }
        }
        var iterator = started.makeAsyncIterator()
        let first = try #require(await iterator.next())
        let second = try #require(await iterator.next())
        signal.finish()
        cancelled.cancel()
        await #expect(throws: Registry.Interruption.cancelled) { try await cancelled.value }
        // Both callbacks may arrive. Exactly one is still owned by a live consumer.
        let accepted = [registry.resolve(first, with: .success("result")),
                        registry.resolve(second, with: .success("result"))]
        #expect(accepted.filter { $0 }.count == 1)
        #expect(try await surviving.value == "result")
        #expect(registry.pendingCount == 0)
    }

    @Test func aCancelledCallerDoesNotStartWork() async throws {
        let registry = Registry()
        let (ready, signal) = AsyncStream<Void>.makeStream()
        var didStart = false
        let caller = Task {
            for await _ in ready { break }
            return try await registry.perform(timeout: .seconds(2)) { _ in didStart = true }
        }
        caller.cancel()
        signal.finish()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(!didStart)
        #expect(registry.pendingCount == 0)
    }

    @Test func cancellationAfterCallbackButBeforeResumptionDoesNotReturnSuccess() async throws {
        let registry = Registry()
        let (started, signal) = AsyncStream<Registry.Ticket>.makeStream()
        let caller = Task {
            try await registry.perform(timeout: .seconds(2)) { signal.yield($0) }
        }
        var iterator = started.makeAsyncIterator()
        let ticket = try #require(await iterator.next())
        signal.finish()
        // No actor suspension between callback delivery and cancelling its waiting task.
        #expect(registry.resolve(ticket, with: .success("racing result")))
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(registry.pendingCount == 0)
    }

    @Test func generationChangedBeforeResumptionRejectsAnAlreadyDeliveredCallback() async throws {
        let registry = Registry()
        await #expect(throws: Registry.Interruption.staleGeneration) {
            try await registry.perform(timeout: .seconds(2)) { ticket in
                #expect(registry.resolve(ticket, with: .success("previous source")))
                registry.invalidate(because: .sourceChanged)
            }
        }
    }

    @Test func deadlineSettlesAnUncooperativeCallbackWithoutWaitingForIt() async throws {
        let registry = Registry()
        var delayed: Registry.Ticket?
        await #expect(throws: Registry.Interruption.timedOut) {
            try await registry.perform(timeout: .milliseconds(10)) { delayed = $0 }
        }
        #expect(registry.pendingCount == 0)
        #expect(!registry.resolve(try #require(delayed), with: .success("late")))
        let recovered = try await registry.perform(timeout: .seconds(2)) {
            registry.resolve($0, with: .success("recovered"))
        }
        #expect(recovered == "recovered")
    }

    @Test(arguments: [Registry.Interruption.webContentTerminated, .sourceChanged, .sessionChanged])
    func invalidationBeforeFailureResumesPreservesItsNativeCause(reason: Registry.Interruption) async throws {
        let registry = Registry()
        let callbackError = NSError(domain: "WKErrorDomain", code: 5)
        await #expect(throws: reason) {
            try await registry.perform(timeout: .seconds(2)) { ticket in
                #expect(registry.resolve(ticket, with: .failure(callbackError)))
                registry.invalidate(because: reason)
                // Later generations must not replace this waiter's original cause.
                registry.invalidate(because: .contextRebuilt)
            }
        }
        #expect(registry.pendingCount == 0)
        #expect(try await registry.perform(timeout: .seconds(2)) {
            registry.resolve($0, with: .success("new generation"))
        } == "new generation")
    }

    @Test func callbackErrorWithoutInvalidationIsNotReportedAsProcessTermination() async throws {
        let registry = Registry()
        let callbackError = NSError(domain: "WKErrorDomain", code: 5)
        do {
            _ = try await registry.perform(timeout: .seconds(2)) {
                registry.resolve($0, with: .failure(callbackError))
            }
            Issue.record("Expected the original callback error")
        } catch {
            #expect((error as NSError) === callbackError)
        }
    }

    @Test func closingRejectsEveryWaiterAndCannotBeReopened() async throws {
        let registry = Registry()
        await #expect(throws: Registry.Interruption.closed) {
            try await registry.perform(timeout: .seconds(2)) { _ in registry.close() }
        }
        var didStart = false
        await #expect(throws: Registry.Interruption.closed) {
            try await registry.perform(timeout: .seconds(2)) { _ in didStart = true }
        }
        #expect(!didStart)
        #expect(registry.pendingCount == 0)
    }
}
