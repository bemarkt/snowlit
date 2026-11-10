import Foundation
import GRDB
import SnowlitCore
import Testing
@testable import SnowlitStorage

struct LibrarySourceScriptTests {
    @Test func importsRetainOriginalBytesAndIndependentReceiptsAcrossConnectionsAndReopen() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let first = try LibraryDatabase.create(at: path)
            let second = try LibraryDatabase(existingAt: path)
            let script = try snapshot("\u{FEFF}// first\r\n")
            let receipt = try receipt(script)
            try await first.stageSourceScript(script, receipt: receipt)
            try await second.stageSourceScript(script, receipt: receipt) // An exact retry is idempotent.
            let reimport = try self.receipt(script)
            try await second.stageSourceScript(script, receipt: reimport)
            let newBytes = try snapshot("// second\r\n") // The display version need not change.
            try await first.stageSourceScript(newBytes, receipt: self.receipt(newBytes))
            #expect(try await first.sourceImports().count == 3)
            #expect(try await first.books().isEmpty)
            try await first.close(); try await second.close()
            let reopened = try LibraryDatabase(existingAt: path, readOnly: true)
            #expect(try await reopened.sourceScript(sha256: script.sha256, digest: Self.fixtureDigest) == script)
            #expect(try await reopened.sourceScript(sha256: newBytes.sha256, digest: Self.fixtureDigest) == newBytes)
            #expect(try await reopened.sourceImports().prefix(2) == [receipt, reimport])
            await #expect(throws: DatabaseError.self) {
                try await reopened.stageSourceScript(script, receipt: self.receipt(script))
            }
            try await reopened.close()
        }
    }

    @Test func sameDigestNeverReplacesBytesMetadataOrImportProvenance() async throws {
        try await withDirectory { root in
            let database = try LibraryDatabase.create(at: root.appendingPathComponent("library.sqlite"))
            let original = try snapshot("// first\n")
            let savedReceipt = try receipt(original)
            try await database.stageSourceScript(original, receipt: savedReceipt)
            let collision = try SourceScriptSnapshot(bytes: Data("// corrupt\n".utf8), metadata: original.metadata,
                                                    digest: { _ in original.sha256 })
            await #expect(throws: SourceScriptFailure.conflictingScript) {
                try await database.stageSourceScript(collision, receipt: self.receipt(collision))
            }
            let otherSource = try SourceScriptSnapshot(bytes: original.bytes,
                metadata: metadata(sourceID: "org.example.other"), digest: Self.fixtureDigest)
            await #expect(throws: SourceScriptFailure.conflictingScript) {
                try await database.stageSourceScript(otherSource, receipt: self.receipt(otherSource))
            }
            let changedReceipt = try SourceImportRecord(id: savedReceipt.id, scriptSHA256: original.sha256,
                inspectionContractSHA256: savedReceipt.inspectionContractSHA256, fileName: "changed.source.js", importedAt: savedReceipt.importedAt)
            await #expect(throws: SourceScriptFailure.invalidImport) {
                try await database.stageSourceScript(original, receipt: changedReceipt)
            }
            #expect(try await database.sourceImports() == [savedReceipt])
            #expect(try await database.sourceScript(sha256: original.sha256, digest: Self.fixtureDigest) == original)
            try await database.close()
        }
    }

    @Test func importFailureRollsBackNewBytesAndPreservesExistingCandidates() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase.create(at: path)
            let original = try snapshot("// first\n")
            let savedReceipt = try receipt(original)
            try await database.stageSourceScript(original, receipt: savedReceipt)
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try $0.execute(sql: "CREATE TRIGGER fail_import BEFORE INSERT ON source_import BEGIN SELECT RAISE(ABORT, 'injected import failure'); END;") }
            let candidate = try snapshot("// second\r\n")
            await #expect(throws: DatabaseError.self) {
                try await database.stageSourceScript(candidate, receipt: self.receipt(candidate))
            }
            #expect(try await database.sourceScript(sha256: candidate.sha256, digest: Self.fixtureDigest) == nil)
            #expect(try await database.sourceImports() == [savedReceipt])
            try await raw.write { try $0.execute(sql: "DROP TRIGGER fail_import") }
            try raw.close()
            try await database.stageSourceScript(candidate, receipt: receipt(candidate))
            #expect(try await database.sourceImports().count == 2)
            try await database.close()
        }
    }

    @Test func alteredStoredBytesAreRejectedOnRead() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase.create(at: path)
            let original = try snapshot("// first\n")
            try await database.stageSourceScript(original, receipt: receipt(original))
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try $0.execute(sql: "UPDATE source_script SET bytes=?", arguments: [Data("// corrupt\n".utf8)]) }
            try raw.close()
            await #expect(throws: SourceScriptFailure.digestMismatch) {
                try await database.sourceScript(sha256: original.sha256, digest: Self.fixtureDigest)
            }
            try await database.close()
        }
    }

    @Test func schemaTwoUpgradeRetainsLibraryAndPublicStateAndReadonlyRejectsMigration() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase.create(at: path)
            let book = try await database.addBook(reference: .init(installationID: SourceInstallationID(), referenceVersion: 1, key: "book"), title: "retained", author: nil)
            let session = try await database.startReading(book.id)
            let position = try ReadingPosition(chapter: .init(book: book.reference, key: "chapter"), documentRevision: "saved", normalizationVersion: 1, elementID: "p", utf16Offset: 2)
            #expect(try await database.saveCheckpoint(position, session: session, sequence: 1))
            let access = try await database.beginPublicStateAccess(installationID: book.reference.installationID, stateVersion: 1)
            let operation = try await database.beginPublicStateOperation(requestID: UUID(), using: access)
            #expect(try await database.writePublicState([.init(key: "public", value: "retained")], expectedRevision: 0, using: operation).written)
            try await database.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try removeSourceInventorySchema($0); try $0.execute(sql: "DROP TABLE book_reference; ALTER TABLE library_book DROP COLUMN catalog_reference; DROP TABLE source_installation; DROP TABLE source_import; DROP TABLE source_script; PRAGMA user_version=2;") }
            try raw.close()
            let before = try Data(contentsOf: path)
            #expect(throws: LibraryDatabase.Failure.migrationRequired) { try LibraryDatabase(existingAt: path, readOnly: true) }
            #expect(try Data(contentsOf: path) == before)
            let upgraded = try LibraryDatabase(existingAt: path)
            #expect(try await upgraded.books() == [book])
            #expect(try await upgraded.checkpoint(for: book.id)?.position == position)
            #expect(try await upgraded.readPublicState(using: access).revision == 1)
            let script = try snapshot("// first\n")
            try await upgraded.stageSourceScript(script, receipt: receipt(script))
            #expect(try await upgraded.sourceScript(sha256: script.sha256, digest: Self.fixtureDigest) == script)
            try await upgraded.close()
        }
    }

    @Test func failedSchemaTwoMigrationRollsBackItsFirstTableAndVersion() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase.create(at: path)
            try await database.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try removeSourceInventorySchema($0); try $0.execute(sql: "DROP TABLE book_reference; ALTER TABLE library_book DROP COLUMN catalog_reference; DROP TABLE source_installation; DROP TABLE source_import; DROP TABLE source_script; CREATE TABLE source_import(marker TEXT); INSERT INTO source_import VALUES('retain'); PRAGMA user_version=2;") }
            #expect(throws: DatabaseError.self) { try LibraryDatabase(existingAt: path) }
            let result = try await raw.read { db in
                try (Int.fetchOne(db, sql: "PRAGMA user_version"),
                     Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name='source_script'"),
                     String.fetchOne(db, sql: "SELECT marker FROM source_import"))
            }
            #expect(result.0 == 2 && result.1 == 0 && result.2 == "retain")
            try raw.close()
        }
    }

    private func metadata(sourceID: String = "org.example.source") throws -> SourceScriptMetadata {
        try .init(sourceID: sourceID, name: "Source", scriptVersion: "1", protocolVersion: 1, referenceVersion: 1, stateVersion: 1)
    }
    private func snapshot(_ source: String) throws -> SourceScriptSnapshot {
        try .init(bytes: Data(source.utf8), metadata: metadata(), digest: Self.fixtureDigest)
    }
    private func receipt(_ script: SourceScriptSnapshot) throws -> SourceImportRecord {
        try .init(scriptSHA256: script.sha256, inspectionContractSHA256: String(repeating: "a", count: 64),
                  fileName: "example.source.js", importedAt: Date(timeIntervalSince1970: 1_000))
    }
    // Precomputed SHA-256 vectors keep portable tests independent of Apple CryptoKit.
    private static func fixtureDigest(_ bytes: Data) throws -> String {
        switch bytes {
        case Data("// first\n".utf8): "df42160d1f5acf7bee611550c19ef8eec50071d96f12608fa7b31fff8195c48a"
        case Data("// second\r\n".utf8): "8cfc6e9233c8ac95fec7fd15ed33763560db9ac582f98e6b89a610dca6155c44"
        case Data("\u{FEFF}// first\r\n".utf8): "08b3755934ed63f9805f872e7367e63cf40d9ac29d705fd261348364b2618dc5"
        case Data("// corrupt\n".utf8): "545100f2ea46eb6581a57bbdab066a3bc1e1c3566f133b757641e18373044898"
        default: throw SourceScriptFailure.invalidBytes
        }
    }
    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitImports-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove isolated import data") }
        }
        try await body(root)
    }
}
