import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase {
    /// References identify saved content as well as current network bindings.
    /// Register a validated mapping in the same transaction as its adoption.
    /// A historical identity can never be reassigned to another local book.
    static func recordBookReference(_ db: Database, bookID: LocalBookID, reference: SourceBookReference) throws {
        let book = try decodeBook(bookRow(db, bookID))
        guard book.reference.installationID == reference.installationID else { throw LibraryModelError.differentBook }
        let owner = try String.fetchOne(db, sql: """
            SELECT book_id FROM book_reference WHERE installation=? AND reference_version=? AND remote_key=?
            """, arguments: [reference.installationID.rawValue.uuidString, reference.referenceVersion, reference.key])
        if let owner {
            guard owner == bookID.rawValue.uuidString else { throw LibraryModelError.differentBook }
            return
        }
        try db.execute(sql: """
            INSERT INTO book_reference (book_id, installation, reference_version, remote_key) VALUES (?, ?, ?, ?)
            """, arguments: [bookID.rawValue.uuidString, reference.installationID.rawValue.uuidString,
                              reference.referenceVersion, reference.key])
    }

    static func ownsReference(_ db: Database, bookID: LocalBookID, reference: SourceBookReference) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM book_reference
                WHERE book_id=? AND installation=? AND reference_version=? AND remote_key=?)
            """, arguments: [bookID.rawValue.uuidString, reference.installationID.rawValue.uuidString,
                              reference.referenceVersion, reference.key]) == true
    }

    static func savedCatalog(_ db: Database, _ bookID: LocalBookID) throws -> CatalogSnapshot? {
        let row = try bookRow(db, bookID)
        let encoded: Data? = row["catalog_reference"]
        guard let revision: String = row["catalog_revision"] else {
            guard encoded == nil else { throw Failure.inconsistentData }
            return nil
        }
        guard let encoded else { throw Failure.inconsistentData }
        let reference = try JSONDecoder().decode(SourceBookReference.self, from: encoded)
        guard try ownsReference(db, bookID: bookID, reference: reference) else { throw Failure.inconsistentData }
        let entries = try Row.fetchAll(db, sql: "SELECT * FROM catalog_entry WHERE book_id=? ORDER BY ordinal",
                                      arguments: [bookID.rawValue.uuidString]).map { item in
            try CatalogEntry(reference: ChapterReference(book: reference, key: item["remote_key"]), title: item["title"])
        }
        return try CatalogSnapshot(book: reference, revision: revision, entries: entries)
    }

    static func savedCheckpoint(_ db: Database, _ bookID: LocalBookID) throws -> ReadingCheckpoint? {
        _ = try bookRow(db, bookID)
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM reading_checkpoint WHERE book_id=?",
                                        arguments: [bookID.rawValue.uuidString]) else { return nil }
        let rawSession: String = row["session_id"]
        guard let id = UUID(uuidString: rawSession) else { throw Failure.inconsistentData }
        let encoded: Data? = row["position"]
        let position = try encoded.map { try JSONDecoder().decode(ReadingPosition.self, from: $0) }
        if let position, try !ownsReference(db, bookID: bookID, reference: position.chapter.book) {
            throw Failure.inconsistentData
        }
        return ReadingCheckpoint(session: ReadingSession(bookID: bookID, id: id), sequence: row["sequence"], position: position)
    }

    /// Schema 4 -> 5 preserves the only reference semantics known to earlier
    /// versions. An inconsistent old checkpoint aborts the entire migration.
    static func migrateBookReferences(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE book_reference (
                book_id TEXT NOT NULL REFERENCES library_book(id) ON DELETE CASCADE,
                installation TEXT NOT NULL,
                reference_version INTEGER NOT NULL CHECK(reference_version > 0),
                remote_key TEXT NOT NULL CHECK(length(remote_key) > 0),
                PRIMARY KEY(installation, reference_version, remote_key)
            );
            CREATE INDEX book_reference_owner ON book_reference(book_id);
            ALTER TABLE library_book ADD COLUMN catalog_reference BLOB;
            """)
        for row in try Row.fetchAll(db, sql: "SELECT * FROM library_book ORDER BY rowid") {
            let book = try decodeBook(row)
            try recordBookReference(db, bookID: book.id, reference: book.reference)
            if let _: String = row["catalog_revision"] {
                try db.execute(sql: "UPDATE library_book SET catalog_reference=? WHERE id=?",
                               arguments: [try JSONEncoder().encode(book.reference), book.id.rawValue.uuidString])
                _ = try savedCatalog(db, book.id)
            }
            _ = try savedCheckpoint(db, book.id)
        }
        try db.execute(sql: "PRAGMA user_version=5;")
    }
}
