import Foundation
import GRDB
import Testing
@testable import SnowlitStorage

struct ProbeDatabaseTests {
    @Test func sqliteFullRollsBackAndCanRecoverWhenCapacityReturns() async throws {
        try await withDirectory { root in
            let db = try ProbeDatabase(at: root.appendingPathComponent("db.sqlite"), create: true)
            let session = try await db.startSession(bookID: "book")
            try await db.save(session, sequence: 1, position: "safe")
            let originalLimit = try await db.constrainGrowthToCurrentPages()
            do {
                try await db.save(session, sequence: 2, position: String(repeating: "x", count: 1_000_000))
                Issue.record("The SQLite capacity limit did not reject growth")
            } catch let error as DatabaseError {
                #expect(error.resultCode == .SQLITE_FULL)
            }
            #expect(try await db.checkpoint(bookID: "book")?.position == "safe")
            try await db.restorePageLimit(originalLimit)
            #expect(try await db.save(session, sequence: 2, position: "recovered"))
            try await db.close()
        }
    }

    @Test func readonlyDatabaseReportsWriteFailureAndRetainsSavedContent() async throws {
        try await withDirectory { root in
            let file = root.appendingPathComponent("db.sqlite")
            let writer = try ProbeDatabase(at: file, create: true)
            let session = try await writer.startSession(bookID: "book")
            try await writer.save(session, sequence: 1, position: "keep")
            try await writer.close()
            let reader = try ProbeDatabase(at: file, create: false, readOnly: true)
            do {
                try await reader.save(session, sequence: 2, position: "cannot write")
                Issue.record("A readonly connection accepted a write")
            } catch let error as DatabaseError {
                #expect(error.resultCode == .SQLITE_READONLY)
            }
            #expect(try await reader.checkpoint(bookID: "book")?.position == "keep")
            try await reader.close()
        }
    }

