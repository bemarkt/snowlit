import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase {
    /// Retain the exact identity of saved content independently of the current
    /// catalog. Replacing a catalog or checkpoint never erases this inventory.
    static func recordChapterReference(_ db: Database, bookID: LocalBookID, reference: ChapterReference) throws {
        guard try ownsReference(db, bookID: bookID, reference: reference.book) else {
            throw LibraryModelError.differentBook
        }
        let arguments: StatementArguments = [reference.book.installationID.rawValue.uuidString,
            reference.book.referenceVersion, reference.book.key, reference.key]
        if let owner = try String.fetchOne(db, sql: """
            SELECT book_id FROM chapter_reference
            WHERE installation=? AND reference_version=? AND book_key=? AND chapter_key=?
            """, arguments: arguments) {
            guard owner == bookID.rawValue.uuidString else { throw Failure.inconsistentData }
            return
        }
        try db.execute(sql: """
            INSERT INTO chapter_reference (book_id, installation, reference_version, book_key, chapter_key)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [bookID.rawValue.uuidString, reference.book.installationID.rawValue.uuidString,
                reference.book.referenceVersion, reference.book.key, reference.key])
    }

    static func savedChapterReferences(_ db: Database, _ bookID: LocalBookID) throws -> [ChapterReference] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM chapter_reference WHERE book_id=?
            ORDER BY reference_version, book_key, chapter_key
            """, arguments: [bookID.rawValue.uuidString]).map { row in
                let raw: String = row["installation"]
                guard let installation = UUID(uuidString: raw) else { throw Failure.inconsistentData }
                let book = try SourceBookReference(installationID: SourceInstallationID(installation),
                    referenceVersion: row["reference_version"], key: row["book_key"])
                guard try ownsReference(db, bookID: bookID, reference: book) else { throw Failure.inconsistentData }
                return try ChapterReference(book: book, key: row["chapter_key"])
            }
    }

    /// Backfill only references actually retained by schema 6. Earlier versions
    /// did not preserve chapters removed from both the catalog and checkpoint.
    static func migrateChapterReferences(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE chapter_reference (
                book_id TEXT NOT NULL REFERENCES library_book(id) ON DELETE CASCADE,
                installation TEXT NOT NULL,
                reference_version INTEGER NOT NULL CHECK(reference_version > 0),
                book_key TEXT NOT NULL CHECK(length(book_key) > 0),
                chapter_key TEXT NOT NULL CHECK(length(chapter_key) > 0),
                PRIMARY KEY(installation, reference_version, book_key, chapter_key),
                FOREIGN KEY(installation, reference_version, book_key)
                    REFERENCES book_reference(installation, reference_version, remote_key)
            );
            CREATE INDEX chapter_reference_owner ON chapter_reference(book_id);
            """)
        for (name, definition) in inventoryTriggers(for: ["chapter_reference"]) {
            try db.execute(sql: "CREATE TRIGGER \(name) \(definition)")
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM library_book ORDER BY id") {
            let book = try decodeBook(row)
            for entry in try savedCatalog(db, book.id)?.entries ?? [] {
                try recordChapterReference(db, bookID: book.id, reference: entry.reference)
            }
            if let position = try savedCheckpoint(db, book.id)?.position {
                try recordChapterReference(db, bookID: book.id, reference: position.chapter)
            }
        }
        try db.execute(sql: "PRAGMA user_version=7;")
    }

    static func validateChapterReferenceSchema(_ db: Database) throws {
        _ = try Row.fetchAll(db, sql: "SELECT book_id, installation, reference_version, book_key, chapter_key FROM chapter_reference LIMIT 0")
        for (name, _) in inventoryTriggers(for: ["chapter_reference"]) {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='trigger' AND name=?)",
                                   arguments: [name]) == true else { throw Failure.inconsistentData }
        }
    }
}
