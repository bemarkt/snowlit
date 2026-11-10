import Foundation

public struct LibraryBook: Equatable, Sendable {
    public let id: LocalBookID
    public let reference: SourceBookReference
    public let title: String
    public let author: String?

    public init(id: LocalBookID, reference: SourceBookReference, title: String, author: String?) {
        self.id = id
        self.reference = reference
        self.title = title
        self.author = author
    }
}

public struct CatalogEntry: Equatable, Codable, Sendable {
    public let reference: ChapterReference
    public let title: String

    public init(reference: ChapterReference, title: String) {
        self.reference = reference
        self.title = title
    }
}

/// A complete ordered catalog. Partial pages remain outside persistent active state.
public struct CatalogSnapshot: Equatable, Codable, Sendable {
    public let book: SourceBookReference
    public let revision: String
    public let entries: [CatalogEntry]

    public init(book: SourceBookReference, revision: String, entries: [CatalogEntry]) throws {
        guard !revision.isEmpty else { throw LibraryModelError.invalidRevision }
        guard !entries.isEmpty else { throw LibraryModelError.emptyCatalog }
        var seen = Set<ChapterReference>()
        for entry in entries {
            guard entry.reference.book == book else { throw LibraryModelError.differentBook }
            guard seen.insert(entry.reference).inserted else { throw LibraryModelError.duplicateChapter }
        }
        self.book = book
        self.revision = revision
        self.entries = entries
    }

    private enum CodingKeys: CodingKey { case book, revision, entries }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(book: values.decode(SourceBookReference.self, forKey: .book),
                      revision: values.decode(String.self, forKey: .revision),
                      entries: values.decode([CatalogEntry].self, forKey: .entries))
    }
}

/// Revision-qualified semantic position, independent of layout and website login.
/// A document projection must additionally validate its element and grapheme boundary.
public struct ReadingPosition: Equatable, Codable, Sendable {
    public let chapter: ChapterReference
    public let documentRevision: String
    public let normalizationVersion: Int
    public let elementID: String
    public let utf16Offset: Int

    public init(chapter: ChapterReference, documentRevision: String, normalizationVersion: Int,
                elementID: String, utf16Offset: Int) throws {
        guard !documentRevision.isEmpty, normalizationVersion > 0,
              !elementID.isEmpty, utf16Offset >= 0 else { throw LibraryModelError.invalidPosition }
        self.chapter = chapter
        self.documentRevision = documentRevision
        self.normalizationVersion = normalizationVersion
        self.elementID = elementID
        self.utf16Offset = utf16Offset
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chapter == rhs.chapter && lhs.documentRevision.utf8.elementsEqual(rhs.documentRevision.utf8)
            && lhs.normalizationVersion == rhs.normalizationVersion
            && lhs.elementID.utf8.elementsEqual(rhs.elementID.utf8) && lhs.utf16Offset == rhs.utf16Offset
    }

    private enum CodingKeys: CodingKey {
        case chapter, documentRevision, normalizationVersion, elementID, utf16Offset
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(chapter: values.decode(ChapterReference.self, forKey: .chapter),
                      documentRevision: values.decode(String.self, forKey: .documentRevision),
                      normalizationVersion: values.decode(Int.self, forKey: .normalizationVersion),
                      elementID: values.decode(String.self, forKey: .elementID),
                      utf16Offset: values.decode(Int.self, forKey: .utf16Offset))
    }
}

public struct ReaderPreferences: Equatable, Codable, Sendable {
    public enum Theme: String, Codable, Sendable { case system, light, dark }
    public let fontSize: Double
    public let theme: Theme

    public static let defaults = ReaderPreferences()
    private init() { fontSize = 20; theme = .system }

    public init(fontSize: Double, theme: Theme) throws {
        guard fontSize.isFinite, fontSize > 0 else { throw LibraryModelError.invalidPreferences }
        self.fontSize = fontSize
        self.theme = theme
    }

    private enum CodingKeys: CodingKey { case fontSize, theme }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fontSize: values.decode(Double.self, forKey: .fontSize),
                      theme: values.decode(Theme.self, forKey: .theme))
    }
}

public struct CatalogWriteToken: Equatable, Sendable {
    public let bookID: LocalBookID
    public let requestID: UUID
    public init(bookID: LocalBookID, requestID: UUID) {
        self.bookID = bookID; self.requestID = requestID
    }
}

public struct ReadingSession: Equatable, Sendable {
    public let bookID: LocalBookID
    public let id: UUID
    public init(bookID: LocalBookID, id: UUID) { self.bookID = bookID; self.id = id }
}

public struct ReadingCheckpoint: Equatable, Sendable {
    public let session: ReadingSession
    public let sequence: Int64
    public let position: ReadingPosition?
    public init(session: ReadingSession, sequence: Int64, position: ReadingPosition?) {
        self.session = session; self.sequence = sequence; self.position = position
    }
}

/// The local library boundary. Authentication is not an input to any operation.
public protocol LibraryStore: Sendable {
    func addBook(reference: SourceBookReference, title: String, author: String?) async throws -> LibraryBook
    func books() async throws -> [LibraryBook]
    func beginCatalogUpdate(for bookID: LocalBookID) async throws -> CatalogWriteToken
    func publishCatalog(_ catalog: CatalogSnapshot, using token: CatalogWriteToken) async throws -> Bool
    func catalog(for bookID: LocalBookID) async throws -> CatalogSnapshot?
    func startReading(_ bookID: LocalBookID) async throws -> ReadingSession
    func saveCheckpoint(_ position: ReadingPosition, session: ReadingSession, sequence: Int64) async throws -> Bool
    func checkpoint(for bookID: LocalBookID) async throws -> ReadingCheckpoint?
    func preferences() async throws -> ReaderPreferences
    func savePreferences(_ preferences: ReaderPreferences) async throws
}
