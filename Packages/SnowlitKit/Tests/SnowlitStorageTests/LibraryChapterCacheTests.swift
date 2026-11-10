import Foundation
import GRDB
import SnowlitCore
import Testing
@testable import SnowlitStorage

struct LibraryChapterCacheTests {
    @Test func semanticDocumentsAndExactCheckpointRevisionsSurviveReopenAndSignOut() async throws {
        try await withLibrary { path, db, installed, book, chapter in
            let original = try document(chapter, text: "原文 👩🏽‍💻", revision: "one")
            let changed = try document(chapter, text: "新版", revision: "two")
            try await save(original, book: book, to: db)
            let reader = try await db.startReading(book.id)
            let position = try ChapterTextProjection(document: original).position(atUTF16Offset: 0)
            #expect(try await db.saveCheckpoint(position, session: reader, sequence: 1))
            try await save(changed, book: book, to: db)
            #expect(try await db.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) == changed)
            #expect(try await db.cachedChapter(bookID: book.id, chapter: chapter, revision: original.revision, digest: Self.digest) == original)
            _ = try await db.signOutSource(expected: installed)
            try await db.close()
            let reopened = try LibraryDatabase(existingAt: path)
            #expect(try await reopened.cachedChapter(bookID: book.id, chapter: chapter, revision: original.revision, digest: Self.digest) == original)
            #expect(try await reopened.checkpoint(for: book.id)?.position == position)
            #expect(try await reopened.books() == [book])
            try await reopened.close()
        }
    }

    @Test func aNewRequestAndRevocationRejectLateWritesAcrossConnections() async throws {
        try await withLibrary { path, db, installed, book, chapter in
            let second = try LibraryDatabase(existingAt: path)
            let value = try document(chapter)
            let old = try await db.beginChapterUpdate(bookID: book.id, chapter: chapter)
            let fresh = try await second.beginChapterUpdate(bookID: book.id, chapter: chapter)
            await #expect(throws: ChapterAccessFailure.stale) { try await db.publishChapter(value, using: old, digest: Self.digest) }
            try await db.revokeChapterUpdate(old)
            try await second.publishChapter(value, using: fresh, digest: Self.digest)
            let cancelled = try await db.beginChapterUpdate(bookID: book.id, chapter: chapter)
            try await second.revokeChapterUpdate(cancelled)
            await #expect(throws: ChapterAccessFailure.stale) { try await db.publishChapter(value, using: cancelled, digest: Self.digest) }
            let changed = try await db.beginChapterUpdate(bookID: book.id, chapter: chapter)
            _ = try await second.setSourceEnabled(false, expected: installed)
            await #expect(throws: ChapterAccessFailure.stale) { try await db.publishChapter(value, using: changed, digest: Self.digest) }
            #expect(try await second.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) == value)
            try await second.close()
        }
    }

    @Test func failedCommitRetainsOldDocumentAndCollectsPromotedOrphans() async throws {
        try await withLibrary { _, db, _, book, chapter in
            let original = try document(chapter), changed = try document(chapter, text: "changed")
            try await save(original, book: book, to: db)
            let token = try await db.beginChapterUpdate(bookID: book.id, chapter: chapter)
            try await db.queue.write { try $0.execute(sql: "CREATE TRIGGER reject_cache BEFORE INSERT ON chapter_cache BEGIN SELECT RAISE(ABORT, 'fixture'); END;") }
            await #expect(throws: DatabaseError.self) { try await db.publishChapter(changed, using: token, digest: Self.digest) }
            #expect(try await db.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) == original)
            #expect(try await db.collectChapterCacheFiles() == 1)
            try await db.queue.write { try $0.execute(sql: "DROP TRIGGER reject_cache") }
            try await db.publishChapter(changed, using: token, digest: Self.digest)
            #expect(try await db.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) == changed)
            // Returning to earlier content still becomes the most recently fetched revision.
            try await save(original, book: book, to: db)
            #expect(try await db.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) == original)
            #expect(try await db.collectChapterCacheFiles() == 1)
        }
    }

    @Test func corruptMissingAndForgedPathsAreReportedWithoutReadingOutsideCache() async throws {
        try await withLibrary { path, db, _, book, chapter in
            let value = try document(chapter)
            try await save(value, book: book, to: db)
            let filename = try await db.queue.read { try String.fetchOne($0, sql: "SELECT filename FROM chapter_cache") }
            let name = try #require(filename)
            let file = path.deletingPathExtension().appendingPathExtension("chapters").appendingPathComponent("objects").appendingPathComponent(name)
            try Data("corrupt".utf8).write(to: file)
            await #expect(throws: ChapterAccessFailure.cacheCorrupt) { try await db.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) }
            try FileManager.default.removeItem(at: file)
            await #expect(throws: ChapterAccessFailure.cacheMissing) { try await db.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) }
            try await db.queue.write { try $0.execute(sql: "UPDATE chapter_cache SET filename='../private.json'") }
            await #expect(throws: ChapterAccessFailure.invalidCachePath) { try await db.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) }
            #expect(try await db.books() == [book])
        }
    }

