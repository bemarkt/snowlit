import Foundation
import GRDB
import SnowlitCore
import Testing
@testable import SnowlitStorage

struct LibrarySourceStateAdoptionTests {
    @Test func stateAndScriptCommitTogetherPreservingLocalDataAndRevokingOldWrites() async throws {
        try await withFixture { path, db, original, candidate, book in
            let access = try await db.beginInstalledPublicStateAccess(expected: original)
            let operation = try await db.beginPublicStateOperation(requestID: UUID(), using: access)
            let oldEntry = try SourcePublicStateEntry(key: "category", value: "old")
            #expect(try await db.writePublicState([oldEntry], expectedRevision: 0, using: operation).written)
            let catalog = try savedCatalog(book)
            let initial = try await db.beginCatalogUpdate(for: book.id)
            #expect(try await db.publishCatalog(catalog, using: initial))
            let request = try await db.beginCatalogUpdate(for: book.id)
            let reader = try await db.startReading(book.id)
            let position = try savedPosition(book)
            #expect(try await db.saveCheckpoint(position, session: reader, sequence: 1))
            let prepared = try await db.captureSourceUpdate(importID: candidate.id, expected: original)
            let next = try migratedState()
            let updated = try await db.updateSource(prepared: prepared, migratedState: next,
                configuration: [.boolean(key: "show", value: true)], consent: .managedOnly)
            #expect(updated.id == original.id && updated.revision == original.revision + 1)
            #expect(updated.scriptSHA256 == candidate.scriptSHA256 && !updated.allowsCredentialRead)
            #expect(updated.websiteSessionID == original.websiteSessionID && updated.canExecute)
            #expect(try await db.books() == [book])
            #expect(try await db.catalog(for: book.id) == catalog)
            #expect(try await db.checkpoint(for: book.id)?.position == position)
            #expect(try await db.saveCheckpoint(position, session: reader, sequence: 2))
            #expect(try await !db.publishCatalog(catalog, using: request))
            await #expect(throws: SourcePublicStateFailure.staleAccess) { try await db.writePublicState([], expectedRevision: 1, using: operation) }
            let fresh = try await db.beginInstalledPublicStateAccess(expected: updated)
            #expect(try await db.readPublicState(using: fresh) == (try .init(stateVersion: 2, revision: 1, entries: next.entries)))
            let old = try await db.queue.read { try LibraryDatabase.publicState($0, installationID: original.id, version: 1) }
            #expect(old.entries == [oldEntry] && old.revision == 1)
            try await db.close()
            let reopened = try LibraryDatabase(existingAt: path, readOnly: true)
            #expect(try await reopened.sourceInstallations() == [updated])
            #expect(try await reopened.readPublicState(using: fresh).entries == next.entries)
            #expect(try await reopened.checkpoint(for: book.id)?.position == position)
            try await reopened.close()
        }
    }

    enum ConcurrentWrite: CaseIterable, Sendable { case book, catalog, progress, publicState, targetState }