    @Test func interruptedBackupLeavesTheSourceIntactAndCandidateUnadopted() async throws {
        try await withDirectory { root in
            let db = try ProbeDatabase(at: root.appendingPathComponent("live.sqlite"), create: true)
            let session = try await db.startSession(bookID: "book")
            let value = String(repeating: "正文", count: 10_000)
            try await db.save(session, sequence: 1, position: value)
            let candidate = root.appendingPathComponent("incomplete.sqlite")
            await #expect(throws: ProbeDatabase.Failure.injectedRollback) {
                try await db.backup(to: candidate, failDuringCopy: true)
            }
            #expect(throws: (any Error).self) { try ProbeDatabase(at: candidate, create: false) }
            #expect(try await db.checkpoint(bookID: "book")?.position == value)
            #expect(try await db.save(session, sequence: 2, position: "still available"))
            try await db.close()
        }
    }

    @Test func outOfOrderAndReplayedCheckpointsCannotMoveProgressBackwards() async throws {
        try await withDirectory { root in
            let db = try ProbeDatabase(at: root.appendingPathComponent("db.sqlite"), create: true)
            let session = try await db.startSession(bookID: "local-book")
            #expect(try await db.save(session, sequence: 20, position: "newer"))
            #expect(try await !db.save(session, sequence: 10, position: "older"))
            #expect(try await !db.save(session, sequence: 20, position: "replay"))
            #expect(try await db.checkpoint(bookID: "local-book")?.position == "newer")
            try await db.close()
        }
    }

    @Test func replacingAReadingSessionPreservesPositionAndRejectsOldWriters() async throws {
        try await withDirectory { root in
            let db = try ProbeDatabase(at: root.appendingPathComponent("db.sqlite"), create: true)
            let first = try await db.startSession(bookID: "book")
            try await db.save(first, sequence: 7, position: "chapter-2")
            let second = try await db.startSession(bookID: "book")
            #expect(try await db.checkpoint(bookID: "book")?.position == "chapter-2")
            #expect(try await !db.save(first, sequence: 1000, position: "late old session"))
            #expect(try await db.save(second, sequence: 1, position: "chapter-3"))
            try await db.close()
        }
    }

    @Test func competingConnectionsConvergeOnTheHighestSequence() async throws {
        try await withDirectory { root in
            let file = root.appendingPathComponent("db.sqlite")
            let first = try ProbeDatabase(at: file, create: true)
            let second = try ProbeDatabase(at: file, create: false)
            let session = try await first.startSession(bookID: "book")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for sequence in 1...60 {
                    group.addTask {
                        let database = sequence.isMultiple(of: 2) ? first : second
                        try await database.save(session, sequence: Int64(sequence), position: "position-\(sequence)")
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await first.checkpoint(bookID: "book")?.sequence == 60)
            #expect(try await second.checkpoint(bookID: "book")?.position == "position-60")
            try await first.close()
            try await second.close()
            let reopened = try ProbeDatabase(at: file, create: false)
            #expect(try await reopened.checkpoint(bookID: "book")?.sequence == 60)
            try await reopened.close()
        }
    }

    @Test func failureAfterSQLUpdateRollsBackBeforeCommit() async throws {
        try await withDirectory { root in
            let file = root.appendingPathComponent("db.sqlite")
            let db = try ProbeDatabase(at: file, create: true)
            let session = try await db.startSession(bookID: "book")
            try await db.save(session, sequence: 1, position: "safe")
            await #expect(throws: ProbeDatabase.Failure.injectedRollback) {
                try await db.save(session, sequence: 2, position: "uncommitted", failBeforeCommit: true)
            }
            try await db.close()
            let reopened = try ProbeDatabase(at: file, create: false)
            #expect(try await reopened.checkpoint(bookID: "book")?.position == "safe")
            try await reopened.close()
        }
    }

    @Test func liveWALBackupReopensIndependentlyAndDoesNotChangeTheSource() async throws {
        try await withDirectory { root in
            let db = try ProbeDatabase(at: root.appendingPathComponent("live.sqlite"), create: true)
            let session = try await db.startSession(bookID: "book")
            try await db.save(session, sequence: 1, position: "snapshot")
            let snapshot = root.appendingPathComponent("backup.sqlite")
            try await db.backup(to: snapshot)
            try await db.save(session, sequence: 2, position: "later")
            let recovered = try ProbeDatabase(at: snapshot, create: false)
            #expect(try await recovered.checkpoint(bookID: "book")?.position == "snapshot")
            #expect(try await db.checkpoint(bookID: "book")?.position == "later")
            try await recovered.close()
            try await db.close()
        }
    }

    @Test func missingCorruptAndUnknownSchemaDatabasesNeverBecomeEmptyReplacements() async throws {
        try await withDirectory { root in
            let missing = root.appendingPathComponent("missing.sqlite")
            #expect(throws: ProbeDatabase.Failure.missingDatabase) { try ProbeDatabase(at: missing, create: false) }
            #expect(!FileManager.default.fileExists(atPath: missing.path))
            let corrupt = root.appendingPathComponent("corrupt.sqlite")
            let bytes = Data("a corrupt database that must be retained".utf8)
            try bytes.write(to: corrupt)
            #expect(throws: (any Error).self) { try ProbeDatabase(at: corrupt, create: false) }
            #expect(try Data(contentsOf: corrupt) == bytes)
            let unknown = root.appendingPathComponent("unknown.sqlite")
            let raw = try DatabaseQueue(path: unknown.path)
            try raw.write { db in
                try db.execute(sql: "CREATE TABLE marker (value TEXT); INSERT INTO marker VALUES ('keep'); PRAGMA user_version=999;")
            }
            try raw.close()
            #expect(throws: ProbeDatabase.Failure.unsupportedSchema) { try ProbeDatabase(at: unknown, create: false) }
            let inspect = try DatabaseQueue(path: unknown.path)
            #expect(try inspect.read { try String.fetchOne($0, sql: "SELECT value FROM marker") } == "keep")
            #expect(try inspect.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 999)
            try inspect.close()
        }
    }

    @Test func existingBackupIsNotOverwrittenAndSourceRemainsWritable() async throws {
        try await withDirectory { root in
            let db = try ProbeDatabase(at: root.appendingPathComponent("live.sqlite"), create: true)
            let existing = root.appendingPathComponent("backup.sqlite")
            let original = Data("preserve existing backup".utf8)
            try original.write(to: existing)
            await #expect(throws: ProbeDatabase.Failure.alreadyExists) { try await db.backup(to: existing) }
            #expect(try Data(contentsOf: existing) == original)
            let session = try await db.startSession(bookID: "book")
            #expect(try await db.save(session, sequence: 1, position: "still usable"))
            try await db.close()
        }
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitDBProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove the isolated test directory") }
        }
        try await body(root)
    }
}
