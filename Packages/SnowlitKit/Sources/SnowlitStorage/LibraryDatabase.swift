import Foundation
import GRDB
import SnowlitCore

/// One serialized writer per active library. SQL predicates also protect against
/// independent connections; actor isolation alone cannot prevent stale commits.
public actor LibraryDatabase: LibraryStore {
    public enum Failure: Error, Equatable, Sendable {
        case alreadyExists
        case missingDatabase
        case unsupportedSchema
        case migrationRequired
        case inconsistentData
        case missingBook
        case invalidSequence
        case closed
    }

    let queue: DatabaseQueue
    let chapterFiles: ChapterCacheFiles
    let readOnly: Bool
    private var isClosed = false

    /// Dataset creation must be an explicit first-install/recovery decision.
    /// Opening missing, corrupt or future data never creates a replacement library.
    public static func create(at url: URL) throws -> LibraryDatabase {
        try LibraryDatabase(at: url, create: true, readOnly: false)
    }

    public init(existingAt url: URL, readOnly: Bool = false) throws {
        try self.init(at: url, create: false, readOnly: readOnly)
    }

    private init(at url: URL, create: Bool, readOnly: Bool) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        if create && exists { throw Failure.alreadyExists }
        if !create && !exists { throw Failure.missingDatabase }
        var configuration = Configuration()
        configuration.readonly = readOnly
        if create { configuration.journalMode = .wal }
        configuration.busyMode = .timeout(2)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        if create {
            try queue.write { db in
                try db.execute(sql: Self.schema)
                try db.execute(sql: Self.publicStateSchema)
                try db.execute(sql: Self.sourceScriptSchema)
                try db.execute(sql: Self.sourceInstallationSchema)
                try Self.migrateBookReferences(db)
                try Self.migrateSourceInventoryRevision(db)
                try Self.migrateChapterReferences(db)
                try Self.migrateSourceReferenceHistory(db)
                try Self.migrateChapterCache(db)
            }
        } else {
            let version = try queue.read { db in
                let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
                guard try Int.fetchOne(db, sql: "PRAGMA application_id") == 0x534e4c54,
                      let version, (1...9).contains(version) else {
                    throw Failure.unsupportedSchema
                }
                guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok",
                      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                    throw Failure.inconsistentData
                }
                _ = try Row.fetchAll(db, sql: "SELECT id, installation, reference_version, remote_key, title, author, catalog_request, catalog_revision FROM library_book LIMIT 0")
                _ = try Row.fetchAll(db, sql: "SELECT book_id, ordinal, remote_key, title FROM catalog_entry LIMIT 0")
                _ = try Row.fetchAll(db, sql: "SELECT book_id, session_id, sequence, position FROM reading_checkpoint LIMIT 0")
                _ = try Row.fetchAll(db, sql: "SELECT id, value FROM reader_preferences LIMIT 0")
                if version >= 2 {
                    _ = try Row.fetchAll(db, sql: "SELECT installation, state_version, revision, entries FROM source_public_state LIMIT 0")
                    _ = try Row.fetchAll(db, sql: "SELECT installation, state_version, access_id FROM source_state_access LIMIT 0")
                    _ = try Row.fetchAll(db, sql: "SELECT installation, access_id, request_id, active FROM source_state_operation LIMIT 0")
                }
                if version >= 3 {
                    _ = try Row.fetchAll(db, sql: "SELECT sha256, bytes, metadata FROM source_script LIMIT 0")
                    _ = try Row.fetchAll(db, sql: "SELECT id, script_sha256, inspection_contract_sha256, file_name, imported_at FROM source_import LIMIT 0")
                }
                if version >= 4 {
                    _ = try Row.fetchAll(db, sql: "SELECT id, source_id, import_id, revision, state, configuration, credential_read, website_session, cleanup FROM source_installation LIMIT 0")
                }
                if version >= 5 {
                    _ = try Row.fetchAll(db, sql: "SELECT book_id, installation, reference_version, remote_key FROM book_reference LIMIT 0")
                    _ = try Row.fetchAll(db, sql: "SELECT catalog_reference FROM library_book LIMIT 0")
                }
                if version >= 6 { try Self.validateSourceInventoryRevisionSchema(db) }
                if version >= 7 { try Self.validateChapterReferenceSchema(db) }
                if version >= 8 { try Self.validateSourceReferenceHistorySchema(db) }
                if version >= 9 { try Self.validateChapterCacheSchema(db) }
                return version
            }
            if version != 9 {
                guard !readOnly else { throw Failure.migrationRequired }
                try queue.write { db in
                    guard let current = try Int.fetchOne(db, sql: "PRAGMA user_version"), (1...9).contains(current) else {
                        throw Failure.unsupportedSchema
                    }
                    if current == 1 { try db.execute(sql: Self.publicStateSchema) }
                    if current < 3 { try db.execute(sql: Self.sourceScriptSchema) }
                    if current < 4 { try db.execute(sql: Self.sourceInstallationSchema) }
                    if current < 5 { try Self.migrateBookReferences(db) }
                    if current < 6 { try Self.migrateSourceInventoryRevision(db) }
                    if current < 7 { try Self.migrateChapterReferences(db) }
                    if current < 8 { try Self.migrateSourceReferenceHistory(db) }
                    if current < 9 { try Self.migrateChapterCache(db) }
                }
            }
        }
        self.queue = queue
        self.readOnly = readOnly
        chapterFiles = ChapterCacheFiles(root: url.deletingPathExtension().appendingPathExtension("chapters"))
    }

    /// Exact remote binding is idempotent. Equal titles never merge different books.
    public func addBook(reference: SourceBookReference, title: String, author: String?) throws -> LibraryBook {
        try checkOpen()
        return try queue.write { db in
            try Self.addBook(db, reference: reference, title: title, author: author)
        }
    }

    static func addBook(_ db: Database, reference: SourceBookReference, title: String, author: String?) throws -> LibraryBook {
        let installation = reference.installationID.rawValue.uuidString
        if let row = try Row.fetchOne(db, sql: """
            SELECT b.* FROM library_book b JOIN book_reference r ON r.book_id=b.id
            WHERE r.installation=? AND r.reference_version=? AND r.remote_key=?
            """, arguments: [installation, reference.referenceVersion, reference.key]) {
            return try Self.decodeBook(row)
        }
        let book = LibraryBook(id: LocalBookID(), reference: reference, title: title, author: author)
        try db.execute(sql: """
            INSERT INTO library_book (id, installation, reference_version, remote_key, title, author)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [book.id.rawValue.uuidString, installation, reference.referenceVersion,
                              reference.key, title, author])
        try Self.recordBookReference(db, bookID: book.id, reference: reference)
        return book
    }

    public func books() throws -> [LibraryBook] {
        try checkOpen()
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM library_book ORDER BY rowid").map(Self.decodeBook)
        }
    }

    public func beginCatalogUpdate(for bookID: LocalBookID) throws -> CatalogWriteToken {
        try checkOpen()
        let token = CatalogWriteToken(bookID: bookID, requestID: UUID())
        try queue.write { db in
            guard try Self.decodeBook(Self.bookRow(db, bookID)).networkReference != nil else {
                throw LibraryModelError.unavailableReference
            }
            try db.execute(sql: "UPDATE library_book SET catalog_request=? WHERE id=?",
                           arguments: [token.requestID.uuidString, bookID.rawValue.uuidString])
            guard db.changesCount == 1 else { throw Failure.missingBook }
        }
        return token
    }

    /// A newer request invalidates old responses even if they finish later.
    /// Validation/replacement/activation commit atomically; failure keeps the old catalog.
    @discardableResult
    public func publishCatalog(_ catalog: CatalogSnapshot, using token: CatalogWriteToken) throws -> Bool {
        try checkOpen()
        return try queue.write { db in
            let row = try Self.bookRow(db, token.bookID)
            let request: String? = row["catalog_request"]
            guard request == token.requestID.uuidString else { return false }
            guard try Self.decodeBook(row).networkReference == catalog.book else {
                throw LibraryModelError.differentBook
            }
            try Self.replaceCatalog(db, catalog: catalog, bookID: token.bookID)
            return true
        }
    }

    static func replaceCatalog(_ db: Database, catalog: CatalogSnapshot, bookID: LocalBookID) throws {
        let id = bookID.rawValue.uuidString
        try db.execute(sql: "DELETE FROM catalog_entry WHERE book_id=?", arguments: [id])
        for (ordinal, entry) in catalog.entries.enumerated() {
            try Self.recordChapterReference(db, bookID: bookID, reference: entry.reference)
            try db.execute(sql: "INSERT INTO catalog_entry (book_id, ordinal, remote_key, title) VALUES (?, ?, ?, ?)",
                           arguments: [id, ordinal, entry.reference.key, entry.title])
        }
        try db.execute(sql: "UPDATE library_book SET catalog_revision=?, catalog_reference=?, catalog_request=NULL WHERE id=?",
                       arguments: [catalog.revision, try JSONEncoder().encode(catalog.book), id])
    }

    public func catalog(for bookID: LocalBookID) throws -> CatalogSnapshot? {
        try checkOpen()
        return try queue.read { db in
            try Self.savedCatalog(db, bookID)
        }
    }

    public func startReading(_ bookID: LocalBookID) throws -> ReadingSession {
        try checkOpen()
        let session = ReadingSession(bookID: bookID, id: UUID())
        try queue.write { db in
            _ = try Self.bookRow(db, bookID)
            try db.execute(sql: """
                INSERT INTO reading_checkpoint (book_id, session_id, sequence, position) VALUES (?, ?, 0, NULL)
                ON CONFLICT(book_id) DO UPDATE SET session_id=excluded.session_id, sequence=0
                """, arguments: [bookID.rawValue.uuidString, session.id.uuidString])
        }
        return session
    }

    @discardableResult
    public func saveCheckpoint(_ position: ReadingPosition, session: ReadingSession, sequence: Int64) throws -> Bool {
        try checkOpen()
        guard sequence > 0 else { throw Failure.invalidSequence }
        let encoded = try JSONEncoder().encode(position)
        return try queue.write { db in
            _ = try Self.bookRow(db, session.bookID)
            guard try Self.ownsReference(db, bookID: session.bookID, reference: position.chapter.book) else {
                throw LibraryModelError.differentBook
            }
            try db.execute(sql: """
                UPDATE reading_checkpoint SET sequence=?, position=?
                WHERE book_id=? AND session_id=? AND sequence < ?
                """, arguments: [sequence, encoded, session.bookID.rawValue.uuidString, session.id.uuidString, sequence])
            let saved = db.changesCount == 1
            if saved { try Self.recordChapterReference(db, bookID: session.bookID, reference: position.chapter) }
            return saved
        }
    }

    public func checkpoint(for bookID: LocalBookID) throws -> ReadingCheckpoint? {
        try checkOpen()
        return try queue.read { db in
            try Self.savedCheckpoint(db, bookID)
        }
    }

    public func preferences() throws -> ReaderPreferences {
        try checkOpen()
        return try queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM reader_preferences WHERE id=1") else {
                return .defaults
            }
            return try JSONDecoder().decode(ReaderPreferences.self, from: data)
        }
    }

    public func savePreferences(_ preferences: ReaderPreferences) throws {
        try checkOpen()
        let encoded = try JSONEncoder().encode(preferences)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reader_preferences (id, value) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET value=excluded.value
                """, arguments: [encoded])
        }
    }

    public func close() throws {
        guard !isClosed else { return }
        try queue.close()
        isClosed = true
    }

    func checkOpen() throws {
        guard !isClosed else { throw Failure.closed }
    }

    static func bookRow(_ db: Database, _ id: LocalBookID) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM library_book WHERE id=?",
                                        arguments: [id.rawValue.uuidString]) else { throw Failure.missingBook }
        return row
    }

    static func decodeBook(_ row: Row) throws -> LibraryBook {
        let rawID: String = row["id"]
        let rawInstallation: String = row["installation"]
        guard let id = UUID(uuidString: rawID), let installation = UUID(uuidString: rawInstallation) else {
            throw Failure.inconsistentData
        }
        // Earlier migrations decode books before schema 8 adds this column.
        let rawInvalidation: String? = row.columnNames.contains("reference_invalidation") ? row["reference_invalidation"] : nil
        let invalidation = rawInvalidation.flatMap(SourceReferenceInvalidation.init(rawValue:))
        guard rawInvalidation == nil || invalidation != nil else { throw Failure.inconsistentData }
        return try LibraryBook(id: LocalBookID(id),
            reference: SourceBookReference(installationID: SourceInstallationID(installation),
                                           referenceVersion: row["reference_version"], key: row["remote_key"]),
            title: row["title"], author: row["author"], referenceInvalidation: invalidation)
    }

    private static let schema = """
        CREATE TABLE library_book (
            id TEXT PRIMARY KEY NOT NULL,
            installation TEXT NOT NULL,
            reference_version INTEGER NOT NULL CHECK(reference_version > 0),
            remote_key TEXT NOT NULL CHECK(length(remote_key) > 0),
            title TEXT NOT NULL,
            author TEXT,
            catalog_request TEXT,
            catalog_revision TEXT,
            UNIQUE(installation, reference_version, remote_key)
        );
        CREATE TABLE catalog_entry (
            book_id TEXT NOT NULL REFERENCES library_book(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            remote_key TEXT NOT NULL CHECK(length(remote_key) > 0),
            title TEXT NOT NULL,
            PRIMARY KEY(book_id, remote_key),
            UNIQUE(book_id, ordinal)
        );
        CREATE TABLE reading_checkpoint (
            book_id TEXT PRIMARY KEY NOT NULL REFERENCES library_book(id) ON DELETE CASCADE,
            session_id TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK(sequence >= 0),
            position BLOB
        );
        CREATE TABLE reader_preferences (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            value BLOB NOT NULL
        );
        PRAGMA application_id = 0x534e4c54;
        PRAGMA user_version = 1;
        """
}
