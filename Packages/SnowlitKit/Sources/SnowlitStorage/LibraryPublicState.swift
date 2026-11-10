import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase: SourcePublicStateStore {
    public func beginPublicStateAccess(installationID: SourceInstallationID, stateVersion: Int) throws -> SourcePublicStateAccess {
        try checkOpen()
        try Task.checkCancellation()
        let access = try SourcePublicStateAccess(installationID: installationID, stateVersion: stateVersion)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM source_state_operation WHERE installation=?", arguments: [installationID.rawValue.uuidString])
            try db.execute(sql: """
                INSERT INTO source_state_access (installation, state_version, access_id) VALUES (?, ?, ?)
                ON CONFLICT(installation) DO UPDATE SET state_version=excluded.state_version, access_id=excluded.access_id
                """, arguments: [installationID.rawValue.uuidString, stateVersion, access.id.uuidString])
        }
        return access
    }

    public func beginPublicStateOperation(requestID: UUID, using access: SourcePublicStateAccess) throws -> SourcePublicStateOperation {
        try checkOpen()
        try Task.checkCancellation()
        try queue.write { db in
            try Self.checkPublicStateAccess(db, access)
            try db.execute(sql: "INSERT INTO source_state_operation (installation, access_id, request_id, active) VALUES (?, ?, ?, 1)",
                arguments: [access.installationID.rawValue.uuidString, access.id.uuidString, requestID.uuidString])
        }
        return .init(access: access, requestID: requestID)
    }

    public func revokePublicStateOperation(_ operation: SourcePublicStateOperation) throws {
        try checkOpen()
        try queue.write { db in
            // Retain the spent ID until its access session ends, preventing replay.
            try db.execute(sql: "UPDATE source_state_operation SET active=0 WHERE installation=? AND access_id=? AND request_id=?",
                arguments: [operation.access.installationID.rawValue.uuidString, operation.access.id.uuidString, operation.requestID.uuidString])
        }
    }

    public func revokePublicStateAccess(_ access: SourcePublicStateAccess) throws {
        try checkOpen()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM source_state_access WHERE installation=? AND state_version=? AND access_id=?",
                arguments: [access.installationID.rawValue.uuidString, access.stateVersion, access.id.uuidString])
        }
    }

    public func readPublicState(using access: SourcePublicStateAccess) throws -> SourcePublicState {
        try checkOpen()
        try Task.checkCancellation()
        return try queue.read { db in
            try Self.checkPublicStateAccess(db, access)
            return try Self.publicState(db, access)
        }
    }

    public func writePublicState(_ entries: [SourcePublicStateEntry], expectedRevision: Int,
                                  using operation: SourcePublicStateOperation) throws -> SourcePublicStateWrite {
        try checkOpen()
        try Task.checkCancellation()
        let access = operation.access
        _ = try SourcePublicState(stateVersion: access.stateVersion, revision: expectedRevision, entries: entries)
        return try queue.write { db in
            try Self.checkPublicStateAccess(db, access)
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM source_state_operation WHERE installation=? AND access_id=? AND request_id=? AND active=1)
                """, arguments: [access.installationID.rawValue.uuidString, access.id.uuidString, operation.requestID.uuidString]) == true else {
                throw SourcePublicStateFailure.staleAccess
            }
            let current = try Self.publicState(db, access)
            guard current.revision == expectedRevision else { return .init(written: false, snapshot: current) }
            guard current.revision < 9_007_199_254_740_991 else { throw SourcePublicStateFailure.revisionExhausted }
            let next = try SourcePublicState(stateVersion: access.stateVersion, revision: current.revision + 1, entries: entries)
            let bytes = try JSONEncoder().encode(next.entries)
            try db.execute(sql: """
                INSERT INTO source_public_state (installation, state_version, revision, entries) VALUES (?, ?, ?, ?)
                ON CONFLICT(installation, state_version) DO UPDATE SET revision=excluded.revision, entries=excluded.entries
                """, arguments: [access.installationID.rawValue.uuidString, access.stateVersion, next.revision, bytes])
            return .init(written: true, snapshot: next)
        }
    }

    private static func checkPublicStateAccess(_ db: Database, _ access: SourcePublicStateAccess) throws {
        guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM source_state_access WHERE installation=? AND state_version=? AND access_id=?)
            """, arguments: [access.installationID.rawValue.uuidString, access.stateVersion, access.id.uuidString]) == true else {
            throw SourcePublicStateFailure.staleAccess
        }
    }

    private static func publicState(_ db: Database, _ access: SourcePublicStateAccess) throws -> SourcePublicState {
        guard let row = try Row.fetchOne(db, sql: "SELECT revision, entries FROM source_public_state WHERE installation=? AND state_version=?",
                                        arguments: [access.installationID.rawValue.uuidString, access.stateVersion]) else {
            return try .init(stateVersion: access.stateVersion, revision: 0, entries: [])
        }
        let bytes: Data = row["entries"]
        return try .init(stateVersion: access.stateVersion, revision: row["revision"],
                         entries: JSONDecoder().decode([SourcePublicStateEntry].self, from: bytes))
    }

    /// Schema 1 -> 2 is additive and transactional; it never replaces library data.
    static let publicStateSchema = """
        CREATE TABLE source_public_state (
            installation TEXT NOT NULL,
            state_version INTEGER NOT NULL CHECK(state_version > 0),
            revision INTEGER NOT NULL CHECK(revision > 0 AND revision <= 9007199254740991),
            entries BLOB NOT NULL,
            PRIMARY KEY(installation, state_version)
        );
        CREATE TABLE source_state_access (
            installation TEXT PRIMARY KEY NOT NULL,
            state_version INTEGER NOT NULL CHECK(state_version > 0),
            access_id TEXT NOT NULL
        );
        CREATE TABLE source_state_operation (
            installation TEXT NOT NULL REFERENCES source_state_access(installation) ON DELETE CASCADE,
            access_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            active INTEGER NOT NULL CHECK(active IN (0, 1)),
            PRIMARY KEY(installation, access_id, request_id)
        );
        PRAGMA user_version = 2;
        """
}
