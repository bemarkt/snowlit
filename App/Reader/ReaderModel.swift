import Foundation
import Observation
import SnowlitCore
import SnowlitStorage

@MainActor
@Observable
final class ReaderModel: Identifiable {
    enum Failure: Error { case missingCatalog, missingPosition, superseded }
    let id = UUID()
    let book: LibraryBook
    private(set) var catalog: CatalogSnapshot?
    private(set) var chapters: [ReadingWindow.Chapter] = []
    private(set) var position: ReadingPosition?
    private(set) var navigationID = UUID()
    private(set) var preferences = ReaderPreferences.defaults
    private(set) var isLoading = false
    private(set) var problem: SourceBrowsingProblem?
    private(set) var adjacentProblem: SourceBrowsingProblem?
    var persistenceProblem: SourceBrowsingProblem? { checkpointProblem ?? preferencesProblem }
    private var checkpointProblem: SourceBrowsingProblem?
    private var preferencesProblem: SourceBrowsingProblem?
    private(set) var needsResumeChoice = false
    private(set) var ownershipLost = false
    private(set) var cacheUsage: ChapterCacheUsage?
    private(set) var offlineOnly = false
    var currentIndex: Int? { entries.firstIndex { entry in documents[entry.reference]?.content.chapter == position?.chapter } }
    var currentTitle: String { currentIndex.map { entries[$0].title } ?? chapters.first?.title ?? book.title }
    var entries: [CatalogEntry] { catalog?.entries ?? [] }
    var hasHiddenElements: Bool { chapters.contains { !ChapterTextProjection(document: $0.document).nonTextPositions.isEmpty } }
    static let cacheByteLimit: Int64 = 256 * 1024 * 1024

    @ObservationIgnored private let openLibrary: @MainActor () async throws -> LibraryDatabase
    @ObservationIgnored private let makeService: @MainActor (LibraryDatabase) -> ChapterAccessService
    @ObservationIgnored private var library: LibraryDatabase?
    @ObservationIgnored private var service: ChapterAccessService?
    @ObservationIgnored private var session: ReadingSession?
    @ObservationIgnored private var sequence: Int64 = 0
    @ObservationIgnored private var documents: [ChapterReference: ChapterDocument] = [:]
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var saves: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var opened = false
    @ObservationIgnored private let initialChapter: ChapterReference?

    init(book: LibraryBook, chapter: ChapterReference?,
         openLibrary: @escaping @MainActor () async throws -> LibraryDatabase,
         makeService: @escaping @MainActor (LibraryDatabase) -> ChapterAccessService) {
        self.book = book; initialChapter = chapter
        self.openLibrary = openLibrary; self.makeService = makeService
    }

    func open() async {
        guard !opened, !closed else { return }
        opened = true; isLoading = true
        do {
            let library = try await openLibrary()
            try Task.checkCancellation()
            guard !closed else { return }
            self.library = library; service = makeService(library)
            preferences = try await library.preferences()
            catalog = try await library.catalog(for: book.id)
            guard catalog != nil else { throw Failure.missingCatalog }
            let checkpoint = try await library.checkpoint(for: book.id)
            try Task.checkCancellation()
            guard !closed else { return }
            if let initialChapter { navigate(to: initialChapter) }
            else if let saved = checkpoint?.position { resume(saved) }
            else if let first = entries.first { navigate(to: first.reference) }
            else { throw Failure.missingCatalog }
            await work?.value
        } catch { fail(error) }
    }

    func navigate(to chapter: ChapterReference, reload: Bool = false) {
        guard !closed, let service, let library, let entry = entries.first(where: { $0.reference == chapter }) else { return }
        needsResumeChoice = false
        replaceWork { [self] in
            let result = try await service.document(for: .init(book: book.id, chapter: chapter),
                policy: offlineOnly ? .offline : (reload ? .reload : .cachedFirst))
            try Task.checkCancellation()
            let anchor = try ChapterTextProjection(document: result.document).position(atUTF16Offset: 0)
            if session == nil { session = try await library.startReading(book.id) }
            try Task.checkCancellation()
            documents = [chapter: result.document]
            chapters = [.init(title: entry.title, document: result.document)]
            position = anchor; navigationID = UUID(); isLoading = false
            // Cached restoration does not create a website operation. Adjacent
            // network content is requested by scrolling or a chapter action.
            try await loadAdjacent(network: false)
            try await maintainCache()
        }
    }

    private func resume(_ saved: ReadingPosition) {
        guard let service, let library else { return }
        replaceWork { [self] in
            do {
                let result = try await service.document(for: .init(book: book.id, chapter: saved.chapter),
                    policy: .offline, revision: saved.documentRevision)
                _ = try ChapterTextProjection(document: result.document).utf16Offset(of: saved)
                try Task.checkCancellation()
                session = try await library.startReading(book.id)
                try Task.checkCancellation()
                documents = [saved.chapter: result.document]
                chapters = [.init(title: entries.first(where: { $0.reference == saved.chapter })?.title ?? "上次阅读的章节",
                    document: result.document)]
                position = saved; navigationID = UUID(); isLoading = false
                try await loadAdjacent(network: false)
            } catch {
                if !(error is CancellationError) { needsResumeChoice = true }
                throw error
            }
        }
    }

