import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase: SourceScriptStore {
    public func stageSourceScript(_ script: SourceScriptSnapshot, receipt: SourceImportRecord) throws {
        try checkOpen()
        try Task.checkCancellation()
        guard receipt.scriptSHA256 == script.sha256 else { throw SourceScriptFailure.digestMismatch }
        let metadata = try JSONEncoder().encode(script.metadata)
        try queue.write { db in
            if let existing = try Row.fetchOne(db, sql: "SELECT bytes, metadata FROM source_script WHERE sha256=?", arguments: [script.sha256]) {
                let bytes: Data = existing["bytes"]
                let encoded: Data = existing["metadata"]
                guard bytes == script.bytes,
                      try JSONDecoder().decode(SourceScriptMetadata.self, from: encoded) == script.metadata else {
                    throw SourceScriptFailure.conflictingScript
                }
            } else {
                try db.execute(sql: "INSERT INTO source_script (sha256, bytes, metadata) VALUES (?, ?, ?)",
                               arguments: [script.sha256, script.bytes, metadata])
            }
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM source_import WHERE id=?", arguments: [receipt.id.uuidString]) {
                guard try Self.decodeSourceImport(existing) == receipt else { throw SourceScriptFailure.invalidImport }
                return
            }
            try db.execute(sql: """
                INSERT INTO source_import (id, script_sha256, inspection_contract_sha256, file_name, imported_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [receipt.id.uuidString, receipt.scriptSHA256, receipt.inspectionContractSHA256,
                                  receipt.fileName, receipt.importedAt.timeIntervalSince1970])
        }
    }

    public func sourceScript(sha256: String, digest: SourceScriptSnapshot.Digest) throws -> SourceScriptSnapshot? {
        try checkOpen()
        try Task.checkCancellation()
        try SourceScriptSnapshot.validateDigest(sha256)
        return try queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT bytes, metadata FROM source_script WHERE sha256=?", arguments: [sha256]) else { return nil }
            let bytes: Data = row["bytes"]
            let metadata: Data = row["metadata"]
            let snapshot = try SourceScriptSnapshot(bytes: bytes,
                metadata: JSONDecoder().decode(SourceScriptMetadata.self, from: metadata), digest: digest)
            guard snapshot.sha256 == sha256 else { throw SourceScriptFailure.digestMismatch }
            return snapshot
        }
    }

    public func sourceImports() throws -> [SourceImportRecord] {
        try checkOpen()
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM source_import ORDER BY rowid").map(Self.decodeSourceImport)
        }
    }

    static func decodeSourceImport(_ row: Row) throws -> SourceImportRecord {
        let rawID: String = row["id"]
        guard let id = UUID(uuidString: rawID) else { throw Failure.inconsistentData }
        return try SourceImportRecord(id: id, scriptSHA256: row["script_sha256"],
            inspectionContractSHA256: row["inspection_contract_sha256"], fileName: row["file_name"],
            importedAt: Date(timeIntervalSince1970: row["imported_at"]))
    }

    /// Script candidates are ordinary library data; no website sessions or grants
    /// are serialized. Installation activation is a separate transaction.
    static let sourceScriptSchema = """
        CREATE TABLE source_script (
            sha256 TEXT PRIMARY KEY NOT NULL CHECK(length(sha256) = 64),
            bytes BLOB NOT NULL CHECK(length(bytes) > 0),
            metadata BLOB NOT NULL
        );
        CREATE TABLE source_import (
            id TEXT PRIMARY KEY NOT NULL,
            script_sha256 TEXT NOT NULL REFERENCES source_script(sha256),
            inspection_contract_sha256 TEXT NOT NULL CHECK(length(inspection_contract_sha256) = 64),
            file_name TEXT NOT NULL CHECK(length(file_name) > 0),
            imported_at REAL NOT NULL
        );
        PRAGMA user_version = 3;
        """
}
