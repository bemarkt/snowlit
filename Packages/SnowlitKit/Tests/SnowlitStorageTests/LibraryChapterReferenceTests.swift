import Foundation
import GRDB
import SnowlitCore
import Testing
@testable import SnowlitStorage

func removeChapterReferenceSchema(_ db: Database) throws {
    for action in ["insert", "update", "delete"] {
        try db.execute(sql: "DROP TRIGGER inventory_chapter_reference_\(action)")
    }
    try db.execute(sql: "DROP TABLE chapter_reference")
}

struct LibraryChapterReferenceTests {
    @Test func replacementCatalogAndCheckpointRetainEveryExactSavedIdentityAcrossReopen() async throws {
        try await withLibrary { path, db, book in
            let first = try ChapterReference(book: book.reference, key: "é")
            let second = try ChapterReference(book: book.reference, key: "e\u{301}")
            let outside = try ChapterReference(book: book.reference, key: "outside-catalog")
            try await publish([first, second], book: book, db: db)
            try await publish([second], book: book, db: db)
            let reader = try await db.startReading(book.id)
            #expect(try await db.saveCheckpoint(position(outside), session: reader, sequence: 1))
            #expect(try await db.saveCheckpoint(position(second), session: reader, sequence: 2))
            #expect(Set(try await references(db, book)) == [first, second, outside])
            #expect(try await db.catalog(for: book.id)?.entries.map(\.reference) == [second])
            #expect(try await db.checkpoint(for: book.id)?.position?.chapter == second)
            try await db.close()
            let reopened = try LibraryDatabase(existingAt: path, readOnly: true)
            #expect(Set(try await references(reopened, book)) == [first, second, outside])
            try await reopened.close()
        }
    }

