import Foundation
import GRDB
import SnowlitCore
import Testing
@testable import SnowlitStorage

/// Reconstruct the actual earlier schema before testing an upgrade path.
func removeSourceInventorySchema(_ db: Database) throws {
    for table in ["library_book", "catalog_entry", "reading_checkpoint", "book_reference"] {
        for action in ["insert", "update", "delete"] {
            try db.execute(sql: "DROP TRIGGER inventory_\(table)_\(action)")
        }
    }
    try db.execute(sql: "DROP TABLE source_inventory_revision")
}

struct LibrarySourceUpdateSnapshotTests {
    @Test func preparationIsReadonlyAndIncludesCurrentAndPriorTargetState() async throws {
        try await withLibrary { _, database in
            let (installed, candidate, book) = try await setup(database)
            let access = try await database.beginInstalledPublicStateAccess(expected: installed)
            let operation = try await database.beginPublicStateOperation(requestID: UUID(), using: access)
            let old = try SourcePublicStateEntry(key: "category", value: "retain")
            #expect(try await database.writePublicState([old], expectedRevision: 0, using: operation).written)
            // A state version can already exist after an earlier upgrade/downgrade.
            let retained = try SourcePublicStateEntry(key: "previous", value: "target")
            try await database.queue.write { db in
                try db.execute(sql: "INSERT INTO source_public_state VALUES (?, 2, 7, ?)",
                    arguments: [installed.id.rawValue.uuidString, try JSONEncoder().encode([retained])])
            }
            let snapshot = try await database.captureSourceUpdate(importID: candidate.id, expected: installed)
            #expect(snapshot.installation == installed && snapshot.candidate == candidate)
            #expect(snapshot.candidateMetadata.referenceVersion == 2 && snapshot.candidateMetadata.stateVersion == 2)
            #expect(snapshot.currentState == (try .init(stateVersion: 1, revision: 1, entries: [old])))
            #expect(snapshot.targetState == (try .init(stateVersion: 2, revision: 7, entries: [retained])))
            #expect(snapshot.books.map(\.book) == [book])
            #expect(snapshot.books.first?.references == [book.reference])
            #expect(snapshot.books.first?.catalog == nil && snapshot.books.first?.checkpoint == nil)
            #expect(try await database.captureSourceUpdate(importID: candidate.id, expected: installed) == snapshot)
            #expect(try await database.sourceInstallations() == [installed])
            #expect(try await database.writePublicState([], expectedRevision: 1, using: operation).written)
            let changed = try await database.captureSourceUpdate(importID: candidate.id, expected: installed)
            #expect(changed.currentState.revision == 2 && changed.inventoryRevision == snapshot.inventoryRevision)
            #expect(changed.targetState == snapshot.targetState)
        }
    }

    @Test func independentConnectionsInvalidateTheInventoryForEverySavedLibraryChange() async throws {
        try await withLibrary { path, first in
            let (installed, candidate, book) = try await setup(first)
            let second = try LibraryDatabase(existingAt: path)
            var snapshot = try await first.captureSourceUpdate(importID: candidate.id, expected: installed)
            let token = try await second.beginCatalogUpdate(for: book.id)
            var changed = try await first.captureSourceUpdate(importID: candidate.id, expected: installed)
            #expect(changed.inventoryRevision > snapshot.inventoryRevision)
            snapshot = changed
            let chapter = try ChapterReference(book: book.reference, key: "saved-chapter")
            let catalog = try CatalogSnapshot(book: book.reference, revision: "catalog", entries: [.init(reference: chapter, title: "Chapter")])
            #expect(try await second.publishCatalog(catalog, using: token))
            changed = try await first.captureSourceUpdate(importID: candidate.id, expected: installed)
            #expect(changed.inventoryRevision > snapshot.inventoryRevision && changed.books.first?.catalog == catalog)
            snapshot = changed
            let session = try await second.startReading(book.id)
            changed = try await first.captureSourceUpdate(importID: candidate.id, expected: installed)
            #expect(changed.inventoryRevision > snapshot.inventoryRevision)
            snapshot = changed
            let position = try ReadingPosition(chapter: chapter, documentRevision: "document", normalizationVersion: 1, elementID: "p", utf16Offset: 4)
            #expect(try await second.saveCheckpoint(position, session: session, sequence: 1))
            changed = try await first.captureSourceUpdate(importID: candidate.id, expected: installed)
            #expect(changed.inventoryRevision > snapshot.inventoryRevision && changed.books.first?.checkpoint?.position == position)
            snapshot = changed
            #expect(try await !second.saveCheckpoint(position, session: session, sequence: 1))
            #expect(try await first.captureSourceUpdate(importID: candidate.id, expected: installed) == snapshot)
            let other = try await second.addBook(reference: .init(installationID: installed.id, referenceVersion: 1, key: "second"), title: "Second", author: nil)
            changed = try await first.captureSourceUpdate(importID: candidate.id, expected: installed)
            #expect(changed.inventoryRevision > snapshot.inventoryRevision && changed.books.contains(where: { $0.book == other }))
            let beforeUnrelated = changed
            _ = try await second.addBook(reference: .init(installationID: SourceInstallationID(), referenceVersion: 1, key: "other-source"), title: "Other", author: nil)
            #expect(try await first.captureSourceUpdate(importID: candidate.id, expected: installed) == beforeUnrelated)
            try await second.close()
        }
    }

