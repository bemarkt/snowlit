import Foundation
import GRDB
import SnowlitCore
import Testing
@testable import SnowlitStorage

struct LibraryBookReferenceTests {
    @Test func schemaFourUpgradePreservesCatalogAndCheckpointAndReopensReadonly() async throws {
        try await withLibrary { path, database in
            let (book, catalog, session, position) = try await seed(database)
            try await database.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try $0.execute(sql: Self.schemaFour) }
            try raw.close()
            let before = try Data(contentsOf: path)
            #expect(throws: LibraryDatabase.Failure.migrationRequired) { try LibraryDatabase(existingAt: path, readOnly: true) }
            #expect(try Data(contentsOf: path) == before)
            let upgraded = try LibraryDatabase(existingAt: path)
            #expect(try await upgraded.books() == [book])
            #expect(try await upgraded.catalog(for: book.id) == catalog)
            #expect(try await upgraded.checkpoint(for: book.id) == .init(session: session, sequence: 1, position: position))
            try await upgraded.close()
            let reader = try LibraryDatabase(existingAt: path, readOnly: true)
            #expect(try await reader.catalog(for: book.id) == catalog)
            #expect(try await reader.checkpoint(for: book.id)?.position == position)
            try await reader.close()
        }
    }

    @Test func migratedBindingCannotRelabelSavedCatalogOrOfflineProgress() async throws {
        try await withLibrary { path, database in
            let (book, catalog, session, position) = try await seed(database)
            let replacement = try SourceBookReference(installationID: book.reference.installationID, referenceVersion: 2, key: "new-book")
            try await moveBinding(database, book.id, to: replacement)
            #expect(try await database.books().first?.reference == replacement)
            #expect(try await database.catalog(for: book.id) == catalog)
            #expect(try await database.checkpoint(for: book.id)?.position == position)
            // An existing offline reader still writes its original document identity.
            let later = try ReadingPosition(chapter: position.chapter, documentRevision: position.documentRevision,
                normalizationVersion: 1, elementID: position.elementID, utf16Offset: 12)
            #expect(try await database.saveCheckpoint(later, session: session, sequence: 2))
            #expect(try await !database.saveCheckpoint(position, session: session, sequence: 1))
            let request = try await database.beginCatalogUpdate(for: book.id)
            await #expect(throws: LibraryModelError.differentBook) { try await database.publishCatalog(catalog, using: request) }
            let refreshed = try CatalogSnapshot(book: replacement, revision: "new-catalog", entries: [
                .init(reference: .init(book: replacement, key: "new-chapter"), title: "New")])
            #expect(try await database.publishCatalog(refreshed, using: request))
            #expect(try await database.checkpoint(for: book.id)?.position == later)
            try await database.close()
            let reopened = try LibraryDatabase(existingAt: path)
            #expect(try await reopened.catalog(for: book.id) == refreshed)
            #expect(try await reopened.checkpoint(for: book.id)?.position == later)
            let nextSession = try await reopened.startReading(book.id)
            #expect(try await reopened.checkpoint(for: book.id)?.position == later)
            #expect(try await !reopened.saveCheckpoint(position, session: session, sequence: 99))
            #expect(try await reopened.saveCheckpoint(position, session: nextSession, sequence: 1))
            try await reopened.close()
        }
    }

    @Test func historicalIdentityIsIdempotentAndCannotMoveBetweenBooksOrInstallations() async throws {
        try await withLibrary { _, database in
            let (book, _, _, _) = try await seed(database)
            let next = try SourceBookReference(installationID: book.reference.installationID, referenceVersion: 2, key: "new")
            try await moveBinding(database, book.id, to: next)
            let original = try await database.addBook(reference: book.reference, title: "Do not replace", author: nil)
            let current = try await database.addBook(reference: next, title: "Do not replace", author: nil)
            #expect(original == current && original.id == book.id && original.title == book.title)
            let other = try await database.addBook(reference: .init(installationID: next.installationID, referenceVersion: 2, key: "other"), title: "Other", author: nil)
            await #expect(throws: LibraryModelError.differentBook) { try await moveBinding(database, other.id, to: book.reference) }
            let alien = try SourceBookReference(installationID: SourceInstallationID(), referenceVersion: 2, key: "new")
            await #expect(throws: LibraryModelError.differentBook) { try await moveBinding(database, book.id, to: alien) }
            #expect(try await database.books().map(\.reference) == [next, other.reference])
            let session = try await database.startReading(other.id)
            let wrong = try ReadingPosition(chapter: .init(book: book.reference, key: "chapter"), documentRevision: "saved", normalizationVersion: 1, elementID: "p", utf16Offset: 1)
            await #expect(throws: LibraryModelError.differentBook) { try await database.saveCheckpoint(wrong, session: session, sequence: 1) }
            let a = try await database.addBook(reference: .init(installationID: next.installationID, referenceVersion: 1, key: "\u{00E9}"), title: "A", author: nil)
            let b = try await database.addBook(reference: .init(installationID: next.installationID, referenceVersion: 1, key: "e\u{0301}"), title: "B", author: nil)
            #expect(a.id != b.id)
        }
    }

    @Test func invalidOldCheckpointRollsBackSchemaAndEarlierBackfill() async throws {
        try await withLibrary { path, database in
            let (book, catalog, _, position) = try await seed(database)
            let (other, _, _, _) = try await seed(database)
            try await database.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { db in
                try db.execute(sql: Self.schemaFour)
                try db.execute(sql: "UPDATE reading_checkpoint SET position=? WHERE book_id=?",
                    arguments: [try JSONEncoder().encode(position), other.id.rawValue.uuidString])
            }
            #expect(throws: LibraryDatabase.Failure.inconsistentData) { try LibraryDatabase(existingAt: path) }
            let result = try await raw.read { db in
                try (Int.fetchOne(db, sql: "PRAGMA user_version"),
                     Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name='book_reference'"),
                     Row.fetchAll(db, sql: "PRAGMA table_info(library_book)").map { (row: Row) -> String in row["name"] },
                     String.fetchOne(db, sql: "SELECT catalog_revision FROM library_book WHERE id=?", arguments: [book.id.rawValue.uuidString]))
            }
            #expect(result.0 == 4 && result.1 == 0 && !result.2.contains("catalog_reference") && result.3 == catalog.revision)
            try raw.close()
        }
    }

    @Test func unknownSnapshotReferenceIsNotAcceptedAsHistoricalContent() async throws {
        try await withLibrary { _, database in
            let (book, _, _, position) = try await seed(database)
            let unknown = try SourceBookReference(installationID: book.reference.installationID, referenceVersion: 99, key: book.reference.key)
            let wrongPosition = try ReadingPosition(chapter: .init(book: unknown, key: "chapter"), documentRevision: position.documentRevision,
                normalizationVersion: 1, elementID: "p", utf16Offset: 0)
            try await database.queue.write { db in
                try db.execute(sql: "UPDATE library_book SET catalog_reference=? WHERE id=?",
                    arguments: [try JSONEncoder().encode(unknown), book.id.rawValue.uuidString])
                try db.execute(sql: "UPDATE reading_checkpoint SET position=? WHERE book_id=?",
                    arguments: [try JSONEncoder().encode(wrongPosition), book.id.rawValue.uuidString])
            }
            await #expect(throws: LibraryDatabase.Failure.inconsistentData) { try await database.catalog(for: book.id) }
            await #expect(throws: LibraryDatabase.Failure.inconsistentData) { try await database.checkpoint(for: book.id) }
        }
    }

    // Exercise the persistence primitive in isolation. Product adoption must add
    // complete mapping/state validation and inventory CAS before using it.
    private func moveBinding(_ database: LibraryDatabase, _ id: LocalBookID, to reference: SourceBookReference) async throws {
        try await database.queue.write { db in
            try LibraryDatabase.recordBookReference(db, bookID: id, reference: reference)
            try db.execute(sql: "UPDATE library_book SET reference_version=?, remote_key=? WHERE id=?",
                arguments: [reference.referenceVersion, reference.key, id.rawValue.uuidString])
        }
    }

    private static let schemaFour = """
        DROP TABLE book_reference;
        ALTER TABLE library_book DROP COLUMN catalog_reference;
        PRAGMA user_version=4;
        """

    private func seed(_ database: LibraryDatabase) async throws -> (LibraryBook, CatalogSnapshot, ReadingSession, ReadingPosition) {
        let book = try await database.addBook(reference: .init(installationID: SourceInstallationID(), referenceVersion: 1, key: "old-book"), title: "Saved", author: nil)
        let chapter = try ChapterReference(book: book.reference, key: "chapter")
        let catalog = try CatalogSnapshot(book: book.reference, revision: "old-catalog", entries: [.init(reference: chapter, title: "Chapter")])
        let request = try await database.beginCatalogUpdate(for: book.id)
        #expect(try await database.publishCatalog(catalog, using: request))
        let position = try ReadingPosition(chapter: chapter, documentRevision: "original-document", normalizationVersion: 1, elementID: "p", utf16Offset: 3)
        let session = try await database.startReading(book.id)
        #expect(try await database.saveCheckpoint(position, session: session, sequence: 1))
        return (book, catalog, session, position)
    }

    private func withLibrary(_ body: (URL, LibraryDatabase) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitReferences-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove isolated reference data") }
        }
        let path = root.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase.create(at: path)
        do { try await body(path, database); try await database.close() }
        catch {
            do { try await database.close() } catch { Issue.record(error, "Unable to close reference fixture") }
            throw error
        }
    }
}
