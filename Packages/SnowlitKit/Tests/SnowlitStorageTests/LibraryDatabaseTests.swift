import Foundation
import GRDB
import SnowlitCore
import Testing
@testable import SnowlitStorage

struct LibraryDatabaseTests {
    @Test func databasePreservesByteDistinctUnicodeReferences() async throws {
        try await withDirectory { root in
            let database = try LibraryDatabase.create(at: root.appendingPathComponent("library.sqlite"))
            let installation = SourceInstallationID()
            let a = try SourceBookReference(installationID: installation, referenceVersion: 1, key: "é")
            let b = try SourceBookReference(installationID: installation, referenceVersion: 1, key: "e\u{301}")
            let first = try await database.addBook(reference: a, title: "same", author: nil)
            let second = try await database.addBook(reference: b, title: "same", author: nil)
            #expect(first.id != second.id)
            let token = try await database.beginCatalogUpdate(for: first.id)
            try await database.publishCatalog(catalog(a, "r1", ["é", "e\u{301}"]), using: token)
            #expect(try await database.catalog(for: first.id)?.entries.count == 2)
            try await database.close()
        }
    }
    @Test func identicalTitlesStaySeparateAndExactBindingsAreIdempotentAcrossReopen() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase.create(at: path)
            let first = try await database.addBook(reference: reference(), title: "同名书", author: "同名作者")
            let other = try await database.addBook(reference: reference(), title: "同名书", author: "同名作者")
            #expect(first.id != other.id)
            #expect(try await database.addBook(reference: first.reference, title: "renamed", author: nil).id == first.id)
            try await database.close()
            let reopened = try LibraryDatabase(existingAt: path)
            #expect(try await reopened.books() == [first, other])
            try await reopened.close()
        }
    }

    @Test func competingCatalogRequestsNeverPublishOldOrPartialResults() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let first = try LibraryDatabase.create(at: path)
            let second = try LibraryDatabase(existingAt: path)
            let book = try await first.addBook(reference: reference(), title: "book", author: nil)
            let initial = try await first.beginCatalogUpdate(for: book.id)
            #expect(try await first.publishCatalog(catalog(book.reference, "old", ["a"]), using: initial))
            let stale = try await first.beginCatalogUpdate(for: book.id)
            let newest = try await second.beginCatalogUpdate(for: book.id)
            #expect(try await first.catalog(for: book.id)?.revision == "old")
            #expect(try await !first.publishCatalog(catalog(book.reference, "stale", ["a", "x"]), using: stale))
            #expect(try await second.publishCatalog(catalog(book.reference, "new", ["b", "a"]), using: newest))
            #expect(try await !second.publishCatalog(catalog(book.reference, "replayed", ["x"]), using: newest))
            #expect(try await first.catalog(for: book.id)?.entries.map(\.reference.key) == ["b", "a"])
            try await first.close()
            try await second.close()
            let reopened = try LibraryDatabase(existingAt: path)
            #expect(try await reopened.catalog(for: book.id)?.revision == "new")
            try await reopened.close()
        }
    }

    @Test func midReplacementSQLFailureKeepsOriginalCatalogAndAllowsRetry() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase.create(at: path)
            let book = try await database.addBook(reference: reference(), title: "book", author: nil)
            let initial = try await database.beginCatalogUpdate(for: book.id)
            let saved = try catalog(book.reference, "old", ["saved"])
            try await database.publishCatalog(saved, using: initial)
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER simulate_failed_insert BEFORE INSERT ON catalog_entry
                    WHEN NEW.remote_key = 'fail' BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;
                    """)
            }
            let update = try await database.beginCatalogUpdate(for: book.id)
            let replacement = try catalog(book.reference, "new", ["first", "fail"])
            await #expect(throws: DatabaseError.self) { try await database.publishCatalog(replacement, using: update) }
            #expect(try await database.catalog(for: book.id) == saved)
            try await raw.write { try $0.execute(sql: "DROP TRIGGER simulate_failed_insert") }
            #expect(try await database.publishCatalog(replacement, using: update))
            try await database.close()
            try raw.close()
        }
    }

    @Test func checkpointCASSurvivesCompetingWritersSessionReplacementAndRestart() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let first = try LibraryDatabase.create(at: path)
            let second = try LibraryDatabase(existingAt: path)
            let book = try await first.addBook(reference: reference(), title: "book", author: nil)
            let session = try await first.startReading(book.id)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for sequence in 1...40 {
                    let writer = sequence.isMultiple(of: 2) ? first : second
                    let anchor = try position(book.reference, offset: sequence)
                    group.addTask { _ = try await writer.saveCheckpoint(anchor, session: session, sequence: Int64(sequence)) }
                }
                try await group.waitForAll()
            }
            #expect(try await first.checkpoint(for: book.id)?.sequence == 40)
            #expect(try await !first.saveCheckpoint(position(book.reference, offset: 1), session: session, sequence: 40))
            let nextSession = try await second.startReading(book.id)
            #expect(try await first.checkpoint(for: book.id)?.position?.utf16Offset == 40)
            #expect(try await !first.saveCheckpoint(position(book.reference, offset: 99), session: session, sequence: 999))
            #expect(try await second.saveCheckpoint(position(book.reference, offset: 41), session: nextSession, sequence: 1))
            try await first.close()
            try await second.close()
            let reopened = try LibraryDatabase(existingAt: path)
            #expect(try await reopened.checkpoint(for: book.id)?.position?.utf16Offset == 41)
            #expect(try await reopened.books() == [book])
            try await reopened.close()
        }
    }

    @Test func referencesFromAnotherInstallationCannotOverwriteCatalogOrProgress() async throws {
        try await withDirectory { root in
            let database = try LibraryDatabase.create(at: root.appendingPathComponent("library.sqlite"))
            let book = try await database.addBook(reference: reference(), title: "book", author: nil)
            let token = try await database.beginCatalogUpdate(for: book.id)
            let foreign = try reference()
            await #expect(throws: LibraryModelError.differentBook) {
                try await database.publishCatalog(catalog(foreign, "r1", ["a"]), using: token)
            }
            let session = try await database.startReading(book.id)
            await #expect(throws: LibraryModelError.differentBook) {
                try await database.saveCheckpoint(position(foreign, offset: 0), session: session, sequence: 1)
            }
            #expect(try await database.catalog(for: book.id) == nil)
            #expect(try await database.checkpoint(for: book.id)?.position == nil)
            try await database.close()
        }
    }

    @Test func preferencesReopenAndReadonlyFailureCannotPretendToSave() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase.create(at: path)
            #expect(try await database.preferences() == .defaults)
            let saved = try ReaderPreferences(fontSize: 24, theme: .dark)
            try await database.savePreferences(saved)
            try await database.close()
            let reader = try LibraryDatabase(existingAt: path, readOnly: true)
            #expect(try await reader.preferences() == saved)
            do {
                try await reader.savePreferences(.defaults)
                Issue.record("Readonly preferences returned success")
            } catch let error as DatabaseError { #expect(error.resultCode == .SQLITE_READONLY) }
            #expect(try await reader.preferences() == saved)
            try await reader.close()
            await #expect(throws: LibraryDatabase.Failure.closed) { try await reader.books() }
        }
    }

    @Test func missingUnknownAndCorruptDataAreRetainedWithoutFallback() async throws {
        try await withDirectory { root in
            let missing = root.appendingPathComponent("missing.sqlite")
            #expect(throws: LibraryDatabase.Failure.missingDatabase) { try LibraryDatabase(existingAt: missing) }
            #expect(!FileManager.default.fileExists(atPath: missing.path))
            let bad = root.appendingPathComponent("bad.sqlite")
            let original = Data("corrupt database, preserve it".utf8)
            try original.write(to: bad)
            #expect(throws: (any Error).self) { try LibraryDatabase(existingAt: bad) }
            #expect(try Data(contentsOf: bad) == original)
            let unknown = root.appendingPathComponent("unknown.sqlite")
            let raw = try DatabaseQueue(path: unknown.path)
            try raw.write { try $0.execute(sql: "CREATE TABLE marker(value TEXT); INSERT INTO marker VALUES('keep'); PRAGMA user_version=999;") }
            try raw.close()
            let originalUnknown = try Data(contentsOf: unknown)
            #expect(throws: LibraryDatabase.Failure.unsupportedSchema) { try LibraryDatabase(existingAt: unknown) }
            #expect(try Data(contentsOf: unknown) == originalUnknown)
            #expect(throws: LibraryDatabase.Failure.alreadyExists) { try LibraryDatabase.create(at: unknown) }
        }
    }

    private func reference() throws -> SourceBookReference {
        try SourceBookReference(installationID: SourceInstallationID(), referenceVersion: 1, key: "book")
    }
    private func catalog(_ book: SourceBookReference, _ revision: String, _ keys: [String]) throws -> CatalogSnapshot {
        try CatalogSnapshot(book: book, revision: revision, entries: keys.map {
            try CatalogEntry(reference: ChapterReference(book: book, key: $0), title: "同名章节")
        })
    }
    private func position(_ book: SourceBookReference, offset: Int) throws -> ReadingPosition {
        try ReadingPosition(chapter: ChapterReference(book: book, key: "chapter"), documentRevision: "r1",
                            normalizationVersion: 1, elementID: "p1", utf16Offset: offset)
    }
    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove test data") }
        }
        try await body(root)
    }
}
