import Foundation
import GRDB
import SnowlitCore
import Testing
@testable import SnowlitStorage

struct LibrarySourceInstallationTests {
    @Test func configurationChangesUseExactKeysAndRejectStaleWriters() async throws {
        try await withLibrary { _, database in
            let original = try await install(database)
            let values: [SourceSettingValue] = [.text(key: "é", value: "first"), .text(key: "e\u{301}", value: "second")]
            let configured = try await database.configureSource(values, expected: original)
            #expect(configured.configuration == values)
            await #expect(throws: SourceInstallationFailure.invalidConfiguration) {
                try await database.configureSource(values + values, expected: configured)
            }
            await #expect(throws: SourceInstallationFailure.staleInstallation) {
                try await database.configureSource([], expected: original)
            }
            #expect(try await database.sourceInstallations() == [configured])
        }
    }

    @Test func stagingDoesNotInstallAndDistinctSourcesNeverShareAnInstallation() async throws {
        try await withLibrary { path, database in
            let receipt = try await stage(database, "one")
            #expect(try await database.sourceInstallations().isEmpty)
            let installed = try await database.installSource(importID: receipt.id, id: SourceInstallationID(),
                configuration: [.text(key: "region", value: "north")], consent: .managedOnly)
            #expect(installed.canExecute && installed.revision == 1 && !installed.allowsCredentialRead)
            await #expect(throws: SourceInstallationFailure.alreadyInstalled) {
                try await database.installSource(importID: receipt.id, id: SourceInstallationID(), configuration: [], consent: .managedOnly)
            }
            let other = try await stage(database, "other", sourceID: "org.example.other")
            let second = try await database.installSource(importID: other.id, id: SourceInstallationID(), configuration: [], consent: .managedOnly)
            #expect(second.id != installed.id && second.websiteSessionID != installed.websiteSessionID)
            try await database.close()
            let reopened = try LibraryDatabase(existingAt: path, readOnly: true)
            #expect(try await reopened.sourceInstallations() == [installed, second])
            try await reopened.close()
        }
    }

    @Test func updateCASRevokesOldOperationsAndNeverInheritsPlaintextConsent() async throws {
        try await withLibrary { path, database in
            let original = try await install(database, consent: .approvedForCandidate)
            let access = try await database.beginInstalledPublicStateAccess(expected: original)
            let operation = try await database.beginPublicStateOperation(requestID: UUID(), using: access)
            #expect(try await database.writePublicState([.init(key: "retained", value: "public")], expectedRevision: 0, using: operation).written)
            let (book, catalog, _) = try await libraryData(database, installation: original.id)
            let request = try await database.beginCatalogUpdate(for: book.id)
            let candidate = try await stage(database, "two")
            let otherConnection = try LibraryDatabase(existingAt: path)
            let updated = try await otherConnection.updateSource(importID: candidate.id, replacing: original,
                configuration: [.boolean(key: "option", value: true)], consent: .managedOnly)
            #expect(updated.id == original.id && updated.revision == original.revision + 1)
            #expect(updated.scriptSHA256 == candidate.scriptSHA256 && !updated.allowsCredentialRead)
            #expect(updated.websiteSessionID == original.websiteSessionID)
            await #expect(throws: SourceInstallationFailure.staleInstallation) {
                try await database.setSourceEnabled(false, expected: original)
            }
            await #expect(throws: SourcePublicStateFailure.staleAccess) {
                try await database.writePublicState([], expectedRevision: 1, using: operation)
            }
            await #expect(throws: SourcePublicStateFailure.staleAccess) {
                try await database.beginPublicStateAccess(installationID: original.id, stateVersion: 1)
            }
            #expect(try await database.publishCatalog(catalog, using: request) == false)
            #expect(try await database.catalog(for: book.id) == catalog)
            let fresh = try await database.beginInstalledPublicStateAccess(expected: updated)
            #expect(try await database.readPublicState(using: fresh).entries == [.init(key: "retained", value: "public")])
            try await otherConnection.close()
        }
    }

    @Test func removalRetainsLocalDataAndRestorationRequiresConfirmationAndCleanup() async throws {
        try await withLibrary { _, database in
            let installed = try await install(database, consent: .approvedForCandidate)
            let (book, catalog, position) = try await libraryData(database, installation: installed.id)
            let checkpoint = try await database.checkpoint(for: book.id)
            let removed = try await database.removeSource(expected: installed)
            #expect(removed.state == .removed && !removed.canExecute && !removed.allowsCredentialRead)
            #expect(try await database.books() == [book])
            #expect(try await database.catalog(for: book.id) == catalog)
            #expect(try await database.checkpoint(for: book.id) == checkpoint)
            await #expect(throws: SourceInstallationFailure.restorationRequired) {
                try await database.installSource(importID: installed.importID, id: SourceInstallationID(), configuration: [], consent: .managedOnly)
            }
            await #expect(throws: SourceInstallationFailure.cleanupPending) {
                try await database.restoreSource(importID: installed.importID, confirmed: removed, configuration: [], consent: .managedOnly)
            }
            let cleanup = try #require(removed.pendingCleanup)
            #expect(cleanup.websiteSessionID == installed.websiteSessionID)
            #expect(try await database.finishSourceSessionCleanup(cleanup, installationID: installed.id))
            let cleaned = try #require(try await database.sourceInstallations().first)
            let restored = try await database.restoreSource(importID: installed.importID, confirmed: cleaned,
                configuration: installed.configuration, consent: .managedOnly)
            #expect(restored.id == installed.id && restored.websiteSessionID != installed.websiteSessionID)
            #expect(restored.canExecute && !restored.allowsCredentialRead)
            #expect(try await database.books() == [book])
            #expect(try await database.checkpoint(for: book.id)?.position == position)
            #expect(try await database.sourceImports().count == 1)
        }
    }

    @Test func disabledAndPendingCleanupSourcesCannotStartWorkButOfflineProgressSurvives() async throws {
        try await withLibrary { _, database in
            let installed = try await install(database)
            let (book, _, position) = try await libraryData(database, installation: installed.id)
            let disabled = try await database.setSourceEnabled(false, expected: installed)
            await #expect(throws: SourcePublicStateFailure.staleAccess) {
                try await database.beginInstalledPublicStateAccess(expected: disabled)
            }
            let reader = try await database.startReading(book.id)
            #expect(try await database.saveCheckpoint(position, session: reader, sequence: 1))
            let enabled = try await database.setSourceEnabled(true, expected: disabled)
            let signedOut = try await database.signOutSource(expected: enabled)
            let firstCleanup = try #require(signedOut.pendingCleanup)
            #expect(!signedOut.canExecute)
            await #expect(throws: SourcePublicStateFailure.staleAccess) {
                try await database.beginInstalledPublicStateAccess(expected: signedOut)
            }
            #expect(try await database.finishSourceSessionCleanup(firstCleanup, installationID: enabled.id))
            let cleaned = try #require(try await database.sourceInstallations().first)
            let again = try await database.signOutSource(expected: cleaned)
            #expect(again.pendingCleanup != firstCleanup)
            #expect(try await database.finishSourceSessionCleanup(firstCleanup, installationID: enabled.id) == false)
            #expect(try await database.sourceInstallations().first == again)
        }
    }

    @Test func adoptionFailureRollsBackScriptSettingsAndWriteRevocationsTogether() async throws {
        try await withLibrary { path, database in
            let installed = try await install(database, consent: .approvedForCandidate)
            let access = try await database.beginInstalledPublicStateAccess(expected: installed)
            let operation = try await database.beginPublicStateOperation(requestID: UUID(), using: access)
            let candidate = try await stage(database, "two")
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try $0.execute(sql: "CREATE TRIGGER fail_revoke BEFORE DELETE ON source_state_access BEGIN SELECT RAISE(ABORT, 'injected revoke failure'); END;") }
            await #expect(throws: DatabaseError.self) {
                try await database.updateSource(importID: candidate.id, replacing: installed, configuration: [], consent: .managedOnly)
            }
            #expect(try await database.sourceInstallations() == [installed])
            #expect(try await database.writePublicState([.init(key: "kept", value: "valid")], expectedRevision: 0, using: operation).written)
            try await raw.write { try $0.execute(sql: "DROP TRIGGER fail_revoke") }
            try raw.close()
            let updated = try await database.updateSource(importID: candidate.id, replacing: installed, configuration: [], consent: .managedOnly)
            #expect(updated.scriptSHA256 == candidate.scriptSHA256)
        }
    }

    @Test func unsafeCandidatesCannotReplaceExistingReferenceSemanticsOrPublicState() async throws {
        try await withLibrary { _, database in
            let installed = try await install(database)
            let (_, _, position) = try await libraryData(database, installation: installed.id)
            let migration = try await stage(database, "upgrade", referenceVersion: 2, stateVersion: 2)
            await #expect(throws: SourceInstallationFailure.migrationRequired) {
                try await database.updateSource(importID: migration.id, replacing: installed, configuration: [], consent: .managedOnly)
            }
            let other = try await stage(database, "other", sourceID: "org.example.other")
            await #expect(throws: SourceInstallationFailure.differentSource) {
                try await database.updateSource(importID: other.id, replacing: installed, configuration: [], consent: .managedOnly)
            }
            await #expect(throws: SourceInstallationFailure.alreadyCurrent) {
                try await database.updateSource(importID: installed.importID, replacing: installed, configuration: [], consent: .managedOnly)
            }
            #expect(try await database.sourceInstallations() == [installed])
            let book = try #require(try await database.books().first)
            #expect(try await database.checkpoint(for: book.id)?.position == position)
        }
    }

    @Test func newInstallCannotSilentlyAttachUnregisteredLocalBooks() async throws {
        try await withLibrary { _, database in
            let id = SourceInstallationID()
            let (book, _, _) = try await libraryData(database, installation: id)
            let candidate = try await stage(database, "one")
            await #expect(throws: SourceInstallationFailure.restorationRequired) {
                try await database.installSource(importID: candidate.id, id: id, configuration: [], consent: .managedOnly)
            }
            #expect(try await database.sourceInstallations().isEmpty)
            #expect(try await database.books() == [book])
        }
    }

    @Test func schemaThreeUpgradeRetainsImportsAndReadonlyRefusesToMigrate() async throws {
        try await withLibrary { path, database in
            let candidate = try await stage(database, "one")
            try await database.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try $0.execute(sql: "DROP TABLE book_reference; ALTER TABLE library_book DROP COLUMN catalog_reference; DROP TABLE source_installation; PRAGMA user_version=3;") }
            try raw.close()
            #expect(throws: LibraryDatabase.Failure.migrationRequired) { try LibraryDatabase(existingAt: path, readOnly: true) }
            let upgraded = try LibraryDatabase(existingAt: path)
            #expect(try await upgraded.sourceImports() == [candidate])
            #expect(try await upgraded.sourceInstallations().isEmpty)
            let installed = try await upgraded.installSource(importID: candidate.id, id: SourceInstallationID(), configuration: [], consent: .managedOnly)
            #expect(installed.scriptSHA256 == candidate.scriptSHA256)
            try await upgraded.close()
        }
    }

    @Test func laterMigrationFailureRollsBackEarlierNewTablesAndVersion() async throws {
        try await withLibrary { path, database in
            try await database.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try $0.execute(sql: """
                DROP TABLE book_reference; ALTER TABLE library_book DROP COLUMN catalog_reference; DROP TABLE source_installation; DROP TABLE source_import; DROP TABLE source_script;
                CREATE TABLE source_installation(marker TEXT); INSERT INTO source_installation VALUES('retained');
                PRAGMA user_version=2;
                """) }
            #expect(throws: DatabaseError.self) { try LibraryDatabase(existingAt: path) }
            let result = try await raw.read { db in
                try (Int.fetchOne(db, sql: "PRAGMA user_version"),
                     Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name IN ('source_import','source_script')"),
                     String.fetchOne(db, sql: "SELECT marker FROM source_installation"))
            }
            #expect(result.0 == 2 && result.1 == 0 && result.2 == "retained")
            try raw.close()
        }
    }

    private func install(_ database: LibraryDatabase, consent: SourceCredentialReadConsent = .managedOnly) async throws -> SourceInstallationSnapshot {
        let receipt = try await stage(database, "one")
        return try await database.installSource(importID: receipt.id, id: SourceInstallationID(), configuration: [], consent: consent)
    }

    private func stage(_ database: LibraryDatabase, _ tag: String, sourceID: String = "org.example.source",
                       referenceVersion: Int = 1, stateVersion: Int = 1) async throws -> SourceImportRecord {
        let digests = ["one": "fe937a32ee0fa9be5c27533dc08408778651049d53f7ad9ea59b706f8046232f",
                       "two": "3a19149db85385064d1d9313a2b1007f9584c868cce700cf79aea8b9207a33ca",
                       "other": "84b0a684f1e3a9ffae0c124ab329696d1ca80e911d3cbc4749e908098a3a2a70",
                       "upgrade": "1a964fd1ad01de2c691b5c4dcc376a8a5cdada12d981994d18876f0367dc3147"]
        let digest = try #require(digests[tag])
        let script = try SourceScriptSnapshot(bytes: Data("// fixture-\(tag)\n".utf8),
            metadata: .init(sourceID: sourceID, name: "Fixture", scriptVersion: tag, protocolVersion: 1,
                            referenceVersion: referenceVersion, stateVersion: stateVersion), digest: { _ in digest })
        let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: String(repeating: "a", count: 64),
            fileName: "fixture.source.js", importedAt: Date(timeIntervalSince1970: 100))
        try await database.stageSourceScript(script, receipt: receipt)
        return receipt
    }

    private func libraryData(_ database: LibraryDatabase, installation: SourceInstallationID) async throws -> (LibraryBook, CatalogSnapshot, ReadingPosition) {
        let book = try await database.addBook(reference: .init(installationID: installation, referenceVersion: 1, key: "book"), title: "Retained", author: nil)
        let chapter = try ChapterReference(book: book.reference, key: "chapter")
        let catalog = try CatalogSnapshot(book: book.reference, revision: "catalog", entries: [.init(reference: chapter, title: "Chapter")])
        let request = try await database.beginCatalogUpdate(for: book.id)
        #expect(try await database.publishCatalog(catalog, using: request))
        let position = try ReadingPosition(chapter: chapter, documentRevision: "original", normalizationVersion: 1, elementID: "p", utf16Offset: 4)
        let reader = try await database.startReading(book.id)
        #expect(try await database.saveCheckpoint(position, session: reader, sequence: 1))
        return (book, catalog, position)
    }

    private func withLibrary(_ body: (URL, LibraryDatabase) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitInstallations-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove isolated installation data") }
        }
        let path = root.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase.create(at: path)
        do { try await body(path, database); try await database.close() }
        catch {
            do { try await database.close() } catch { Issue.record(error, "Unable to close installation fixture") }
            throw error
        }
    }
}