    @Test func inventoryIncludesHistoricalIdentityWithoutRelabelingCatalogOrAnchor() async throws {
        try await withLibrary { _, database in
            let (installed, candidate, book) = try await setup(database)
            let chapter = try ChapterReference(book: book.reference, key: "old-chapter")
            let catalog = try CatalogSnapshot(book: book.reference, revision: "saved", entries: [.init(reference: chapter, title: "Saved")])
            let token = try await database.beginCatalogUpdate(for: book.id)
            #expect(try await database.publishCatalog(catalog, using: token))
            let session = try await database.startReading(book.id)
            let position = try ReadingPosition(chapter: chapter, documentRevision: "old-content", normalizationVersion: 1, elementID: "p", utf16Offset: 2)
            #expect(try await database.saveCheckpoint(position, session: session, sequence: 1))
            let before = try await database.captureSourceUpdate(importID: candidate.id, expected: installed)
            let updated = try SourceBookReference(installationID: installed.id, referenceVersion: 2, key: "next")
            try await database.queue.write { db in
                try LibraryDatabase.recordBookReference(db, bookID: book.id, reference: updated)
                try db.execute(sql: "UPDATE library_book SET reference_version=2, remote_key='next' WHERE id=?", arguments: [book.id.rawValue.uuidString])
            }
            let after = try await database.captureSourceUpdate(importID: candidate.id, expected: installed)
            #expect(after.inventoryRevision > before.inventoryRevision)
            let saved = try #require(after.books.first)
            #expect(saved.book.reference == updated && saved.references == [book.reference, updated])
            #expect(saved.catalog == catalog && saved.checkpoint?.position == position)
        }
    }

    @Test func staleWrongSourceUnknownProtocolAndPendingCleanupCannotBePrepared() async throws {
        try await withLibrary { _, database in
            let (installed, candidate, _) = try await setup(database)
            await #expect(throws: SourceInstallationFailure.missingImport) { try await database.captureSourceUpdate(importID: UUID(), expected: installed) }
            await #expect(throws: SourceInstallationFailure.alreadyCurrent) { try await database.captureSourceUpdate(importID: installed.importID, expected: installed) }
            let other = try await stage(database, "other", source: "org.example.other")
            await #expect(throws: SourceInstallationFailure.differentSource) { try await database.captureSourceUpdate(importID: other.id, expected: installed) }
            let unsupported = try await stage(database, "protocol", protocolVersion: 2)
            await #expect(throws: SourceUpdateFailure.unsupportedProtocol) { try await database.captureSourceUpdate(importID: unsupported.id, expected: installed) }
            let disabled = try await database.setSourceEnabled(false, expected: installed)
            await #expect(throws: SourceInstallationFailure.staleInstallation) { try await database.captureSourceUpdate(importID: candidate.id, expected: installed) }
            #expect(try await database.captureSourceUpdate(importID: candidate.id, expected: disabled).installation == disabled)
            let removed = try await database.removeSource(expected: disabled)
            await #expect(throws: SourceInstallationFailure.cleanupPending) { try await database.captureSourceUpdate(importID: candidate.id, expected: removed) }
            #expect(try await database.finishSourceSessionCleanup(#require(removed.pendingCleanup), installationID: removed.id))
            let cleaned = try #require(try await database.sourceInstallations().first)
            #expect(try await database.captureSourceUpdate(importID: candidate.id, expected: cleaned).books.count == 1)
        }
    }

    @Test func schemaFiveMigrationRetainsDataAndReadonlyPreparationDoesNotWrite() async throws {
        try await withLibrary { path, database in
            let (installed, candidate, book) = try await setup(database)
            try await database.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { db in
                try removeSourceInventorySchema(db)
                try db.execute(sql: "PRAGMA user_version=5")
            }
            try raw.close()
            let bytes = try Data(contentsOf: path)
            #expect(throws: LibraryDatabase.Failure.migrationRequired) { try LibraryDatabase(existingAt: path, readOnly: true) }
            #expect(try Data(contentsOf: path) == bytes)
            let upgraded = try LibraryDatabase(existingAt: path)
            #expect(try await upgraded.books() == [book])
            let expected = try await upgraded.captureSourceUpdate(importID: candidate.id, expected: installed)
            try await upgraded.close()
            let reader = try LibraryDatabase(existingAt: path, readOnly: true)
            #expect(try await reader.captureSourceUpdate(importID: candidate.id, expected: installed) == expected)
            try await reader.close()
        }
    }

