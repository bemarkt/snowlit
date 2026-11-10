import Foundation
import SnowlitCore
import SnowlitStorage
import YingxueKit

/// One reader owns this service and closes it before leaving. Each consumer may
/// cancel independently; finite jobs serialize access to the foreground runtime.
@MainActor
final class ChapterAccessService {
    enum Policy { case cachedFirst, reload, offline }
    struct Key: Hashable { let book: LocalBookID; let chapter: ChapterReference }
    struct Result: Sendable {
        let document: ChapterDocument
        let fromCache: Bool
        let diagnostics: [String]
    }
    @MainActor private final class Request {
        let id = UUID()
        var work: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Result, any Error>] = [:]
    }
    private let load: @MainActor (Key, String?) async throws -> ChapterDocument?
    private let begin: @MainActor (Key) async throws -> ChapterWriteToken
    private let revoke: @MainActor (ChapterWriteToken) async throws -> Void
    private let fetch: @MainActor (ChapterWriteToken) async throws -> Result
    private let publish: @MainActor (ChapterDocument, ChapterWriteToken) async throws -> Void
    private var active: [Key: Request] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var closed = false
    private var pendingCleanup: [UUID: ChapterWriteToken] = [:]
    private(set) var cleanupProblem: (any Error)?

    init(load: @escaping @MainActor (Key, String?) async throws -> ChapterDocument?,
         begin: @escaping @MainActor (Key) async throws -> ChapterWriteToken,
         revoke: @escaping @MainActor (ChapterWriteToken) async throws -> Void,
         fetch: @escaping @MainActor (ChapterWriteToken) async throws -> Result,
         publish: @escaping @MainActor (ChapterDocument, ChapterWriteToken) async throws -> Void) {
        self.load = load; self.begin = begin; self.revoke = revoke; self.fetch = fetch; self.publish = publish
    }

    convenience init(library: LibraryDatabase, invoke: @escaping SourceInvocation,
                     digest: @escaping LibraryDatabase.ChapterDigest) {
        let normalizer = ChapterNormalizer()
        self.init(load: { try await library.cachedChapter(bookID: $0.book, chapter: $0.chapter, revision: $1, digest: digest) },
            begin: { try await library.beginChapterUpdate(bookID: $0.book, chapter: $0.chapter) },
            revoke: { try await library.revokeChapterUpdate($0) },
            fetch: { token in
                let reply = try await invoke(.chapter(.init(kind: .chapter,
                    input: .init(reference: .init(book: .init(key: token.resolved.book.key), key: token.resolved.key)))), token.installation)
                try checkedSourceReply(reply, operation: .chapter, installation: token.installation)
                guard case .chapter(let value) = reply else { throw SourceBrowsingFailure.invalidReply }
                let normalized = try await ChapterWireAdapter.normalize(YingxueWireCodec.encode(value.value), expected: token.resolved, using: normalizer)
                try Task.checkCancellation()
                return try .init(document: .init(content: normalized.content, digest: digest), fromCache: false, diagnostics: normalized.diagnostics)
            },
            publish: { try await library.publishChapter($0, using: $1, digest: digest) })
    }

    func document(for key: Key, policy: Policy = .cachedFirst, revision: String? = nil) async throws -> Result {
        guard !closed else { throw ChapterAccessFailure.closed }
        try Task.checkCancellation()
        if policy != .reload {
            if let document = try await load(key, revision) {
                try Task.checkCancellation()
                guard !closed else { throw ChapterAccessFailure.closed }
                return .init(document: document, fromCache: true, diagnostics: [])
            }
            guard policy != .offline, revision == nil else { throw ChapterAccessFailure.cacheMissing }
        }
        guard !closed else { throw ChapterAccessFailure.closed }
        if let cleanupProblem { throw cleanupProblem }
        try Task.checkCancellation()
        if policy == .reload, let previous = active.removeValue(forKey: key) {
            previous.work?.cancel()
            for waiter in previous.waiters.values { waiter.resume(throwing: ChapterAccessFailure.stale) }
            previous.waiters.removeAll()
        }
        let request: Request
        if let current = active[key] { request = current }
        else {
            request = Request(); active[key] = request
            let previous = tail
            let task = Task { @MainActor [self, request] in
                if let previous { await previous.value }
                await execute(key, request: request)
                jobs.removeValue(forKey: request.id)
                if jobs.isEmpty { tail = nil }
            }
            request.work = task; jobs[request.id] = task; tail = task
        }
        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                if Task.isCancelled { waiter.resume(throwing: CancellationError()) }
                else { request.waiters[consumer] = waiter }
            }
        } onCancel: {
            // This finite main-actor hop only removes one consumer. The service
            // owns the actual job and close awaits all outstanding jobs.
            Task { @MainActor in self.cancel(consumer, key: key, request: request) }
        }
    }

    func close() async throws {
        closed = true
        let requests = Array(active.values)
        active.removeAll()
        for request in requests {
            request.work?.cancel()
            for waiter in request.waiters.values { waiter.resume(throwing: CancellationError()) }
            request.waiters.removeAll()
        }
        let pending = Array(jobs.values)
        for work in pending { await work.value }
        cleanupProblem = nil
        for token in Array(pendingCleanup.values) {
            do {
                let cleanup = Task { try await revoke(token) }
                try await cleanup.value
                pendingCleanup.removeValue(forKey: token.id)
            } catch { cleanupProblem = error }
        }
        if let cleanupProblem { throw cleanupProblem }
    }

    private func cancel(_ consumer: UUID, key: Key, request: Request) {
        request.waiters.removeValue(forKey: consumer)?.resume(throwing: CancellationError())
        if request.waiters.isEmpty, active[key] === request {
            active.removeValue(forKey: key); request.work?.cancel()
        }
    }

    private func execute(_ key: Key, request: Request) async {
        var token: ChapterWriteToken?
        var result: Swift.Result<Result, any Error>
        do {
            try Task.checkCancellation()
            guard !closed, active[key] === request, !request.waiters.isEmpty else { throw CancellationError() }
            if let cleanupProblem { throw cleanupProblem }
            let permit = try await begin(key); token = permit
            try Task.checkCancellation()
            let value = try await fetch(permit)
            try Task.checkCancellation()
            guard !closed, active[key] === request, !request.waiters.isEmpty else { throw CancellationError() }
            try await publish(value.document, permit)
            try Task.checkCancellation()
            result = .success(value)
        } catch { result = .failure(error) }
        if let token {
            // Cancellation must not cancel permit cleanup. The finite cleanup
            // task is awaited before this owned job can finish.
            let cleanup = Task { try await revoke(token) }
            do { try await cleanup.value }
            catch { cleanupProblem = error; pendingCleanup[token.id] = token; result = .failure(error) }
        }
        if active[key] === request {
            active.removeValue(forKey: key)
            for waiter in request.waiters.values { waiter.resume(with: result) }
            request.waiters.removeAll()
        }
    }
}
