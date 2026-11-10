import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase {
    public func captureSourceUpdate(importID: UUID, expected: SourceInstallationSnapshot) throws -> SourceUpdateSnapshot {
        try checkOpen()
        try Task.checkCancellation()
        return try queue.read { db in
            try Self.sourceUpdateSnapshot(db, importID: importID, expected: expected)
        }
    }

    static func sourceUpdateSnapshot(_ db: Database, importID: UUID, expected: SourceInstallationSnapshot) throws -> SourceUpdateSnapshot {
        let current = try Self.installation(db, expected.id)
        guard current == expected else { throw SourceInstallationFailure.staleInstallation }
        guard current.pendingCleanup == nil else { throw SourceInstallationFailure.cleanupPending }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM source_import WHERE id=?",
                                        arguments: [importID.uuidString]) else { throw SourceInstallationFailure.missingImport }
        let candidate = try Self.decodeSourceImport(row)
        let metadata = try Self.importedMetadata(db, importID)
        guard metadata.sourceID.utf8.elementsEqual(current.metadata.sourceID.utf8) else {
            throw SourceInstallationFailure.differentSource
        }
        guard metadata.protocolVersion == current.metadata.protocolVersion else { throw SourceUpdateFailure.unsupportedProtocol }
        guard current.state == .removed || candidate.scriptSHA256 != current.scriptSHA256 else { throw SourceInstallationFailure.alreadyCurrent }
        let id = current.id.rawValue.uuidString
        let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM source_inventory_revision WHERE installation=?", arguments: [id])
        let books = try Row.fetchAll(db, sql: "SELECT * FROM library_book WHERE installation=? ORDER BY id", arguments: [id]).map { row in
            let book = try Self.decodeBook(row)
            let references = try Row.fetchAll(db, sql: """
                SELECT installation, reference_version, remote_key FROM book_reference
                WHERE book_id=? ORDER BY reference_version, remote_key
                """, arguments: [book.id.rawValue.uuidString]).map { item in
                    let raw: String = item["installation"]
                    guard let installation = UUID(uuidString: raw) else { throw Failure.inconsistentData }
                    return try SourceBookReference(installationID: SourceInstallationID(installation),
                                                   referenceVersion: item["reference_version"], key: item["remote_key"])
                }
            return try SourceUpdateBookSnapshot(book: book, references: references,
                chapterReferences: Self.savedChapterReferences(db, book.id),
                catalog: Self.savedCatalog(db, book.id), checkpoint: Self.savedCheckpoint(db, book.id))
        }
        guard books.isEmpty || revision != nil else { throw Failure.inconsistentData }
        return try SourceUpdateSnapshot(installation: current, candidate: candidate, candidateMetadata: metadata,
            inventoryRevision: revision ?? 0, books: books,
            currentState: Self.publicState(db, installationID: current.id, version: current.metadata.stateVersion),
            targetState: Self.publicState(db, installationID: current.id, version: metadata.stateVersion))
    }

    /// SQLite owns invalidation, including writes made by another connection.
    /// Read/write counters cannot be maintained only in an actor's memory.
    static func migrateSourceInventoryRevision(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE source_inventory_revision (
                installation TEXT PRIMARY KEY NOT NULL,
                revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision >= 0)
            );
            INSERT INTO source_inventory_revision SELECT DISTINCT installation, 0 FROM library_book;
            """)
        for (name, definition) in inventoryTriggers(for: ["library_book", "catalog_entry", "reading_checkpoint", "book_reference"]) {
            try db.execute(sql: "CREATE TRIGGER \(name) \(definition)")
        }
        try db.execute(sql: "PRAGMA user_version=6;")
    }

    static func validateSourceInventoryRevisionSchema(_ db: Database) throws {
        _ = try Row.fetchAll(db, sql: "SELECT installation, revision FROM source_inventory_revision LIMIT 0")
        for (name, _) in inventoryTriggers(for: ["library_book", "catalog_entry", "reading_checkpoint", "book_reference"]) {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='trigger' AND name=?)", arguments: [name]) == true else {
                throw Failure.inconsistentData
            }
        }
    }

    static func inventoryTriggers(for tables: [String]) -> [(String, String)] {
        var result: [(String, String)] = []
        for table in tables {
            for action in ["INSERT", "UPDATE", "DELETE"] {
                let owner = action == "DELETE" ? "OLD" : "NEW"
                let selection = table == "library_book" || table == "book_reference"
                    ? "SELECT \(owner).installation, 1"
                    : "SELECT installation, 1 FROM library_book WHERE id=\(owner).book_id"
                // A WHERE in the SELECT disambiguates SQLite's UPSERT grammar.
                let predicate = selection.contains(" WHERE ") ? "" : " WHERE true"
                let timing = action == "DELETE" ? "BEFORE" : "AFTER"
                result.append(("inventory_\(table)_\(action.lowercased())", """
                    \(timing) \(action) ON \(table) BEGIN
                        INSERT INTO source_inventory_revision (installation, revision) \(selection)\(predicate)
                        ON CONFLICT(installation) DO UPDATE SET revision=revision+1;
                    END;
                    """))
            }
        }
        return result
    }
}
