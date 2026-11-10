import Foundation
import Observation
import SnowlitCore

@MainActor
@Observable
final class LibraryShelfModel {
    private(set) var books: [LibraryBook] = []
    private(set) var isLoading = false
    private(set) var problem: SourceBrowsingProblem?
    @ObservationIgnored private let load: @Sendable () async throws -> [LibraryBook]
    @ObservationIgnored private let loadCatalog: @Sendable (LocalBookID) async throws -> CatalogSnapshot?
    @ObservationIgnored let makeReader: (@MainActor (LibraryBook, ChapterReference?) -> ReaderModel)?
    @ObservationIgnored private var generation: UUID?

    init(load: @escaping @Sendable () async throws -> [LibraryBook],
         loadCatalog: @escaping @Sendable (LocalBookID) async throws -> CatalogSnapshot?,
         makeReader: (@MainActor (LibraryBook, ChapterReference?) -> ReaderModel)? = nil) {
        self.load = load; self.loadCatalog = loadCatalog; self.makeReader = makeReader
    }

    func refresh() async {
        let id = UUID(); generation = id; isLoading = true; problem = nil
        defer { if generation == id { isLoading = false } }
        do {
            let books = try await load()
            try Task.checkCancellation()
            if generation == id { self.books = books }
        } catch {
            if generation == id && !(error is CancellationError) && !Task.isCancelled {
                problem = .init(error, fallback: "无法读取本地书架，请重试。")
            }
        }
    }

    func catalog(for book: LocalBookID) async throws -> CatalogSnapshot? { try await loadCatalog(book) }
}
