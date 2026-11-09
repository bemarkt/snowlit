import Foundation
import GRDB

/// Internal experiment: a single writer and SQLite CAS, with no App integration.
actor ProbeDatabase {
    enum Failure: Error, Equatable {
        case alreadyExists
        case missingDatabase
        case unsupportedSchema
        case invalidCheckpoint
        case injectedRollback
        case integrityCheckFailed
    }

    struct Session: Sendable {
        let bookID: String
        let id: UUID
    }

    struct Checkpoint: Equatable, Sendable {
        let sessionID: UUID
        let sequence: Int64
        let position: String?
    }

    struct BackupFailure: Error {
        let primary: any Error
        let closing: any Error
    }

    private let queue: DatabaseQueue

    /// Existing data is never replaced, migrated, or silently reset by this probe.
    init(at url: URL, create: Bool, readOnly: Bool = false) throws {
        guard !create || !readOnly else { throw Failure.invalidCheckpoint }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if create && exists { throw Failure.alreadyExists }
        if !create && !exists { throw Failure.missingDatabase }
        var configuration = Configuration()
        configuration.readonly = readOnly
        // Preserve an existing database's journal mode, including on rejected schemas.
        if create { configuration.journalMode = .wal }
        configuration.busyMode = .timeout(2) // Experiment contention deadline, not a product budget.
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        if create {
            try queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE checkpoint (
                        book_id TEXT PRIMARY KEY NOT NULL,
                        session_id TEXT NOT NULL,
                        sequence INTEGER NOT NULL CHECK(sequence >= 0),
                        position TEXT
                    );
                    PRAGMA user_version = 1;
                    """)
            }
        } else {
            try queue.read { db in
                guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 1 else {
                    throw Failure.unsupportedSchema
                }
                guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else {
                    throw Failure.integrityCheckFailed
                }
                // Check expected columns too, so an unrelated version-1 DB is not accepted.
                _ = try Row.fetchAll(db, sql: "SELECT book_id, session_id, sequence, position FROM checkpoint LIMIT 0")
            }
        }
        self.queue = queue
    }

    func startSession(bookID: String) throws -> Session {
        guard !bookID.isEmpty else { throw Failure.invalidCheckpoint }
        let session = Session(bookID: bookID, id: UUID())
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO checkpoint (book_id, session_id, sequence, position) VALUES (?, ?, 0, NULL)
                ON CONFLICT(book_id) DO UPDATE SET session_id=excluded.session_id, sequence=0
                """, arguments: [bookID, session.id.uuidString])
        }
        return session
    }

    /// Sequence and session are checked in the UPDATE itself, including across connections.
    /// A new reading session preserves the old position while invalidating all old writers.
    @discardableResult
    func save(_ session: Session, sequence: Int64, position: String,
              failBeforeCommit: Bool = false) throws -> Bool {
        guard sequence > 0 else { throw Failure.invalidCheckpoint }
        return try queue.write { db in
            try db.execute(sql: """
                UPDATE checkpoint SET sequence=?, position=?
                WHERE book_id=? AND session_id=? AND sequence < ?
                """, arguments: [sequence, position, session.bookID, session.id.uuidString, sequence])
            let changed = db.changesCount == 1
            if failBeforeCommit { throw Failure.injectedRollback }
            return changed
        }
    }

    func checkpoint(bookID: String) throws -> Checkpoint? {
        try queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM checkpoint WHERE book_id=?",
                                             arguments: [bookID]) else { return nil }
            let rawSession: String = row["session_id"]
            guard let sessionID = UUID(uuidString: rawSession) else { throw Failure.invalidCheckpoint }
            return Checkpoint(sessionID: sessionID, sequence: row["sequence"], position: row["position"])
        }
    }

    /// Uses SQLite's backup API while WAL is live; never copies only the main sqlite file.
    func backup(to destination: URL, failDuringCopy: Bool = false) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.alreadyExists }
        let backup = try DatabaseQueue(path: destination.path)
        do {
            try queue.backup(to: backup, pagesPerStep: failDuringCopy ? 1 : -1) { progress in
                if failDuringCopy && !progress.isCompleted { throw Failure.injectedRollback }
            }
            try backup.close()
        } catch let primary {
            // The incomplete candidate is retained for diagnosis, never adopted as active data.
            do { try backup.close() }
            catch { throw BackupFailure(primary: primary, closing: error) }
            throw primary
        }
    }

    func close() throws { try queue.close() }

    /// An SQLite-level disk-full experiment; it does not fill the user's disk.
    func constrainGrowthToCurrentPages() throws -> Int {
        try queue.writeWithoutTransaction { db in
            let original = try Int.fetchOne(db, sql: "PRAGMA max_page_count")!
            let count = try Int.fetchOne(db, sql: "PRAGMA page_count")!
            _ = try Int.fetchOne(db, sql: "PRAGMA max_page_count=\(count)")
            return original
        }
    }

    func restorePageLimit(_ count: Int) throws {
        guard count > 0 else { throw Failure.invalidCheckpoint }
        _ = try queue.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA max_page_count=\(count)") }
    }
}
