import Foundation
import SnowlitCore
import Testing
@testable import Snowlit

@MainActor
struct ChapterAccessServiceTests {
    @Test func cachedAndOfflineReadsNeverBeginOrFetchAWebsiteOperation() async throws {
        let fixture = try Fixture(), service = fixture.service()
        fixture.cached = fixture.value
        let result = try await service.document(for: fixture.key, policy: .offline, revision: fixture.value.revision)
        #expect(result.fromCache && result.document == fixture.value)
        #expect(fixture.begun == 0 && fixture.fetched == 0 && fixture.published.isEmpty)
        fixture.cached = nil
        await #expect(throws: ChapterAccessFailure.cacheMissing) {
            try await service.document(for: fixture.key, policy: .offline)
        }
        await #expect(throws: ChapterAccessFailure.cacheMissing) {
            try await service.document(for: fixture.key, revision: fixture.value.revision)
        }
        #expect(fixture.begun == 0 && fixture.fetched == 0)
        try await service.close()
    }

    @Test func coalescedReadersCancelIndependentlyAndPublishOnlyOnce() async throws {
        let fixture = try Fixture(), service = fixture.service()
        let first = Task { try await service.document(for: fixture.key) }
        await fixture.fetchStarted.wait()
        let joined = Signal()
        let second = Task { @MainActor in
            joined.send()
            return try await service.document(for: fixture.key)
        }
        await joined.wait()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        fixture.finishFetch()
        let result = try await second.value
        #expect(result.document == fixture.value && !result.fromCache)
        #expect(fixture.fetched == 1 && fixture.begun == 1 && fixture.published == [fixture.value])
        #expect(fixture.revoked.count == 1)
        try await service.close()
    }

    @Test func lastConsumerCancellationReturnsWithoutAcceptingTheLateResponse() async throws {
        let fixture = try Fixture(), service = fixture.service()
        let consumer = Task { try await service.document(for: fixture.key) }
        await fixture.fetchStarted.wait()
        consumer.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        #expect(fixture.published.isEmpty)
        fixture.finishFetch()
        try await service.close()
        #expect(fixture.published.isEmpty && fixture.revoked.count == 1)
    }

    @Test func closingWaitsForCleanupAndNoLateResponseCanPublish() async throws {
        let fixture = try Fixture(), service = fixture.service()
        let consumer = Task { try await service.document(for: fixture.key) }
        await fixture.fetchStarted.wait()
        let closing = Task { try await service.close() }
        await #expect(throws: CancellationError.self) { try await consumer.value }
        #expect(fixture.revoked.isEmpty)
        fixture.finishFetch()
        try await closing.value
        #expect(fixture.published.isEmpty && fixture.revoked.count == 1)
        await #expect(throws: ChapterAccessFailure.closed) { try await service.document(for: fixture.key) }
    }

    @Test func refreshSupersedesAnOlderResponseAndWaitsForItsCleanup() async throws {
        let fixture = try Fixture(), service = fixture.service()
        let old = Task { try await service.document(for: fixture.key) }
        await fixture.fetchStarted.wait()
        let fresh = Task { try await service.document(for: fixture.key, policy: .reload) }
        await #expect(throws: ChapterAccessFailure.stale) { try await old.value }
        #expect(fixture.fetched == 1)
        fixture.delay = false
        fixture.finishFetch()
        let result = try await fresh.value
        #expect(result.document == fixture.value && fixture.published == [fixture.value])
        #expect(fixture.fetched == 2 && fixture.revoked.count == 2)
        try await service.close()
    }

    @Test func cacheAndPersistenceFailuresRemainVisibleAndCleanupCanBeRetried() async throws {
        let fixture = try Fixture(), service = fixture.service()
        fixture.readFailure = true
        await #expect(throws: ChapterAccessFailure.cacheCorrupt) { try await service.document(for: fixture.key) }
        #expect(fixture.begun == 0)
        fixture.readFailure = false; fixture.delay = false; fixture.publishFailure = true
        await #expect(throws: Fixture.Failure.write) { try await service.document(for: fixture.key) }
        #expect(fixture.published.isEmpty && fixture.revoked.count == 1)
        fixture.publishFailure = false; fixture.cleanupFailure = true
        await #expect(throws: Fixture.Failure.cleanup) { try await service.document(for: fixture.key) }
        #expect(service.cleanupProblem != nil)
        fixture.cached = fixture.value
        let offline = try await service.document(for: fixture.key, policy: .offline)
        #expect(offline.fromCache && offline.document == fixture.value)
        await #expect(throws: Fixture.Failure.cleanup) { try await service.document(for: fixture.key, policy: .reload) }
        #expect(fixture.fetched == 2)
        await #expect(throws: Fixture.Failure.cleanup) { try await service.close() }
        fixture.cleanupFailure = false
        try await service.close()
        #expect(service.cleanupProblem == nil && fixture.revoked.count == 2)
    }

    @MainActor
    private final class Fixture {
        enum Failure: Error { case write, cleanup }
        let key: ChapterAccessService.Key
        let installation: SourceInstallationSnapshot
        let value: ChapterDocument
        var cached: ChapterDocument?
        var delay = true, readFailure = false, publishFailure = false, cleanupFailure = false
        var begun = 0, fetched = 0
        var published: [ChapterDocument] = []
        var revoked: [UUID] = []
        let fetchStarted = Signal()
        private var fetchWaiter: CheckedContinuation<Void, Never>?

        init() throws {
            installation = try .init(id: .init(), importID: UUID(), scriptSHA256: String(repeating: "a", count: 64),
                metadata: .init(sourceID: "org.example.chapter-access", name: "Fixture", scriptVersion: "1",
                    protocolVersion: 1, referenceVersion: 1, stateVersion: 1), revision: 1, state: .enabled,
                configuration: [], allowsCredentialRead: false, websiteSessionID: UUID(), pendingCleanup: nil)
            key = try .init(book: .init(), chapter: .init(book: .init(installationID: installation.id, referenceVersion: 1, key: "book"), key: "chapter"))
            value = try .init(content: .init(chapter: key.chapter, sourceRevision: "r1", blocks: [
                .paragraph(.init(id: "p1", runs: [.text("Test", .init())]))]), digest: { _ in String(repeating: "b", count: 64) })
        }
        func service() -> ChapterAccessService {
            .init(load: { key, revision in try self.read(key, revision: revision) },
                begin: { key in self.begin(key) }, revoke: { try self.revoke($0) },
                fetch: { token in await self.fetch(token) }, publish: { try self.publish($0, $1) })
        }
        private func read(_ key: ChapterAccessService.Key, revision: String?) throws -> ChapterDocument? {
            #expect(key == self.key)
            if readFailure { throw ChapterAccessFailure.cacheCorrupt }
            return cached
        }
        private func begin(_ key: ChapterAccessService.Key) -> ChapterWriteToken {
            begun += 1
            return .init(id: UUID(), bookID: key.book, requested: key.chapter, resolved: key.chapter, installation: installation)
        }
        private func fetch(_ token: ChapterWriteToken) async -> ChapterAccessService.Result {
            fetched += 1
            if delay { await withCheckedContinuation { fetchWaiter = $0; fetchStarted.send() } }
            return .init(document: value, fromCache: false, diagnostics: [])
        }
        private func publish(_ value: ChapterDocument, _ token: ChapterWriteToken) throws {
            if publishFailure { throw Failure.write }
            published.append(value)
        }
        private func revoke(_ token: ChapterWriteToken) throws {
            if cleanupFailure { throw Failure.cleanup }
            revoked.append(token.id)
        }
        func finishFetch() { fetchWaiter?.resume(); fetchWaiter = nil }
    }

    @MainActor
    private final class Signal {
        private var sent = false
        private var waiter: CheckedContinuation<Void, Never>?
        func send() { sent = true; waiter?.resume(); waiter = nil }
        func wait() async { if !sent { await withCheckedContinuation { waiter = $0 } } }
    }
}
