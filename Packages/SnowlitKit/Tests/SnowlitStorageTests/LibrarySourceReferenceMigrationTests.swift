import Foundation
import GRDB
import SnowlitCore
import Testing
@testable import SnowlitStorage

/// Rebuild schema 7, including its absence of migration history and reasons.
func removeSourceReferenceHistorySchema(_ db: Database) throws {
    try db.execute(sql: "DROP TABLE chapter_request; DROP TABLE chapter_cache;")
    for action in ["insert", "update", "delete"] {
        try db.execute(sql: "DROP TRIGGER inventory_source_reference_transition_\(action)")
    }
    try db.execute(sql: "DROP TABLE source_reference_transition; ALTER TABLE library_book DROP COLUMN reference_invalidation;")
}

struct LibrarySourceReferenceMigrationTests {
    @Test func upgradesAndRollbackPreserveLocalIdentityAndSavedContent() async throws {
        try await withLibrary { path, db, initial, book in
            let originalChapter = try ChapterReference(book: book.reference, key: "chapter")
            let catalog = try CatalogSnapshot(book: book.reference, revision: "saved",
                entries: [.init(reference: originalChapter, title: "Saved")])
            let request = try await db.beginCatalogUpdate(for: book.id)
            #expect(try await db.publishCatalog(catalog, using: request))
            let staleRequest = try await db.beginCatalogUpdate(for: book.id)
            let reader = try await db.startReading(book.id)
            let position = try savedPosition(originalChapter)
            #expect(try await db.saveCheckpoint(position, session: reader, sequence: 1))
            let originalDocument = try ChapterDocument(content: .init(chapter: originalChapter, sourceRevision: "original", blocks: [
                .paragraph(.init(id: "p1", runs: [.text("Saved original text", .init())]))]), digest: ProbeFileStoreTests.sha256)
            let originalWrite = try await db.beginChapterUpdate(bookID: book.id, chapter: originalChapter)
            try await db.publishChapter(originalDocument, using: originalWrite, digest: ProbeFileStoreTests.sha256)
            var current = initial
            for version in [2, 3, 1, 2] {
                let candidate = try await stage(db, version)
                let prepared = try await db.captureSourceUpdate(importID: candidate.id, expected: current)
                let changes = try mapped(prepared)
                current = try await db.updateSource(prepared: prepared, migratedState: nil, referenceChanges: changes,
                    configuration: [], consent: .managedOnly)
                let binding = try #require(try await db.books().first)
                #expect(binding.id == book.id && binding.reference.referenceVersion == version)
                #expect(binding.reference.key == "book" && binding.networkReference != nil)
                #expect(try await db.catalog(for: book.id) == catalog)
                #expect(try await db.checkpoint(for: book.id)?.position == position)
                #expect(try await db.addBook(reference: book.reference, title: "Duplicate", author: nil).id == book.id)
                #expect(try await db.saveCheckpoint(position, session: reader, sequence: Int64(current.revision)))
                let newWrite = try await db.beginChapterUpdate(bookID: book.id, chapter: originalChapter)
                #expect(newWrite.resolved.book == binding.reference)
                #expect(newWrite.resolved.book.referenceVersion == version)
                let content = try ChapterContent(chapter: newWrite.resolved, sourceRevision: "source-\(current.revision)", blocks: [
                    .paragraph(.init(id: "p1", runs: [.text("Updated text", .init())]))])
                let document = try ChapterDocument(content: content, digest: ProbeFileStoreTests.sha256)
                try await db.publishChapter(document, using: newWrite, digest: ProbeFileStoreTests.sha256)
                #expect(try await db.cachedChapter(bookID: book.id, chapter: originalChapter, digest: ProbeFileStoreTests.sha256) == document)
                #expect(try await db.cachedChapter(bookID: book.id, chapter: originalChapter, revision: originalDocument.revision, digest: ProbeFileStoreTests.sha256) == originalDocument)
            }
            #expect(try await !db.publishCatalog(catalog, using: staleRequest))
            let history = try await db.queue.read { try LibraryDatabase.savedReferenceHistory($0, initial.id) }
            #expect(history.count == 4)
            let resolved = try SourceReferenceHistory(history).resolve(originalChapter)
            #expect(resolved.reference.book.referenceVersion == 2 && resolved.invalidation == nil)
            try await db.close()
            let reopened = try LibraryDatabase(existingAt: path, readOnly: true)
            #expect(try await reopened.sourceInstallations() == [current])
            #expect(try await reopened.books().first?.id == book.id)
            #expect(try await reopened.catalog(for: book.id) == catalog)
            #expect(try await reopened.checkpoint(for: book.id)?.position == position)
            try await reopened.close()
        }
    }