    @Test(arguments: ConcurrentWrite.allCases)
    func anotherConnectionChangingPreparedInputsRejectsAdoption(change: ConcurrentWrite) async throws {
        try await withFixture { path, first, original, candidate, book in
            let access = try await first.beginInstalledPublicStateAccess(expected: original)
            let operation = try await first.beginPublicStateOperation(requestID: UUID(), using: access)
            let token = try await first.beginCatalogUpdate(for: book.id)
            let session = try await first.startReading(book.id)
            let prepared = try await first.captureSourceUpdate(importID: candidate.id, expected: original)
            let second = try LibraryDatabase(existingAt: path)
            switch change {
            case .book:
                _ = try await second.addBook(reference: .init(installationID: original.id, referenceVersion: 1, key: "new-book"), title: "New", author: nil)
            case .catalog:
                #expect(try await second.publishCatalog(savedCatalog(book), using: token))
            case .progress:
                #expect(try await second.saveCheckpoint(savedPosition(book), session: session, sequence: 1))
            case .publicState:
                #expect(try await second.writePublicState([.init(key: "new", value: "retain")], expectedRevision: 0, using: operation).written)
            case .targetState:
                try await second.queue.write { try $0.execute(sql: "INSERT INTO source_public_state VALUES (?, 2, 1, ?)",
                    arguments: [original.id.rawValue.uuidString, try JSONEncoder().encode([SourcePublicStateEntry]())]) }
            }
            let current = try await second.captureSourceUpdate(importID: candidate.id, expected: original)
            await #expect(throws: SourceUpdateFailure.staleInventory) {
                try await first.updateSource(prepared: prepared, migratedState: migratedState(), configuration: [], consent: .managedOnly)
            }
            #expect(try await first.captureSourceUpdate(importID: candidate.id, expected: original) == current)
            #expect(try await first.sourceInstallations() == [original])
            try await second.close()
        }
    }

    @Test func failureAfterStateWriteRollsBackTargetScriptAndPermissions() async throws {
        try await withFixture { _, db, original, candidate, _ in
            let access = try await db.beginInstalledPublicStateAccess(expected: original)
            let operation = try await db.beginPublicStateOperation(requestID: UUID(), using: access)
            try await db.queue.write { sql in
                try sql.execute(sql: "INSERT INTO source_public_state VALUES (?, 2, 7, ?)",
                    arguments: [original.id.rawValue.uuidString, try JSONEncoder().encode([SourcePublicStateEntry(key: "older", value: "keep")])])
                try sql.execute(sql: "CREATE TRIGGER reject_revocation BEFORE DELETE ON source_state_access BEGIN SELECT RAISE(ABORT, 'injected failure'); END;")
            }
            let prepared = try await db.captureSourceUpdate(importID: candidate.id, expected: original)
            await #expect(throws: DatabaseError.self) {
                try await db.updateSource(prepared: prepared, migratedState: migratedState(), configuration: [], consent: .managedOnly)
            }
            #expect(try await db.captureSourceUpdate(importID: candidate.id, expected: original) == prepared)
            #expect(try await db.readPublicState(using: access).revision == 0)
            try await db.queue.write { try $0.execute(sql: "DROP TRIGGER reject_revocation") }
            let updated = try await db.updateSource(prepared: prepared, migratedState: migratedState(), configuration: [], consent: .managedOnly)
            let fresh = try await db.beginInstalledPublicStateAccess(expected: updated)
            #expect(try await db.readPublicState(using: fresh).revision == 8)
            await #expect(throws: SourcePublicStateFailure.staleAccess) { try await db.writePublicState([], expectedRevision: 0, using: operation) }
        }
    }

    @Test func missingMalformedOrUnneededStateMigrationCannotReplaceTheCurrentInstallation() async throws {
        try await withFixture { _, db, original, candidate, _ in
            let prepared = try await db.captureSourceUpdate(importID: candidate.id, expected: original)
            for state in [nil, try SourcePublicState(stateVersion: 3, revision: 0, entries: []),
                          try SourcePublicState(stateVersion: 2, revision: 1, entries: [])] {
                await #expect(throws: SourceUpdateFailure.invalidMigration) {
                    try await db.updateSource(prepared: prepared, migratedState: state, configuration: [], consent: .managedOnly)
                }
            }
            let same = try await stage(db, "same", stateVersion: 1)
            let samePrepared = try await db.captureSourceUpdate(importID: same.id, expected: original)
            await #expect(throws: SourceUpdateFailure.invalidMigration) {
                try await db.updateSource(prepared: samePrepared, migratedState: .init(stateVersion: 1, revision: 0, entries: []), configuration: [], consent: .managedOnly)
            }
            let references = try await stage(db, "references", stateVersion: 2, referenceVersion: 2)
            let referencesPrepared = try await db.captureSourceUpdate(importID: references.id, expected: original)
            await #expect(throws: SourceInstallationFailure.migrationRequired) {
                try await db.updateSource(prepared: referencesPrepared, migratedState: migratedState(), configuration: [], consent: .managedOnly)
            }
            #expect(try await db.sourceInstallations() == [original])
            let updated = try await db.updateSource(prepared: samePrepared, migratedState: nil, configuration: [], consent: .managedOnly)
            #expect(updated.importID == same.id && updated.metadata.stateVersion == 1)
        }
    }

    @Test func removedSourceUsesExplicitRestorationAndKeepsItsLocalIdentity() async throws {
        try await withFixture { _, db, original, candidate, book in
            let removed = try await db.removeSource(expected: original)
            #expect(try await db.finishSourceSessionCleanup(#require(removed.pendingCleanup), installationID: original.id))
            let cleaned = try #require(try await db.sourceInstallations().first)
            let prepared = try await db.captureSourceUpdate(importID: candidate.id, expected: cleaned)
            await #expect(throws: SourceInstallationFailure.invalidState) {
                try await db.updateSource(prepared: prepared, migratedState: migratedState(), configuration: [], consent: .managedOnly)
            }
            let restored = try await db.restoreSource(confirmed: prepared, migratedState: migratedState(), configuration: [], consent: .managedOnly)
            #expect(restored.id == original.id && restored.canExecute && !restored.allowsCredentialRead)
            #expect(restored.websiteSessionID != original.websiteSessionID)
            #expect(try await db.books() == [book])
            await #expect(throws: SourceInstallationFailure.staleInstallation) {
                try await db.restoreSource(confirmed: prepared, migratedState: migratedState(), configuration: [], consent: .managedOnly)
            }
        }
    }

    @Test func twoPreparedWritersCannotBothAdoptTheSameMigration() async throws {
        try await withFixture { path, first, original, candidate, _ in
            let second = try LibraryDatabase(existingAt: path)
            let prepared = try await first.captureSourceUpdate(importID: candidate.id, expected: original)
            #expect(try await second.captureSourceUpdate(importID: candidate.id, expected: original) == prepared)
            let winner = try await first.updateSource(prepared: prepared, migratedState: migratedState(), configuration: [], consent: .managedOnly)
            await #expect(throws: SourceInstallationFailure.staleInstallation) {
                try await second.updateSource(prepared: prepared, migratedState: migratedState(), configuration: [], consent: .approvedForCandidate)
            }
            #expect(try await second.sourceInstallations() == [winner])
            #expect(!winner.allowsCredentialRead)
            try await second.close()
        }
    }

    private func migratedState() throws -> SourcePublicState {
        try .init(stateVersion: 2, revision: 0, entries: [.init(key: "selectedCategory", value: "new")])
    }
    private func savedCatalog(_ book: LibraryBook) throws -> CatalogSnapshot {
        try .init(book: book.reference, revision: "saved", entries: [.init(reference: .init(book: book.reference, key: "chapter"), title: "Chapter")])
    }
    private func savedPosition(_ book: LibraryBook) throws -> ReadingPosition {
        try .init(chapter: .init(book: book.reference, key: "chapter"), documentRevision: "saved", normalizationVersion: 1, elementID: "p", utf16Offset: 3)
    }
    private func stage(_ db: LibraryDatabase, _ tag: String, stateVersion: Int, referenceVersion: Int = 1) async throws -> SourceImportRecord {
        let digests = ["one": "22c5892a20c74aca2cd29d6035eae625bef9773164a944f63549a94930e05b1e",
                       "two": "f9df7bc1ed2d8d4bfed4f4ef82f5a6e197744558bc9a42a7708a4cd61eed4959",
                       "same": "037a187acc127ec3c8196814f1bfacd41d7a2190531105b0f3f2b964fbc64f27",
                       "references": "dda36412a306b5abf0fbd7dab1edfc18f6b8bcf25b47f7eecbe8ed6a369e72aa"]
        let digest = try #require(digests[tag])
        let script = try SourceScriptSnapshot(bytes: Data("// \(tag)\n".utf8),
            metadata: .init(sourceID: "org.example.source", name: "Fixture", scriptVersion: tag, protocolVersion: 1,
                            referenceVersion: referenceVersion, stateVersion: stateVersion), digest: { _ in digest })
        let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: String(repeating: "f", count: 64),
            fileName: "fixture.source.js", importedAt: Date(timeIntervalSince1970: 1))
        try await db.stageSourceScript(script, receipt: receipt)
        return receipt
    }
    private func withFixture(_ body: (URL, LibraryDatabase, SourceInstallationSnapshot, SourceImportRecord, LibraryBook) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitStateAdoption-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove isolated adoption data") }
        }
        let path = root.appendingPathComponent("library.sqlite")
        let db = try LibraryDatabase.create(at: path)
        do {
            let original = try await stage(db, "one", stateVersion: 1)
            let installed = try await db.installSource(importID: original.id, id: SourceInstallationID(), configuration: [], consent: .approvedForCandidate)
            let candidate = try await stage(db, "two", stateVersion: 2)
            let book = try await db.addBook(reference: .init(installationID: installed.id, referenceVersion: 1, key: "book"), title: "Saved", author: nil)
            try await body(path, db, installed, candidate, book)
            try await db.close()
        } catch {
            do { try await db.close() } catch { Issue.record(error, "Unable to close adoption fixture") }
            throw error
        }
    }
}