    @Test func failedTriggerCreationRollsBackTheNewTableAndEarlierTriggers() async throws {
        try await withLibrary { path, database in
            let (_, _, book) = try await setup(database)
            try await database.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { db in
                try removeSourceInventorySchema(db)
                try db.execute(sql: """
                    CREATE TRIGGER inventory_catalog_entry_insert AFTER INSERT ON catalog_entry BEGIN SELECT 1; END;
                    PRAGMA user_version=5;
                    """)
            }
            #expect(throws: DatabaseError.self) { try LibraryDatabase(existingAt: path) }
            let result = try await raw.read { db in
                try (Int.fetchOne(db, sql: "PRAGMA user_version"),
                     Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name='source_inventory_revision'"),
                     Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'inventory_%'"),
                     String.fetchOne(db, sql: "SELECT id FROM library_book"))
            }
            #expect(result.0 == 5 && result.1 == 0 && result.2 == 1 && result.3 == book.id.rawValue.uuidString)
            try raw.close()
        }
    }

    @Test func missingInvalidationTriggerCannotSilentlyWeakenAReopenedLibrary() async throws {
        try await withLibrary { path, database in
            _ = try await setup(database)
            try await database.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try $0.execute(sql: "DROP TRIGGER inventory_reading_checkpoint_update") }
            try raw.close()
            #expect(throws: LibraryDatabase.Failure.inconsistentData) { try LibraryDatabase(existingAt: path) }
        }
    }

    @Test func rejectedWritesAndCounterOverflowPreserveThePreviousInventory() async throws {
        try await withLibrary { _, database in
            let (installed, candidate, book) = try await setup(database)
            let token = try await database.beginCatalogUpdate(for: book.id)
            let before = try await database.captureSourceUpdate(importID: candidate.id, expected: installed)
            try await database.queue.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_catalog BEFORE INSERT ON catalog_entry
                    WHEN NEW.remote_key='reject' BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
                    """)
            }
            let catalog = try CatalogSnapshot(book: book.reference, revision: "candidate", entries: [
                .init(reference: .init(book: book.reference, key: "first"), title: "First"),
                .init(reference: .init(book: book.reference, key: "reject"), title: "Rejected")])
            await #expect(throws: DatabaseError.self) { try await database.publishCatalog(catalog, using: token) }
            #expect(try await database.captureSourceUpdate(importID: candidate.id, expected: installed) == before)
            try await database.queue.write { db in
                try db.execute(sql: "DROP TRIGGER reject_catalog")
                try db.execute(sql: "UPDATE source_inventory_revision SET revision=? WHERE installation=?",
                               arguments: [Int64.max, installed.id.rawValue.uuidString])
            }
            let full = try await database.captureSourceUpdate(importID: candidate.id, expected: installed)
            await #expect(throws: DatabaseError.self) { try await database.publishCatalog(catalog, using: token) }
            #expect(try await database.captureSourceUpdate(importID: candidate.id, expected: installed) == full)
            #expect(try await database.catalog(for: book.id) == nil)
        }
    }

    private func setup(_ database: LibraryDatabase) async throws -> (SourceInstallationSnapshot, SourceImportRecord, LibraryBook) {
        let original = try await stage(database, "one")
        let installed = try await database.installSource(importID: original.id, id: SourceInstallationID(), configuration: [], consent: .managedOnly)
        let candidate = try await stage(database, "two", version: 2)
        let book = try await database.addBook(reference: .init(installationID: installed.id, referenceVersion: 1, key: "book"), title: "Saved", author: nil)
        return (installed, candidate, book)
    }

    private func stage(_ database: LibraryDatabase, _ tag: String, source: String = "org.example.source", protocolVersion: Int = 1, version: Int = 1) async throws -> SourceImportRecord {
        let digests = ["one": "fe937a32ee0fa9be5c27533dc08408778651049d53f7ad9ea59b706f8046232f",
                       "two": "3a19149db85385064d1d9313a2b1007f9584c868cce700cf79aea8b9207a33ca",
                       "other": "84b0a684f1e3a9ffae0c124ab329696d1ca80e911d3cbc4749e908098a3a2a70",
                       "protocol": "36109bf52b933cc7296d45612ca77e755807658aa679f9455d346747171b8237"]
        let digest = try #require(digests[tag])
        let script = try SourceScriptSnapshot(bytes: Data("// fixture-\(tag)\n".utf8),
            metadata: .init(sourceID: source, name: "Fixture", scriptVersion: tag, protocolVersion: protocolVersion,
                            referenceVersion: version, stateVersion: version), digest: { _ in digest })
        let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: String(repeating: "a", count: 64),
            fileName: "fixture.source.js", importedAt: Date(timeIntervalSince1970: 100))
        try await database.stageSourceScript(script, receipt: receipt)
        return receipt
    }

    private func withLibrary(_ body: (URL, LibraryDatabase) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitUpdateSnapshots-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove isolated update data") }
        }
        let path = root.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase.create(at: path)
        do { try await body(path, database); try await database.close() }
        catch {
            do { try await database.close() } catch { Issue.record(error, "Unable to close update fixture") }
            throw error
        }
    }
}