    @Test func invalidatedBookStaysOfflineOnRollbackUntilExplicitNewVersionMapping() async throws {
        try await withLibrary { _, db, initial, book in
            let chapter = try ChapterReference(book: book.reference, key: "chapter")
            let reader = try await db.startReading(book.id)
            #expect(try await db.saveCheckpoint(savedPosition(chapter), session: reader, sequence: 1))
            let second = try await stage(db, 2)
            let prepared = try await db.captureSourceUpdate(importID: second.id, expected: initial)
            let invalidation = try SourceReferenceChanges(targetVersion: 2, books: [
                .init(original: book.reference, outcome: .invalidated(.removed),
                      chapters: [.init(original: chapter, outcome: .invalidated(.removed))])])
            let invalidated = try await db.updateSource(prepared: prepared, migratedState: nil, referenceChanges: invalidation,
                configuration: [], consent: .managedOnly)
            #expect(try await db.books().first?.networkReference == nil)
            await #expect(throws: LibraryModelError.unavailableReference) { try await db.beginCatalogUpdate(for: book.id) }
            #expect(try await db.saveCheckpoint(savedPosition(chapter), session: reader, sequence: 2))
            let first = try await stage(db, 1)
            let rollback = try await db.captureSourceUpdate(importID: first.id, expected: invalidated)
            let rolledBack = try await db.updateSource(prepared: rollback, migratedState: nil, referenceChanges: mapped(rollback),
                configuration: [], consent: .managedOnly)
            #expect(try await db.books().first?.referenceInvalidation == .removed)
            #expect(try await db.books().first?.networkReference == nil)
            let history = try await db.queue.read { try LibraryDatabase.savedReferenceHistory($0, initial.id) }
            #expect(try SourceReferenceHistory(history).resolve(chapter).invalidation == .removed)
            let third = try await stage(db, 3)
            let restore = try await db.captureSourceUpdate(importID: third.id, expected: rolledBack)
            _ = try await db.updateSource(prepared: restore, migratedState: nil, referenceChanges: mapped(restore),
                configuration: [], consent: .managedOnly)
            #expect(try await db.books().first?.networkReference?.referenceVersion == 3)
            #expect(try await db.checkpoint(for: book.id)?.position == savedPosition(chapter))
        }
    }

    @Test func invalidatedChapterSurvivesBookUpgradeAndRollback() async throws {
        try await withLibrary { _, db, initial, book in
            let chapter = try ChapterReference(book: book.reference, key: "chapter")
            let reader = try await db.startReading(book.id)
            #expect(try await db.saveCheckpoint(savedPosition(chapter), session: reader, sequence: 1))
            let second = try await stage(db, 2)
            let prepared = try await db.captureSourceUpdate(importID: second.id, expected: initial)
            let destination = try SourceBookReference(installationID: initial.id, referenceVersion: 2, key: "book")
            let changes = try SourceReferenceChanges(targetVersion: 2, books: [
                .init(original: book.reference, outcome: .mapped(destination),
                      chapters: [.init(original: chapter, outcome: .invalidated(.unavailable))])])
            let updated = try await db.updateSource(prepared: prepared, migratedState: nil, referenceChanges: changes,
                configuration: [], consent: .managedOnly)
            let first = try await stage(db, 1)
            let rollback = try await db.captureSourceUpdate(importID: first.id, expected: updated)
            #expect(try SourceReferenceMigrationInventory(prepared: rollback).books.count == 2)
            _ = try await db.updateSource(prepared: rollback, migratedState: nil, referenceChanges: mapped(rollback),
                configuration: [], consent: .managedOnly)
            let history = try await db.queue.read { try LibraryDatabase.savedReferenceHistory($0, initial.id) }
            #expect(try SourceReferenceHistory(history).resolve(chapter).invalidation == .unavailable)
            #expect(try await db.books().first?.networkReference == book.reference)
        }
    }