    /// Called only after the viewport has displayed a validated semantic anchor.
    func didDisplay(_ anchor: ReadingPosition, userScrolled: Bool) {
        guard !closed, let window = try? ReadingWindow(chapters: chapters),
              (try? window.offset(of: anchor)) != nil else { return }
        position = anchor
        persist(anchor)
        if userScrolled, !isLoading { requestAdjacent() }
    }

    func requestAdjacent() {
        guard !closed, position != nil else { return }
        replaceWork(reportAsAdjacent: true) { [self] in
            try await loadAdjacent(network: !offlineOnly)
            try await maintainCache()
        }
    }

    func move(by offset: Int) {
        guard let index = currentIndex, entries.indices.contains(index + offset) else { return }
        navigate(to: entries[index + offset].reference)
    }

    func updatePreferences(fontSize: Double? = nil, theme: ReaderPreferences.Theme? = nil) {
        guard !closed, let library else { return }
        do {
            let next = try ReaderPreferences(fontSize: min(36, max(14, fontSize ?? preferences.fontSize)), theme: theme ?? preferences.theme)
            preferences = next
            enqueueSave(preferences: true) { try await library.savePreferences(next) }
        } catch { preferencesProblem = .init(error, fallback: "阅读设置未能保存，请重试。") }
    }

    func retrySave() {
        guard let position else { return }
        persist(position)
        updatePreferences()
    }

    func clearCache() async {
        guard let library else { return }
        await suspend()
        do { cacheUsage = try await library.trimChapterCache(toByteLimit: 0) }
        catch { problem = .init(error, fallback: "缓存未能清理，请重试。") }
    }

    func setOfflineOnly(_ value: Bool) {
        offlineOnly = value
        if value { work?.cancel(); generation = nil; isLoading = false }
    }

    func suspend() async {
        work?.cancel(); generation = nil; isLoading = false
        await work?.value
        await saves?.value
    }

    func waitForLoading() async { await work?.value }

    func close(acknowledgingNewerProgress: Bool = false) async -> Bool {
        closed = true
        await suspend()
        if ownershipLost && acknowledgingNewerProgress { checkpointProblem = nil }
        if persistenceProblem != nil { closed = false; return false }
        do { try await service?.close() }
        catch { problem = .init(error, fallback: "阅读会话尚未清理完成，请重试关闭。"); return false }
        return true
    }

    func reportViewportFailure(_ error: any Error) {
        problem = .init(error, fallback: "无法保持当前文字位置，请从目录重新选择章节。")
    }

    private func loadAdjacent(network: Bool) async throws {
        guard let index = currentIndex, let service else { return }
        let wanted = max(0, index - 1)...min(entries.count - 1, index + 1)
        // Drop distant documents only while the visible chapter remains resident.
        var nextDocuments = documents.filter { key, _ in wanted.contains { entries[$0].reference == key } }
        for neighbor in [index + 1, index - 1] where wanted.contains(neighbor) {
            let entry = entries[neighbor]
            if nextDocuments[entry.reference] != nil { continue }
            do {
                let result = try await service.document(for: .init(book: book.id, chapter: entry.reference),
                    policy: network ? .cachedFirst : .offline)
                try Task.checkCancellation()
                guard result.document.content.chapter.book == position?.chapter.book else { throw ChapterContentError.differentDocument }
                nextDocuments[entry.reference] = result.document
            } catch ChapterAccessFailure.cacheMissing where !network { continue }
            catch { throw error }
        }
        try Task.checkCancellation()
        guard currentIndex == index else { return }
        documents = nextDocuments
        chapters = wanted.compactMap { n in
            documents[entries[n].reference].map { .init(title: entries[n].title, document: $0) }
        }
    }

    private func maintainCache() async throws {
        if let library { cacheUsage = try await library.trimChapterCache(toByteLimit: Self.cacheByteLimit) }
    }

    private func replaceWork(reportAsAdjacent: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        let previous = work; previous?.cancel()
        let id = UUID(); generation = id; isLoading = true
        if reportAsAdjacent { adjacentProblem = nil } else { problem = nil }
        // Owned finite tasks serialize navigation, so a cancelled request is
        // fully settled before a new one can publish a visible window.
        work = Task { [self] in
            await previous?.value
            defer { if generation == id { isLoading = false } }
            do { try Task.checkCancellation(); try await operation() }
            catch {
                guard generation == id, !(error is CancellationError), !Task.isCancelled else { return }
                if reportAsAdjacent { adjacentProblem = .init(error, fallback: "相邻章节暂时无法读取，可重试或从目录选择。") }
                else { fail(error) }
            }
        }
    }

    private func persist(_ position: ReadingPosition) {
        guard !ownershipLost, let library, let session, sequence < Int64.max else { return }
        sequence += 1; let value = sequence
        enqueueSave {
            guard try await library.saveCheckpoint(position, session: session, sequence: value) else { throw Failure.superseded }
        }
    }

    private func enqueueSave(preferences: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        let previous = saves
        saves = Task { [self] in
            await previous?.value
            do {
                try await operation()
                if preferences { preferencesProblem = nil } else { checkpointProblem = nil }
            } catch {
                if case Failure.superseded = error { ownershipLost = true }
                let problem = SourceBrowsingProblem(error, fallback: "阅读位置或设置未能保存，请重试后退出。")
                if preferences { preferencesProblem = problem } else { checkpointProblem = problem }
            }
        }
    }

    private func fail(_ error: any Error) {
        isLoading = false
        if !(error is CancellationError) { problem = .init(error, fallback: "本章暂时无法读取，请重试或从目录选择。") }
    }
}
