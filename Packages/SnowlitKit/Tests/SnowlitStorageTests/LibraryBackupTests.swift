import Foundation
import GRDB
import SnowlitCore
import Synchronization
import Testing
@testable import SnowlitStorage

struct LibraryBackupTests {
    @Test(arguments: [false, true]) func rebuildsReadingDataAndResetsAllExecutionAuthority(includeCache: Bool) async throws {
        try await withFixture { f in
            let access = try await f.database.beginInstalledPublicStateAccess(expected: f.installation)
            let operation = try await f.database.beginPublicStateOperation(requestID: UUID(), using: access)
            _ = try await f.database.writePublicState([.init(key: "public", value: "kept")], expectedRevision: 0, using: operation)
            _ = try await f.database.beginCatalogUpdate(for: f.book.id)
            _ = try await f.database.beginChapterUpdate(bookID: f.book.id, chapter: f.document.content.chapter)
            // A private table and a deleted value stand in for data that must
            // never be copied from SQLite pages, WAL, website directories, etc.
            let sentinel = "private-credential-sentinel-\(UUID())"
            try await f.database.queue.write { db in
                try db.execute(sql: "PRAGMA secure_delete=OFF; CREATE TABLE private_fixture(value TEXT); INSERT INTO private_fixture VALUES (?); DELETE FROM private_fixture;", arguments: [sentinel])
            }
            try Data(sentinel.utf8).write(to: f.root.appendingPathComponent("website-private"))
            let summary = try await f.database.exportBackup(to: f.archive, includeCache: includeCache, digest: Self.digest)
            let bytes = try Data(contentsOf: f.archive)
            for secret in [sentinel, f.installation.websiteSessionID.uuidString, f.session.id.uuidString, access.id.uuidString, operation.requestID.uuidString] {
                #expect(bytes.range(of: Data(secret.utf8)) == nil)
                #expect(bytes.range(of: Data(Data(secret.utf8).base64EncodedString().utf8)) == nil)
            }
            let prepared = try await LibraryBackup.preflight(file: f.archive, into: f.candidate, digest: Self.digest)
            #expect(prepared.summary == summary)
            #expect(summary.books == 2 && summary.sources == 1 && summary.cachedChapters == (includeCache ? 1 : 0))
            let restored = try LibraryDatabase(existingAt: prepared.databaseURL)
            #expect(try await restored.books() == f.database.books())
            #expect(try await restored.catalog(for: f.book.id) == f.database.catalog(for: f.book.id))
            #expect(try await restored.checkpoint(for: f.book.id)?.position == f.position)
            #expect(try await restored.preferences() == f.database.preferences())
            #expect(try await restored.sourceImports() == f.database.sourceImports())
            #expect(try await restored.sourceScript(sha256: f.script.sha256, digest: Self.digest) == f.script)
            let installed = try #require(try await restored.sourceInstallations().first)
            #expect(installed.id == f.installation.id && installed.configuration == f.installation.configuration)
            #expect(installed.websiteSessionID != f.installation.websiteSessionID && !installed.allowsCredentialRead && installed.pendingCleanup == nil)
            #expect(try await !restored.saveCheckpoint(f.position, session: f.session, sequence: 100))
            await #expect(throws: SourcePublicStateFailure.staleAccess) { try await restored.readPublicState(using: access) }
            let newAccess = try await restored.beginInstalledPublicStateAccess(expected: installed)
            #expect(try await restored.readPublicState(using: newAccess).entries == [.init(key: "public", value: "kept")])
            let cached = try await restored.cachedChapter(bookID: f.book.id, chapter: f.document.content.chapter, revision: f.document.revision, digest: Self.digest)
            #expect(cached == (includeCache ? f.document : nil))
            let forbidden = try await restored.queue.read { db in
                let extraTable = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name='private_fixture'")
                let operations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_state_operation")
                let chapters = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter_request")
                let catalogs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_book WHERE catalog_request IS NOT NULL")
                return [extraTable, operations, chapters, catalogs].allSatisfy { $0 == 0 }
            }
            #expect(forbidden)
            try await restored.close()
        }
    }

