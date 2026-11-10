import Foundation
import GRDB
import SnowlitCore
import Testing
@testable import SnowlitStorage

struct LibraryPublicStateTests {
    @Test func stateCASAndRevocationAreEnforcedAcrossConnectionsAndReopen() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let first = try LibraryDatabase.create(at: path)
            let second = try LibraryDatabase(existingAt: path)
            let installation = SourceInstallationID()
            let access = try await first.beginPublicStateAccess(installationID: installation, stateVersion: 1)
            let operation = try await first.beginPublicStateOperation(requestID: UUID(), using: access)
            #expect(try await first.readPublicState(using: access).revision == 0)
            let entries = try [SourcePublicStateEntry(key: "é", value: "one"), .init(key: "e\u{301}", value: "two")]
            #expect(try await second.writePublicState(entries, expectedRevision: 0, using: operation).written)
            let conflict = try await first.writePublicState([], expectedRevision: 0, using: operation)
            #expect(!conflict.written && conflict.snapshot.entries == entries && conflict.snapshot.revision == 1)
            let replaced = try await second.beginPublicStateAccess(installationID: installation, stateVersion: 1)
            await #expect(throws: SourcePublicStateFailure.staleAccess) { try await first.writePublicState([], expectedRevision: 1, using: operation) }
            try await first.revokePublicStateAccess(access)
            #expect(try await second.readPublicState(using: replaced).entries == entries)
            try await second.revokePublicStateAccess(replaced)
            await #expect(throws: SourcePublicStateFailure.staleAccess) { try await first.readPublicState(using: replaced) }
            try await first.close(); try await second.close()
            let reopened = try LibraryDatabase(existingAt: path)
            let fresh = try await reopened.beginPublicStateAccess(installationID: installation, stateVersion: 1)
            #expect(try await reopened.readPublicState(using: fresh).entries == entries)
            try await reopened.close()
        }
    }

    @Test func versionsAndInstallationsNeverOverwriteEachOtherAndFailedWriteRollsBack() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase.create(at: path)
            let installation = SourceInstallationID()
            let old = try await database.beginPublicStateAccess(installationID: installation, stateVersion: 1)
            let oldOperation = try await database.beginPublicStateOperation(requestID: UUID(), using: old)
            #expect(try await database.writePublicState([.init(key: "old", value: "retain")], expectedRevision: 0, using: oldOperation).written)
            let next = try await database.beginPublicStateAccess(installationID: installation, stateVersion: 2)
            let nextOperation = try await database.beginPublicStateOperation(requestID: UUID(), using: next)
            #expect(try await database.readPublicState(using: next).entries.isEmpty)
            let other = try await database.beginPublicStateAccess(installationID: SourceInstallationID(), stateVersion: 1)
            #expect(try await database.readPublicState(using: other).entries.isEmpty)
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try $0.execute(sql: "CREATE TRIGGER fail_state BEFORE INSERT ON source_public_state BEGIN SELECT RAISE(ABORT, 'injected failure'); END;") }
            await #expect(throws: DatabaseError.self) { try await database.writePublicState([.init(key: "new", value: "fail")], expectedRevision: 0, using: nextOperation) }
            #expect(try await database.readPublicState(using: next).revision == 0)
            try await raw.write { try $0.execute(sql: "DROP TRIGGER fail_state") }
            try raw.close()
            let restored = try await database.beginPublicStateAccess(installationID: installation, stateVersion: 1)
            #expect(try await database.readPublicState(using: restored).entries == [.init(key: "old", value: "retain")])
            try await database.close()
        }
    }

    @Test func schemaOneMigrationRetainsBooksAndReadonlyDoesNotAttemptMigration() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase.create(at: path)
            let book = try await database.addBook(reference: .init(installationID: SourceInstallationID(), referenceVersion: 1, key: "book"), title: "retained", author: nil)
            try await database.savePreferences(.init(fontSize: 23, theme: .dark))
            try await database.close()
            // The prior schema is the same four library tables, without source state.
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try $0.execute(sql: "DROP TABLE source_import; DROP TABLE source_script; DROP TABLE source_public_state; DROP TABLE source_state_operation; DROP TABLE source_state_access; PRAGMA user_version=1;") }
            try raw.close()
            let before = try Data(contentsOf: path)
            #expect(throws: LibraryDatabase.Failure.migrationRequired) { try LibraryDatabase(existingAt: path, readOnly: true) }
            #expect(try Data(contentsOf: path) == before)
            let upgraded = try LibraryDatabase(existingAt: path)
            #expect(try await upgraded.books() == [book])
            #expect(try await upgraded.preferences().fontSize == 23)
            let access = try await upgraded.beginPublicStateAccess(installationID: book.reference.installationID, stateVersion: 1)
            let operation = try await upgraded.beginPublicStateOperation(requestID: UUID(), using: access)
            #expect(try await upgraded.readPublicState(using: access).revision == 0)
            try await upgraded.close()
            let reopened = try LibraryDatabase(existingAt: path, readOnly: true)
            #expect(try await reopened.books() == [book])
            await #expect(throws: DatabaseError.self) { try await reopened.writePublicState([], expectedRevision: 0, using: operation) }
            try await reopened.close()
        }
    }

    @Test func failedMigrationLeavesVersionAndLibraryDataUntouched() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase.create(at: path)
            let book = try await database.addBook(reference: .init(installationID: SourceInstallationID(), referenceVersion: 1, key: "book"), title: "retained", author: nil)
            try await database.close()
            let raw = try DatabaseQueue(path: path.path)
            try await raw.write { try $0.execute(sql: "DROP TABLE source_import; DROP TABLE source_script; DROP TABLE source_public_state; PRAGMA user_version=1;") }
            // Existing conflicting second table makes the migration fail after its first CREATE.
            #expect(throws: DatabaseError.self) { try LibraryDatabase(existingAt: path) }
            let values = try await raw.read { db in
                try (Int.fetchOne(db, sql: "PRAGMA user_version"),
                     Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name='source_public_state'"),
                     String.fetchOne(db, sql: "SELECT id FROM library_book"))
            }
            #expect(values.0 == 1 && values.1 == 0 && values.2 == book.id.rawValue.uuidString)
            try raw.close()
        }
    }

    @Test func cancelledOperationCannotWriteButAnotherConsumerCanAndIDsCannotReplay() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent("library.sqlite")
            let first = try LibraryDatabase.create(at: path)
            let second = try LibraryDatabase(existingAt: path)
            let access = try await first.beginPublicStateAccess(installationID: SourceInstallationID(), stateVersion: 1)
            let cancelled = try await first.beginPublicStateOperation(requestID: UUID(), using: access)
            let survivor = try await first.beginPublicStateOperation(requestID: UUID(), using: access)
            try await second.revokePublicStateOperation(cancelled)
            await #expect(throws: SourcePublicStateFailure.staleAccess) {
                try await first.writePublicState([.init(key: "late", value: "rejected")], expectedRevision: 0, using: cancelled)
            }
            await #expect(throws: DatabaseError.self) {
                try await second.beginPublicStateOperation(requestID: cancelled.requestID, using: access)
            }
            #expect(try await second.writePublicState([.init(key: "current", value: "accepted")], expectedRevision: 0, using: survivor).written)
            try await first.revokePublicStateAccess(access)
            await #expect(throws: SourcePublicStateFailure.staleAccess) {
                try await second.writePublicState([], expectedRevision: 1, using: survivor)
            }
            try await first.close(); try await second.close()
        }
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitState-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove isolated state data") }
        }
        try await body(root)
    }
}