    @Test(arguments: [false, true])
    func failureAfterReferenceWritesRollsBackHistoryBindingsAndInventory(changesState: Bool) async throws {
        try await withLibrary { path, db, initial, _ in
            let access = try await db.beginInstalledPublicStateAccess(expected: initial)
            let candidate = try await stage(db, 2, stateVersion: changesState ? 2 : 1)
            let migratedState: SourcePublicState? = changesState ? try .init(stateVersion: 2, revision: 0,
                entries: [.init(key: "new", value: "candidate")]) : nil
            try await db.queue.write { try $0.execute(sql: "CREATE TRIGGER reject_reference_commit BEFORE DELETE ON source_state_access BEGIN SELECT RAISE(ABORT, 'injected'); END;") }
            let prepared = try await db.captureSourceUpdate(importID: candidate.id, expected: initial)
            await #expect(throws: DatabaseError.self) {
                try await db.updateSource(prepared: prepared, migratedState: migratedState, referenceChanges: mapped(prepared),
                    configuration: [], consent: .managedOnly)
            }
            #expect(try await db.captureSourceUpdate(importID: candidate.id, expected: initial) == prepared)
            #expect(try await db.readPublicState(using: access).revision == 0)
            try await db.close()
            let reopened = try LibraryDatabase(existingAt: path)
            #expect(try await reopened.captureSourceUpdate(importID: candidate.id, expected: initial) == prepared)
            try await reopened.queue.write { try $0.execute(sql: "DROP TRIGGER reject_reference_commit") }
            let updated = try await reopened.updateSource(prepared: prepared, migratedState: migratedState, referenceChanges: mapped(prepared),
                configuration: [], consent: .managedOnly)
            #expect(updated.metadata.referenceVersion == 2)
            if changesState {
                let fresh = try await reopened.beginInstalledPublicStateAccess(expected: updated)
                #expect(try await reopened.readPublicState(using: fresh).entries == migratedState?.entries)
            }
            try await reopened.close()
        }
    }

    @Test func competingProgressAndUpdateRejectStaleReferenceCandidate() async throws {
        try await withLibrary { path, db, initial, book in
            let reader = try await db.startReading(book.id)
            let candidate = try await stage(db, 2)
            let prepared = try await db.captureSourceUpdate(importID: candidate.id, expected: initial)
            let second = try LibraryDatabase(existingAt: path)
            let position = try savedPosition(.init(book: book.reference, key: "newly-read"))
            #expect(try await second.saveCheckpoint(position, session: reader, sequence: 1))
            await #expect(throws: SourceUpdateFailure.staleInventory) {
                try await db.updateSource(prepared: prepared, migratedState: nil, referenceChanges: mapped(prepared),
                    configuration: [], consent: .managedOnly)
            }
            let fresh = try await db.captureSourceUpdate(importID: candidate.id, expected: initial)
            let accepted = try await second.updateSource(prepared: fresh, migratedState: nil, referenceChanges: mapped(fresh),
                configuration: [], consent: .managedOnly)
            await #expect(throws: SourceInstallationFailure.staleInstallation) {
                try await db.updateSource(prepared: fresh, migratedState: nil, referenceChanges: mapped(fresh),
                    configuration: [], consent: .managedOnly)
            }
            #expect(try await db.sourceInstallations() == [accepted])
            #expect(try await db.checkpoint(for: book.id)?.position == position)
            try await second.close()
        }
    }

    @Test func partialAndForeignOwnershipMappingsCannotCommit() async throws {
        try await withLibrary { _, db, initial, book in
            let otherReference = try SourceBookReference(installationID: initial.id, referenceVersion: 2, key: "other")
            _ = try await db.addBook(reference: otherReference, title: "Other", author: nil)
            let candidate = try await stage(db, 2)
            let prepared = try await db.captureSourceUpdate(importID: candidate.id, expected: initial)
            let partial = try SourceReferenceChanges(targetVersion: 2, books: [])
            let collision = try SourceReferenceChanges(targetVersion: 2, books: [
                .init(original: book.reference, outcome: .mapped(otherReference), chapters: []),
                .init(original: otherReference, outcome: .mapped(otherReference), chapters: [])])
            for changes in [partial, collision] {
                await #expect(throws: SourceUpdateFailure.invalidMigration) {
                    try await db.updateSource(prepared: prepared, migratedState: nil, referenceChanges: changes,
                        configuration: [], consent: .managedOnly)
                }
                #expect(try await db.captureSourceUpdate(importID: candidate.id, expected: initial) == prepared)
            }
        }
    }

    @Test func schemaSevenMigrationPreservesDataAndReadOnlyOpenRefusesChanges() async throws {
        try await withLibrary { path, db, initial, book in
            try await db.queue.write { sql in
                try removeSourceReferenceHistorySchema(sql)
                try sql.execute(sql: "PRAGMA user_version=7")
            }
            try await db.close()
            #expect(throws: LibraryDatabase.Failure.migrationRequired) { try LibraryDatabase(existingAt: path, readOnly: true) }
            let upgraded = try LibraryDatabase(existingAt: path)
            #expect(try await upgraded.books() == [book])
            #expect(try await upgraded.sourceInstallations() == [initial])
            #expect(try await upgraded.queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 9)
            try await upgraded.close()
        }
    }

    @Test func failedSchemaUpgradeLeavesVersionAndOriginalRowsIntact() async throws {
        try await withLibrary { path, db, _, book in
            try await db.queue.write { sql in
                try removeSourceReferenceHistorySchema(sql)
                try sql.execute(sql: "CREATE TABLE source_reference_transition (sentinel TEXT); PRAGMA user_version=7;")
            }
            try await db.close()
            #expect(throws: DatabaseError.self) { try LibraryDatabase(existingAt: path) }
            let raw = try DatabaseQueue(path: path.path)
            let state = try await raw.read { sql in
                (try Int.fetchOne(sql, sql: "PRAGMA user_version"),
                 try Int.fetchOne(sql, sql: "SELECT count(*) FROM pragma_table_info('library_book') WHERE name='reference_invalidation'"),
                 try String.fetchOne(sql, sql: "SELECT id FROM library_book"))
            }
            #expect(state.0 == 7 && state.1 == 0 && state.2 == book.id.rawValue.uuidString)
            try raw.close()
        }
    }

    @Test func removedSourceRequiresConfirmedRestoreWithTheSameReferenceChecks() async throws {
        try await withLibrary { _, db, initial, book in
            let removed = try await db.removeSource(expected: initial)
            #expect(try await db.finishSourceSessionCleanup(#require(removed.pendingCleanup), installationID: initial.id))
            let cleaned = try #require(try await db.sourceInstallations().first)
            let candidate = try await stage(db, 2)
            let prepared = try await db.captureSourceUpdate(importID: candidate.id, expected: cleaned)
            await #expect(throws: SourceInstallationFailure.invalidState) {
                try await db.updateSource(prepared: prepared, migratedState: nil, referenceChanges: mapped(prepared),
                    configuration: [], consent: .managedOnly)
            }
            let restored = try await db.restoreSource(confirmed: prepared, migratedState: nil, referenceChanges: mapped(prepared),
                configuration: [], consent: .managedOnly)
            #expect(restored.id == initial.id && restored.websiteSessionID != initial.websiteSessionID)
            #expect(!restored.allowsCredentialRead && restored.canExecute)
            #expect(try await db.books().first?.id == book.id)
            #expect(try await db.books().first?.reference.referenceVersion == 2)
        }
    }

    private func mapped(_ prepared: SourceUpdateSnapshot) throws -> SourceReferenceChanges {
        let inventory = try SourceReferenceMigrationInventory(prepared: prepared)
        return try SourceReferenceChanges(targetVersion: prepared.candidateMetadata.referenceVersion,
            books: inventory.books.map { item in
                let next = try SourceBookReference(installationID: prepared.installation.id,
                    referenceVersion: prepared.candidateMetadata.referenceVersion, key: item.reference.key)
                return .init(original: item.reference, outcome: .mapped(next), chapters: try item.chapters.map {
                    .init(original: $0, outcome: .mapped(try .init(book: next, key: $0.key)))
                })
            })
    }

    private func savedPosition(_ chapter: ChapterReference) throws -> ReadingPosition {
        try .init(chapter: chapter, documentRevision: "saved", normalizationVersion: 1, elementID: "p", utf16Offset: 2)
    }

    private func stage(_ db: LibraryDatabase, _ version: Int, stateVersion: Int = 1) async throws -> SourceImportRecord {
        let script = try SourceScriptSnapshot(bytes: Data("// version \(version)\n".utf8),
            metadata: .init(sourceID: "org.example.references", name: "Fixture", scriptVersion: "\(version)",
                            protocolVersion: 1, referenceVersion: version, stateVersion: stateVersion),
            digest: { _ in String(repeating: "\(version)", count: 64) })
        let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: String(repeating: "f", count: 64),
            fileName: "fixture.source.js", importedAt: Date(timeIntervalSince1970: 1))
        try await db.stageSourceScript(script, receipt: receipt)
        return receipt
    }

    private func withLibrary(_ body: (URL, LibraryDatabase, SourceInstallationSnapshot, LibraryBook) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitReferenceMigration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove isolated reference migration data") }
        }
        let path = root.appendingPathComponent("library.sqlite")
        let db = try LibraryDatabase.create(at: path)
        do {
            let receipt = try await stage(db, 1)
            let installed = try await db.installSource(importID: receipt.id, id: SourceInstallationID(), configuration: [], consent: .managedOnly)
            let book = try await db.addBook(reference: .init(installationID: installed.id, referenceVersion: 1, key: "book"), title: "Saved", author: nil)
            try await body(path, db, installed, book)
            try await db.close()
        } catch {
            do { try await db.close() } catch { Issue.record(error, "Unable to close reference migration fixture") }
            throw error
        }
    }
}
