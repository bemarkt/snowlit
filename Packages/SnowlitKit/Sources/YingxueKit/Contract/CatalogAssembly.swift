import Foundation
import SnowlitCore

/// Accumulates one source operation's pages. No partial catalog is published.
/// The wire adapter validates each page before passing domain entries here.
public struct CatalogAssembly: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case alreadyFinished
        case invalidated
        case unexpectedCursor
        case repeatedCursor
        case changedRevision
    }

    private let book: SourceBookReference
    private var revision: String?
    private var entries: [CatalogEntry] = []
    private var chapterIDs = Set<ChapterReference>()
    private var cursors = Set<Data>()
    private var nextCursor: String?
    private var finished = false
    private var invalidated = false

    public init(book: SourceBookReference) { self.book = book }

    /// Cursor nil starts the first page or explicitly ends the returned page chain.
    /// Any invalid page permanently invalidates this assembly; retry starts a new operation.
    public mutating func append(requestedCursor: String?, revision: String,
                                entries page: [CatalogEntry], nextCursor: String?) throws -> CatalogSnapshot? {
        guard !invalidated else { throw Failure.invalidated }
        guard !finished else { throw Failure.alreadyFinished }
        do {
            guard requestedCursor.map({ Data($0.utf8) }) == self.nextCursor.map({ Data($0.utf8) }) else {
                throw Failure.unexpectedCursor
            }
            guard !revision.isEmpty else { throw LibraryModelError.invalidRevision }
            if let original = self.revision, !original.utf8.elementsEqual(revision.utf8) { throw Failure.changedRevision }
            if let cursor = nextCursor, cursors.contains(Data(cursor.utf8)) {
                throw Failure.repeatedCursor
            }
            for entry in page {
                guard entry.reference.book == book else { throw LibraryModelError.differentBook }
                guard chapterIDs.insert(entry.reference).inserted else { throw LibraryModelError.duplicateChapter }
            }
            entries.append(contentsOf: page)
            let result = try nextCursor == nil
                ? CatalogSnapshot(book: book, revision: revision, entries: entries) : nil
            self.revision = revision
            self.nextCursor = nextCursor
            if let nextCursor { cursors.insert(Data(nextCursor.utf8)) }
            finished = nextCursor == nil
            return result
        } catch {
            invalidated = true
            throw error
        }
    }
}