    @Test func staleResponsesAndUnownedReferencesCannotExtendTheInventory() async throws {
        try await withLibrary { _, db, book in
            let old = try await db.startReading(book.id)
            let reader = try await db.startReading(book.id)
            let retained = try ChapterReference(book: book.reference, key: "retained")
            let rejected = try ChapterReference(book: book.reference, key: "rejected")
            #expect(try await db.saveCheckpoint(position(retained), session: reader, sequence: 2))
            #expect(try await !db.saveCheckpoint(position(rejected), session: old, sequence: 3))
            #expect(try await !db.saveCheckpoint(position(rejected), session: reader, sequence: 1))
            let stale = try await db.beginCatalogUpdate(for: book.id)
            _ = try await db.beginCatalogUpdate(for: book.id)
            #expect(try await !db.publishCatalog(catalog([rejected], book: book), using: stale))
            let foreign = try ChapterReference(book: .init(installationID: book.reference.installationID,
                referenceVersion: 1, key: "foreign"), key: "chapter")
            await #expect(throws: LibraryModelError.differentBook) {
                try await db.saveCheckpoint(position(foreign), session: reader, sequence: 3)
            }
            #expect(try await references(db, book) == [retained])
        }
    }

    @Test func referenceWriteFailureRollsBackCatalogCheckpointAndInventoryRevision() async throws {
        try await withLibrary { _, db, book in
            let retained = try ChapterReference(book: book.reference, key: "retained")
            try await publish([retained], book: book, db: db)
            let session = try await db.startReading(book.id)
            #expect(try await db.saveCheckpoint(position(retained), session: session, sequence: 1))
            let token = try await db.beginCatalogUpdate(for: book.id)
            let beforeCatalog = try await db.catalog(for: book.id)
            let beforePosition = try await db.checkpoint(for: book.id)
            let revision = try await inventoryRevision(db, book)
            try await db.queue.write { try $0.execute(sql: """
                CREATE TRIGGER reject_chapter BEFORE INSERT ON chapter_reference
                WHEN NEW.chapter_key='reject' BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
                """) }
            let first = try ChapterReference(book: book.reference, key: "new")
            let rejected = try ChapterReference(book: book.reference, key: "reject")
            await #expect(throws: DatabaseError.self) {
                try await db.publishCatalog(catalog([first, rejected], book: book), using: token)
            }
            await #expect(throws: DatabaseError.self) {
                try await db.saveCheckpoint(position(rejected), session: session, sequence: 2)
            }
            #expect(try await db.catalog(for: book.id) == beforeCatalog)
            #expect(try await db.checkpoint(for: book.id) == beforePosition)
            #expect(try await references(db, book) == [retained])
            #expect(try await inventoryRevision(db, book) == revision)
            try await db.queue.write { try $0.execute(sql: "DROP TRIGGER reject_chapter") }
            #expect(try await db.publishCatalog(catalog([first, rejected], book: book), using: token))
        }
    }

    @Test func secondConnectionInvalidatesPreparedInputsAndDuplicateRegistrationIsReadOnly() async throws {
        try await withLibrary { path, first, book in
            let second = try LibraryDatabase(existingAt: path)
            let reference = try ChapterReference(book: book.reference, key: "retained")
            let before = try await inventoryRevision(first, book)
            try await second.queue.write { try LibraryDatabase.recordChapterReference($0, bookID: book.id, reference: reference) }
            let changed = try await inventoryRevision(first, book)
            #expect(changed > before)
            #expect(try await references(first, book) == [reference])
            try await second.queue.write { try LibraryDatabase.recordChapterReference($0, bookID: book.id, reference: reference) }
            #expect(try await inventoryRevision(first, book) == changed)
            try await second.close()
        }
    }

    @Test func schemaSixBackfillsOriginalCatalogAndCheckpointReferencesWithoutRelabeling() async throws {
        try await withLibrary { path, db, original in
            let oldChapter = try ChapterReference(book: original.reference, key: "old")
            try await publish([oldChapter], book: original, db: db)
            let checkpointOnly = try ChapterReference(book: original.reference, key: "checkpoint-only")
            let session = try await db.startReading(original.id)
            #expect(try await db.saveCheckpoint(position(checkpointOnly), session: session, sequence: 1))
            let active = try SourceBookReference(installationID: original.reference.installationID, referenceVersion: 2, key: "current")
            try await db.queue.write { sql in
                try LibraryDatabase.recordBookReference(sql, bookID: original.id, reference: active)
                try sql.execute(sql: "UPDATE library_book SET reference_version=2, remote_key='current' WHERE id=?",
                    arguments: [original.id.rawValue.uuidString])
                try removeChapterReferenceSchema(sql)
                try sql.execute(sql: "PRAGMA user_version=6")
            }
            try await db.close()
            #expect(throws: LibraryDatabase.Failure.migrationRequired) { try LibraryDatabase(existingAt: path, readOnly: true) }
            let upgraded = try LibraryDatabase(existingAt: path)
            #expect(Set(try await references(upgraded, original)) == [oldChapter, checkpointOnly])
            #expect(try await upgraded.books().first?.reference == active)
            #expect(try await upgraded.catalog(for: original.id)?.book == original.reference)
            #expect(try await upgraded.checkpoint(for: original.id)?.position?.chapter == checkpointOnly)
            try await upgraded.close()
        }
    }

    @Test func failedSchemaUpgradeRollsBackBackfillTableAndTriggers() async throws {
        try await withLibrary { path, db, book in
            try await db.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { sql in
                try removeChapterReferenceSchema(sql)
                try sql.execute(sql: """
                    CREATE TRIGGER inventory_chapter_reference_update AFTER UPDATE ON library_book BEGIN SELECT 1; END;
                    PRAGMA user_version=6;
                    """)
            }
            #expect(throws: DatabaseError.self) { try LibraryDatabase(existingAt: path) }
            let result = try await raw.read { sql in
                try (Int.fetchOne(sql, sql: "PRAGMA user_version"),
                     Int.fetchOne(sql, sql: "SELECT count(*) FROM sqlite_master WHERE name='chapter_reference'"),
                     Int.fetchOne(sql, sql: "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'inventory_chapter_reference_%'"),
                     String.fetchOne(sql, sql: "SELECT id FROM library_book"))
            }
            #expect(result.0 == 6 && result.1 == 0 && result.2 == 1 && result.3 == book.id.rawValue.uuidString)
            try raw.close()
        }
    }

    @Test func missingInventoryTriggerRejectsReopen() async throws {
        try await withLibrary { path, db, _ in
            try await db.queue.write { try $0.execute(sql: "DROP TRIGGER inventory_chapter_reference_insert") }
            try await db.close()
            #expect(throws: LibraryDatabase.Failure.inconsistentData) { try LibraryDatabase(existingAt: path) }
        }
    }

    private func references(_ db: LibraryDatabase, _ book: LibraryBook) async throws -> [ChapterReference] {
        try await db.queue.read { try LibraryDatabase.savedChapterReferences($0, book.id) }
    }
    private func inventoryRevision(_ db: LibraryDatabase, _ book: LibraryBook) async throws -> Int64 {
        try await db.queue.read { try #require(try Int64.fetchOne($0, sql: "SELECT revision FROM source_inventory_revision WHERE installation=?",
            arguments: [book.reference.installationID.rawValue.uuidString])) }
    }
    private func catalog(_ references: [ChapterReference], book: LibraryBook) throws -> CatalogSnapshot {
        try .init(book: book.reference, revision: "catalog", entries: references.map { .init(reference: $0, title: "Chapter") })
    }
    private func publish(_ references: [ChapterReference], book: LibraryBook, db: LibraryDatabase) async throws {
        let token = try await db.beginCatalogUpdate(for: book.id)
        #expect(try await db.publishCatalog(catalog(references, book: book), using: token))
    }
    private func position(_ chapter: ChapterReference) throws -> ReadingPosition {
        try .init(chapter: chapter, documentRevision: "saved", normalizationVersion: 1, elementID: "p", utf16Offset: 2)
    }
    private func withLibrary(_ body: (URL, LibraryDatabase, LibraryBook) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitChapterReferences-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove isolated reference data") }
        }
        let path = root.appendingPathComponent("library.sqlite")
        let db = try LibraryDatabase.create(at: path)
        do {
            let book = try await db.addBook(reference: .init(installationID: SourceInstallationID(), referenceVersion: 1, key: "book"), title: "Saved", author: nil)
            try await body(path, db, book)
            try await db.close()
        } catch {
            do { try await db.close() } catch { Issue.record(error, "Unable to close reference fixture") }
            throw error
        }
    }
}