    @Test func truncatedAlteredAndTrailingDataNeverChangeTheActiveLibrary() async throws {
        try await withFixture { f in
            _ = try await f.database.exportBackup(to: f.archive, includeCache: true, digest: Self.digest)
            let original = try Data(contentsOf: f.archive)
            var changed = original
            changed[changed.count - 3] ^= 1
            for bytes in [original.prefix(original.count - 1), changed, original + Data([1])] {
                let damaged = f.root.appendingPathComponent("damaged-\(UUID())")
                try bytes.write(to: damaged)
                await #expect(throws: LibraryBackupFailure.damagedArchive) {
                    try await LibraryBackup.preflight(file: damaged, into: f.candidate, digest: Self.digest)
                }
                #expect(!FileManager.default.fileExists(atPath: f.candidate.path))
                #expect(try await f.database.checkpoint(for: f.book.id)?.position == f.position)
                #expect(try await f.database.cachedChapter(bookID: f.book.id, chapter: f.document.content.chapter, digest: Self.digest) == f.document)
            }
        }
    }

    @Test func rejectsUnknownVersionsWithoutCreatingAnActiveDatabase() async throws {
        try await withFixture { f in
            _ = try await f.database.exportBackup(to: f.archive, includeCache: false, digest: Self.digest)
            let changed = f.root.appendingPathComponent("future")
            try rewrite(f.archive, to: changed) { manifest, _ in
                manifest = .init(formatVersion: 2, dataVersion: 1, summary: manifest.summary, rowCounts: manifest.rowCounts)
            }
            await #expect(throws: LibraryBackupFailure.unsupportedFormat) {
                try await LibraryBackup.preflight(file: changed, into: f.candidate, digest: Self.digest)
            }
            #expect(!FileManager.default.fileExists(atPath: f.candidate.path))
        }
    }

    @Test(arguments: ["path", "script", "owner", "type"]) func validChecksumsDoNotBypassDataValidation(kind: String) async throws {
        try await withFixture { f in
            _ = try await f.database.exportBackup(to: f.archive, includeCache: true, digest: Self.digest)
            let changed = f.root.appendingPathComponent("forged")
            try rewrite(f.archive, to: changed) { _, tables in
                switch kind {
                case "path": tables[1][0][3] = .text("../outside.js")
                case "script": tables[0][0][1] = .blob(Data("// changed script".utf8))
                case "owner": tables[5][0][0] = .text(f.other.id.rawValue.uuidString)
                default: tables[3][0][2] = .text("1")
                }
            }
            await #expect(throws: (any Error).self) { try await LibraryBackup.preflight(file: changed, into: f.candidate, digest: Self.digest) }
            #expect(!FileManager.default.fileExists(atPath: f.candidate.path))
            #expect(try await f.database.checkpoint(for: f.book.id)?.position == f.position)
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("outside.js").path))
        }
    }

    @Test func cancellationRemovesPartialOutputAndCandidateWithoutConsumingProgress() async throws {
        try await withFixture { f in
            let calls = Mutex(0)
            let cancelling: LibraryBackup.Digest = { data in
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 6 { throw CancellationError() }
                return try Self.digest(data)
            }
            await #expect(throws: CancellationError.self) { try await f.database.exportBackup(to: f.archive, includeCache: true, digest: cancelling) }
            #expect(!FileManager.default.fileExists(atPath: f.archive.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.archive.deletingLastPathComponent().path).isEmpty)
            _ = try await f.database.exportBackup(to: f.archive, includeCache: true, digest: Self.digest)
            calls.withLock { $0 = 0 }
            await #expect(throws: CancellationError.self) { try await LibraryBackup.preflight(file: f.archive, into: f.candidate, digest: cancelling) }
            #expect(!FileManager.default.fileExists(atPath: f.candidate.path))
            #expect(try await f.database.checkpoint(for: f.book.id)?.position == f.position)
        }
    }

    @Test func exportLeasesCacheAcrossIndependentConnections() async throws {
        try await withFixture { f in
            let other = try LibraryDatabase(existingAt: f.databaseURL)
            let entered = Mutex(false), completed = Mutex(false)
            let release = DispatchSemaphore(value: 0)
            let content = try f.document.content.canonicalBytes()
            let digest: LibraryBackup.Digest = { data in
                if data == content {
                    let first = entered.withLock { state in let first = !state; state = true; return first }
                    if first, release.wait(timeout: .now() + 5) == .timedOut { throw LibraryBackupFailure.damagedArchive }
                }
                return try Self.digest(data)
            }
            let exporting = Task { try await f.database.exportBackup(to: f.archive, includeCache: true, digest: digest) }
            defer { release.signal() }
            for _ in 0..<300 {
                if entered.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(entered.withLock { $0 })
            let trimming = Task {
                let usage = try await other.trimChapterCache(toByteLimit: 0)
                completed.withLock { $0 = true }
                return usage
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(!completed.withLock { $0 })
            release.signal()
            _ = try await exporting.value
            #expect(try await trimming.value.documents == 0)
            let prepared = try await LibraryBackup.preflight(file: f.archive, into: f.candidate, digest: Self.digest)
            let copy = try LibraryDatabase(existingAt: prepared.databaseURL)
            #expect(try await copy.cachedChapter(bookID: f.book.id, chapter: f.document.content.chapter, digest: Self.digest) == f.document)
            try await copy.close(); try await other.close()
        }
    }

    @Test func refusesExistingOrLiveDestinationsAndReadonlyCacheSnapshots() async throws {
        try await withFixture { f in
            await #expect(throws: LibraryBackupFailure.invalidPath) {
                try await f.database.exportBackup(to: f.databaseURL.deletingLastPathComponent().appendingPathComponent("backup"), includeCache: false, digest: Self.digest)
            }
            let readonly = try LibraryDatabase(existingAt: f.databaseURL, readOnly: true)
            await #expect(throws: LibraryBackupFailure.readOnlyCacheSnapshot) { try await readonly.exportBackup(to: f.archive, includeCache: true, digest: Self.digest) }
            _ = try await readonly.exportBackup(to: f.archive, includeCache: false, digest: Self.digest)
            let bytes = try Data(contentsOf: f.archive)
            await #expect(throws: LibraryBackupFailure.destinationExists) { try await f.database.exportBackup(to: f.archive, includeCache: false, digest: Self.digest) }
            #expect(try Data(contentsOf: f.archive) == bytes)
            await #expect(throws: LibraryBackupFailure.destinationExists) { try await LibraryBackup.preflight(file: f.archive, into: f.databaseURL.deletingLastPathComponent(), digest: Self.digest) }
            try await readonly.close()
        }
    }

    @Test func manualReferenceUpgradeRetainsHistoricalCacheAndProgressThroughBackup() async throws {
        try await withFixture { f in
            let metadata = try SourceScriptMetadata(sourceID: f.script.metadata.sourceID, name: "Backup", scriptVersion: "2",
                protocolVersion: 1, referenceVersion: 2, stateVersion: 1)
            let script = try SourceScriptSnapshot(bytes: Data("// version two".utf8), metadata: metadata, digest: Self.digest)
            let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: String(repeating: "b", count: 64), fileName: "backup-v2.js", importedAt: Date())
            try await f.database.stageSourceScript(script, receipt: receipt)
            let update = try await f.database.captureSourceUpdate(importID: receipt.id, expected: f.installation)
            let changes = try SourceReferenceChanges(targetVersion: 2, books: update.books.map { saved in
                let reference = try SourceBookReference(installationID: f.installation.id, referenceVersion: 2, key: saved.book.reference.key)
                return .init(original: saved.book.reference, outcome: .mapped(reference), chapters: try saved.chapterReferences.map {
                    .init(original: $0, outcome: .mapped(try .init(book: reference, key: $0.key)))
                })
            })
            _ = try await f.database.updateSource(prepared: update, migratedState: nil, referenceChanges: changes,
                configuration: f.installation.configuration, consent: .managedOnly)
            _ = try await f.database.exportBackup(to: f.archive, includeCache: true, digest: Self.digest)
            let prepared = try await LibraryBackup.preflight(file: f.archive, into: f.candidate, digest: Self.digest)
            let restored = try LibraryDatabase(existingAt: prepared.databaseURL)
            #expect(try await restored.books() == f.database.books())
            #expect(try await restored.checkpoint(for: f.book.id)?.position == f.position)
            #expect(try await restored.cachedChapter(bookID: f.book.id, chapter: f.document.content.chapter, revision: f.document.revision, digest: Self.digest) == f.document)
            let permit = try await restored.beginChapterUpdate(bookID: f.book.id, chapter: f.document.content.chapter)
            #expect(permit.resolved.book.referenceVersion == 2)
            try await restored.close()
        }
    }

    @Test func oversizedFrameLengthFailsBeforeAllocation() async throws {
        try await withFixture { f in
            try (BackupArchiveFormat.magic + Data(repeating: 255, count: 8)).write(to: f.archive)
            await #expect(throws: LibraryBackupFailure.recordTooLarge) {
                try await LibraryBackup.preflight(file: f.archive, into: f.candidate, digest: Self.digest)
            }
            #expect(!FileManager.default.fileExists(atPath: f.candidate.path))
        }
    }

    @Test func capacityFailureRollsBackCandidateRowsAndKeepsOriginalReadable() async throws {
        try await withFixture { f in
            let access = try await f.database.beginInstalledPublicStateAccess(expected: f.installation)
            let operation = try await f.database.beginPublicStateOperation(requestID: UUID(), using: access)
            _ = try await f.database.writePublicState([.init(key: "large", value: String(repeating: "x", count: 1_000_000))], expectedRevision: 0, using: operation)
            _ = try await f.database.exportBackup(to: f.archive, includeCache: false, digest: Self.digest)
            try FileManager.default.createDirectory(at: f.candidate, withIntermediateDirectories: false)
            let candidate = try LibraryDatabase.create(at: f.candidate.appendingPathComponent("library.sqlite"))
            try await candidate.queue.write { db in
                let count = try Int.fetchOne(db, sql: "PRAGMA page_count")
                let pages = try #require(count)
                try db.execute(sql: "PRAGMA max_page_count=\(pages)")
            }
            do {
                _ = try await candidate.readBackup(file: f.archive, digest: Self.digest)
                Issue.record("Candidate adopted data despite a full SQLite allocator")
            } catch let error as DatabaseError { #expect(error.resultCode == .SQLITE_FULL) }
            #expect(try await candidate.books().isEmpty)
            #expect(try await candidate.sourceImports().isEmpty)
            #expect(try await f.database.checkpoint(for: f.book.id)?.position == f.position)
            #expect(try await f.database.cachedChapter(bookID: f.book.id, chapter: f.document.content.chapter, digest: Self.digest) == f.document)
            try await candidate.close()
        }
    }

    private static let digest: LibraryBackup.Digest = { try ProbeFileStoreTests.sha256($0) }

    private func rewrite(_ input: URL, to output: URL,
                         change: (inout BackupArchiveFormat.Manifest, inout [[[BackupArchiveFormat.Value]]]) throws -> Void) throws {
        var (manifest, tables) = try BackupHandles.withFile(FileHandle(forReadingFrom: input)) { handle in
            _ = try handle.read(upToCount: 8)
            let reader = BackupFrameReader(file: handle, digest: Self.digest)
            let manifest = try reader.read(BackupArchiveFormat.Manifest.self)
            let tables = try manifest.rowCounts.map { count in try (0..<count).map { _ in try reader.read([BackupArchiveFormat.Value].self) } }
            return (manifest, tables)
        }
        try change(&manifest, &tables)
        try Data().write(to: output, options: .withoutOverwriting)
        try BackupHandles.withFile(FileHandle(forWritingTo: output)) { handle in
            try handle.write(contentsOf: BackupArchiveFormat.magic)
            let writer = BackupFrameWriter(file: handle, digest: Self.digest)
            try writer.write(manifest)
            for rows in tables { for row in rows { try writer.write(row) } }
        }
    }

    private struct Fixture: Sendable {
        let root: URL, databaseURL: URL, archive: URL, candidate: URL
        let database: LibraryDatabase
        let script: SourceScriptSnapshot
        let installation: SourceInstallationSnapshot
        let book: LibraryBook, other: LibraryBook
        let document: ChapterDocument
        let session: ReadingSession
        let position: ReadingPosition
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitBackup-\(UUID())")
        let live = root.appendingPathComponent("live"), exports = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove backup fixture") }
        }
        let path = live.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase.create(at: path)
        do {
            let script = try SourceScriptSnapshot(bytes: Data("// backup fixture".utf8), metadata: .init(sourceID: "org.example.backup",
                name: "Backup", scriptVersion: "1", protocolVersion: 1, referenceVersion: 1, stateVersion: 1), digest: Self.digest)
            let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: String(repeating: "a", count: 64), fileName: "backup.js", importedAt: Date())
            try await database.stageSourceScript(script, receipt: receipt)
            let installed = try await database.installSource(importID: receipt.id, id: .init(), configuration: [.text(key: "theme", value: "day")], consent: .approvedForCandidate)
            let book = try await database.addBook(reference: .init(installationID: installed.id, referenceVersion: 1, key: "book"), title: "Book", author: "Author")
            let other = try await database.addBook(reference: .init(installationID: installed.id, referenceVersion: 1, key: "other"), title: "Other", author: nil)
            let chapter = try ChapterReference(book: book.reference, key: "chapter")
            let token = try await database.beginCatalogUpdate(for: book.id)
            #expect(try await database.publishCatalog(.init(book: book.reference, revision: "r1", entries: [.init(reference: chapter, title: "Chapter")]), using: token))
            let content = try ChapterContent(chapter: chapter, sourceRevision: "1", blocks: [
                .paragraph(.init(id: "p1", runs: [.text("Reading text", .init(strong: true)), .comment(.init(id: "c", paragraphID: "p1", externalReference: "comments"))])),
                .image(.init(id: "i", resource: .init(id: "r", reference: "image.png")))])
            let document = try ChapterDocument(content: content, digest: Self.digest)
            let permit = try await database.beginChapterUpdate(bookID: book.id, chapter: chapter)
            try await database.publishChapter(document, using: permit, digest: Self.digest)
            let session = try await database.startReading(book.id)
            let position = try ReadingPosition(chapter: chapter, documentRevision: document.revision, normalizationVersion: 1, elementID: "p1", utf16Offset: 4)
            #expect(try await database.saveCheckpoint(position, session: session, sequence: 3))
            try await database.savePreferences(.init(fontSize: 24, theme: .dark))
            try await body(.init(root: root, databaseURL: path, archive: exports.appendingPathComponent("library.snowlitbackup"),
                candidate: root.appendingPathComponent("candidate"), database: database, script: script, installation: installed,
                book: book, other: other, document: document, session: session, position: position))
            try await database.close()
        } catch {
            do { try await database.close() } catch { Issue.record(error, "Unable to close backup fixture") }
            throw error
        }
    }
}