    @Test func trimmingAndReadOnlyOrClosedStoresCannotAlterReadingData() async throws {
        try await withLibrary { path, db, _, book, chapter in
            let value = try document(chapter)
            try await save(value, book: book, to: db)
            let before = try await db.chapterCacheUsage()
            #expect(before.documents == 1 && before.bytes > 0)
            let readonly = try LibraryDatabase(existingAt: path, readOnly: true)
            #expect(try await readonly.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) == value)
            await #expect(throws: ChapterAccessFailure.readOnly) { try await readonly.trimChapterCache(toByteLimit: 0) }
            await #expect(throws: ChapterAccessFailure.readOnly) { try await readonly.beginChapterUpdate(bookID: book.id, chapter: chapter) }
            try await readonly.close()
            await #expect(throws: LibraryDatabase.Failure.closed) { try await readonly.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) }
            #expect(try await db.trimChapterCache(toByteLimit: 0) == .init(documents: 0, bytes: 0))
            #expect(try await db.cachedChapter(bookID: book.id, chapter: chapter, digest: Self.digest) == nil)
            #expect(try await db.books() == [book])
            #expect(try await db.catalog(for: book.id)?.entries.map(\.reference) == [chapter])
        }
    }

    @Test func schemaEightMigratesAtomicallyAndUnknownSchemasRemainRejected() async throws {
        try await withLibrary { path, db, _, book, _ in
            try await db.close()
            let sql = try DatabaseQueue(path: path.path)
            try await sql.write { try $0.execute(sql: "DROP TABLE chapter_request; DROP TABLE chapter_cache; PRAGMA user_version=8;") }
            #expect(throws: LibraryDatabase.Failure.migrationRequired) { try LibraryDatabase(existingAt: path, readOnly: true) }
            try await sql.write { try $0.execute(sql: "CREATE TABLE chapter_cache (sentinel TEXT); INSERT INTO chapter_cache VALUES ('retain');") }
            #expect(throws: DatabaseError.self) { try LibraryDatabase(existingAt: path) }
            let retained = try await sql.read { db in try (Int.fetchOne(db, sql: "PRAGMA user_version"),
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name='chapter_request'"),
                String.fetchOne(db, sql: "SELECT sentinel FROM chapter_cache")) }
            #expect(retained.0 == 8 && retained.1 == 0 && retained.2 == "retain")
            try await sql.write { try $0.execute(sql: "DROP TABLE chapter_cache;") }
            try sql.close()
            let upgraded = try LibraryDatabase(existingAt: path)
            #expect(try await upgraded.books() == [book])
            #expect(try await upgraded.chapterCacheUsage() == .init(documents: 0, bytes: 0))
            try await upgraded.close()
        }
    }

    private func save(_ value: ChapterDocument, book: LibraryBook, to db: LibraryDatabase) async throws {
        let token = try await db.beginChapterUpdate(bookID: book.id, chapter: value.content.chapter)
        try await db.publishChapter(value, using: token, digest: Self.digest)
    }
    private func document(_ chapter: ChapterReference, text: String = "Repeated text", revision: String = "r1") throws -> ChapterDocument {
        let content = try ChapterContent(chapter: chapter, sourceRevision: revision, blocks: [
            .paragraph(.init(id: "p1", runs: [.text(text, .init(strong: true)),
                .comment(.init(id: "comment", paragraphID: "p1", externalReference: "thread"))])),
            .image(.init(id: "image", resource: .init(id: "resource", reference: "picture.png"))),
            .paragraph(.init(id: "p2", runs: [.text(text, .init())]))])
        return try .init(content: content, digest: Self.digest)
    }
    private static let digest: LibraryDatabase.ChapterDigest = { try ProbeFileStoreTests.sha256($0) }

    private func withLibrary(_ body: (URL, LibraryDatabase, SourceInstallationSnapshot, LibraryBook, ChapterReference) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitChapterCache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error, "Unable to remove chapter cache fixture") }
        }
        let path = directory.appendingPathComponent("library.sqlite")
        let db = try LibraryDatabase.create(at: path)
        do {
            let script = try SourceScriptSnapshot(bytes: Data("// fixture".utf8), metadata: .init(sourceID: "org.example.chapter-cache",
                name: "Fixture", scriptVersion: "1", protocolVersion: 1, referenceVersion: 1, stateVersion: 1), digest: Self.digest)
            let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: String(repeating: "a", count: 64),
                fileName: "fixture.js", importedAt: Date())
            try await db.stageSourceScript(script, receipt: receipt)
            let installed = try await db.installSource(importID: receipt.id, id: .init(), configuration: [], consent: .managedOnly)
            let book = try await db.addBook(reference: .init(installationID: installed.id, referenceVersion: 1, key: "book"), title: "Book", author: nil)
            let chapter = try ChapterReference(book: book.reference, key: "chapter")
            let token = try await db.beginCatalogUpdate(for: book.id)
            #expect(try await db.publishCatalog(.init(book: book.reference, revision: "r1", entries: [.init(reference: chapter, title: "Chapter")]), using: token))
            try await body(path, db, installed, book, chapter)
            try await db.close()
        } catch {
            do { try await db.close() } catch { Issue.record(error, "Unable to close chapter cache fixture") }
            throw error
        }
    }
}
