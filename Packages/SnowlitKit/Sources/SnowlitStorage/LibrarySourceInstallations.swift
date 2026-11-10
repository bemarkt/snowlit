import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase: SourceInstallationStore {
    public func sourceInstallations() throws -> [SourceInstallationSnapshot] {
        try checkOpen()
        return try queue.read { db in
            try Row.fetchAll(db, sql: Self.installationSelect + " ORDER BY i.rowid").map(Self.decodeInstallation)
        }
    }

    public func installSource(importID: UUID, id: SourceInstallationID, configuration: [SourceSettingValue],
                              consent: SourceCredentialReadConsent) throws -> SourceInstallationSnapshot {
        try checkOpen()
        try Task.checkCancellation()
        try SourceSettingValue.validate(configuration)
        return try queue.write { db in
            let candidate = try Self.importedMetadata(db, importID)
            if let state = try String.fetchOne(db, sql: "SELECT state FROM source_installation WHERE source_id=?",
                                              arguments: [candidate.sourceID]) {
                throw state == "removed" ? SourceInstallationFailure.restorationRequired : .alreadyInstalled
            }
            // Reusing an unregistered identity could silently attach unrelated
            // books or public state. Only the explicit restore path may do so.
            for table in ["library_book", "source_public_state", "source_state_access"] {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE installation=?)",
                                        arguments: [id.rawValue.uuidString]) == false else {
                    throw SourceInstallationFailure.restorationRequired
                }
            }
            try db.execute(sql: """
                INSERT INTO source_installation
                    (id, source_id, import_id, revision, state, configuration, credential_read, website_session, cleanup)
                VALUES (?, ?, ?, 1, 'enabled', ?, ?, ?, NULL)
                """, arguments: [id.rawValue.uuidString, candidate.sourceID, importID.uuidString,
                    try JSONEncoder().encode(configuration), Self.credentialRead(consent), UUID().uuidString])
            return try Self.installation(db, id)
        }
    }

    public func updateSource(importID: UUID, replacing expected: SourceInstallationSnapshot,
                             configuration: [SourceSettingValue], consent: SourceCredentialReadConsent) throws -> SourceInstallationSnapshot {
        try adoptSource(importID: importID, expected: expected, restoring: false, configuration: configuration, consent: consent)
    }

    public func restoreSource(importID: UUID, confirmed expected: SourceInstallationSnapshot,
                              configuration: [SourceSettingValue], consent: SourceCredentialReadConsent) throws -> SourceInstallationSnapshot {
        try adoptSource(importID: importID, expected: expected, restoring: true, configuration: configuration, consent: consent)
    }

    private func adoptSource(importID: UUID, expected: SourceInstallationSnapshot, restoring: Bool,
                             configuration: [SourceSettingValue], consent: SourceCredentialReadConsent) throws -> SourceInstallationSnapshot {
        try SourceSettingValue.validate(configuration)
        return try changeSource(expected) { db, current in
            guard (current.state == .removed) == restoring else { throw SourceInstallationFailure.invalidState }
            guard current.pendingCleanup == nil else { throw SourceInstallationFailure.cleanupPending }
            let candidate = try Self.importedMetadata(db, importID)
            guard candidate.sourceID.utf8.elementsEqual(current.metadata.sourceID.utf8) else {
                throw SourceInstallationFailure.differentSource
            }
            guard candidate.referenceVersion == current.metadata.referenceVersion,
                  candidate.stateVersion == current.metadata.stateVersion,
                  candidate.protocolVersion == current.metadata.protocolVersion else {
                throw SourceInstallationFailure.migrationRequired
            }
            let digest = try String.fetchOne(db, sql: "SELECT script_sha256 FROM source_import WHERE id=?",
                                             arguments: [importID.uuidString])
            guard restoring || digest != current.scriptSHA256 else { throw SourceInstallationFailure.alreadyCurrent }
            try db.execute(sql: """
                UPDATE source_installation SET import_id=?, configuration=?, credential_read=?, state=? WHERE id=?
                """, arguments: [importID.uuidString, try JSONEncoder().encode(configuration), Self.credentialRead(consent),
                    restoring ? "enabled" : current.state.rawValue, current.id.rawValue.uuidString])
        }
    }

    public func setSourceEnabled(_ enabled: Bool, expected: SourceInstallationSnapshot) throws -> SourceInstallationSnapshot {
        try changeSource(expected) { db, current in
            guard current.state != .removed else { throw SourceInstallationFailure.restorationRequired }
            if enabled && current.pendingCleanup != nil { throw SourceInstallationFailure.cleanupPending }
            try db.execute(sql: "UPDATE source_installation SET state=? WHERE id=?",
                           arguments: [enabled ? "enabled" : "disabled", current.id.rawValue.uuidString])
        }
    }

    public func configureSource(_ values: [SourceSettingValue], expected: SourceInstallationSnapshot) throws -> SourceInstallationSnapshot {
        try SourceSettingValue.validate(values)
        return try changeSource(expected) { db, current in
            guard current.state != .removed else { throw SourceInstallationFailure.restorationRequired }
            try db.execute(sql: "UPDATE source_installation SET configuration=? WHERE id=?",
                           arguments: [try JSONEncoder().encode(values), current.id.rawValue.uuidString])
        }
    }

    public func removeSource(expected: SourceInstallationSnapshot) throws -> SourceInstallationSnapshot {
        try changeSource(expected) { db, current in
            try Self.retireWebsiteSession(db, current)
            try db.execute(sql: "UPDATE source_installation SET state='removed', credential_read=0 WHERE id=?",
                           arguments: [current.id.rawValue.uuidString])
        }
    }

    public func signOutSource(expected: SourceInstallationSnapshot) throws -> SourceInstallationSnapshot {
        try changeSource(expected) { db, current in
            guard current.state != .removed else { throw SourceInstallationFailure.restorationRequired }
            try Self.retireWebsiteSession(db, current)
        }
    }

    @discardableResult
    public func finishSourceSessionCleanup(_ cleanup: SourceSessionCleanup, installationID: SourceInstallationID) throws -> Bool {
        try checkOpen()
        try Task.checkCancellation()
        return try queue.write { db in
            let current = try Self.installation(db, installationID)
            guard current.pendingCleanup == cleanup else { return false }
            try Self.advanceInstallation(db, current)
            try db.execute(sql: "UPDATE source_installation SET cleanup=NULL WHERE id=?",
                           arguments: [installationID.rawValue.uuidString])
            return true
        }
    }

    public func beginInstalledPublicStateAccess(expected: SourceInstallationSnapshot) throws -> SourcePublicStateAccess {
        try checkOpen()
        try Task.checkCancellation()
        return try queue.write { db in
            let current = try Self.installation(db, expected.id)
            guard current == expected else { throw SourceInstallationFailure.staleInstallation }
            guard current.canExecute else { throw SourcePublicStateFailure.staleAccess }
            let access = try SourcePublicStateAccess(installationID: current.id, stateVersion: current.metadata.stateVersion)
            try Self.replacePublicStateAccess(db, access)
            return access
        }
    }

    func changeSource(_ expected: SourceInstallationSnapshot,
                              body: (Database, SourceInstallationSnapshot) throws -> Void) throws -> SourceInstallationSnapshot {
        try checkOpen()
        try Task.checkCancellation()
        return try queue.write { db in
            let current = try Self.installation(db, expected.id)
            guard current == expected else { throw SourceInstallationFailure.staleInstallation }
            try body(db, current)
            try Self.advanceInstallation(db, current)
            return try Self.installation(db, current.id)
        }
    }

    private static func advanceInstallation(_ db: Database, _ current: SourceInstallationSnapshot) throws {
        guard current.revision < 9_007_199_254_740_991 else { throw SourceInstallationFailure.revisionExhausted }
        let id = current.id.rawValue.uuidString
        try db.execute(sql: "UPDATE source_installation SET revision=revision+1 WHERE id=?", arguments: [id])
        // These revocations commit with adoption/removal. A stale callback cannot
        // regain write permission after a separate actor-side check.
        try db.execute(sql: "DELETE FROM source_state_access WHERE installation=?", arguments: [id])
        try db.execute(sql: "UPDATE library_book SET catalog_request=NULL WHERE installation=?", arguments: [id])
    }

    private static func retireWebsiteSession(_ db: Database, _ current: SourceInstallationSnapshot) throws {
        guard current.pendingCleanup == nil else { return }
        let cleanup = SourceSessionCleanup(websiteSessionID: current.websiteSessionID)
        try db.execute(sql: "UPDATE source_installation SET website_session=?, cleanup=? WHERE id=?",
                       arguments: [UUID().uuidString, try JSONEncoder().encode(cleanup), current.id.rawValue.uuidString])
    }

    static func credentialRead(_ consent: SourceCredentialReadConsent) -> Bool {
        switch consent { case .managedOnly: false; case .approvedForCandidate: true }
    }

    static func importedMetadata(_ db: Database, _ importID: UUID) throws -> SourceScriptMetadata {
        guard let bytes = try Data.fetchOne(db, sql: """
            SELECT s.metadata FROM source_import r JOIN source_script s ON s.sha256=r.script_sha256 WHERE r.id=?
            """, arguments: [importID.uuidString]) else { throw SourceInstallationFailure.missingImport }
        return try JSONDecoder().decode(SourceScriptMetadata.self, from: bytes)
    }

    static func installation(_ db: Database, _ id: SourceInstallationID) throws -> SourceInstallationSnapshot {
        guard let row = try Row.fetchOne(db, sql: installationSelect + " WHERE i.id=?",
                                        arguments: [id.rawValue.uuidString]) else { throw SourceInstallationFailure.missingInstallation }
        return try decodeInstallation(row)
    }

    private static func decodeInstallation(_ row: Row) throws -> SourceInstallationSnapshot {
        let rawID: String = row["id"], rawImport: String = row["import_id"], rawSession: String = row["website_session"]
        let rawState: String = row["state"], sourceID: String = row["source_id"]
        guard let id = UUID(uuidString: rawID), let importID = UUID(uuidString: rawImport),
              let session = UUID(uuidString: rawSession), let state = SourceInstallationSnapshot.State(rawValue: rawState) else {
            throw Failure.inconsistentData
        }
        let metadata: Data = row["metadata"], configuration: Data = row["configuration"], cleanup: Data? = row["cleanup"]
        let decoded = try JSONDecoder().decode(SourceScriptMetadata.self, from: metadata)
        guard decoded.sourceID.utf8.elementsEqual(sourceID.utf8) else { throw Failure.inconsistentData }
        return try .init(id: SourceInstallationID(id), importID: importID, scriptSHA256: row["script_sha256"],
            metadata: decoded, revision: row["revision"], state: state,
            configuration: JSONDecoder().decode([SourceSettingValue].self, from: configuration),
            allowsCredentialRead: row["credential_read"], websiteSessionID: session,
            pendingCleanup: cleanup.map { try JSONDecoder().decode(SourceSessionCleanup.self, from: $0) })
    }

    private static let installationSelect = """
        SELECT i.*, r.script_sha256, s.metadata FROM source_installation i
        JOIN source_import r ON r.id=i.import_id JOIN source_script s ON s.sha256=r.script_sha256
        """

    static let sourceInstallationSchema = """
        CREATE TABLE source_installation (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL UNIQUE CHECK(length(source_id) > 0),
            import_id TEXT NOT NULL REFERENCES source_import(id),
            revision INTEGER NOT NULL CHECK(revision > 0 AND revision <= 9007199254740991),
            state TEXT NOT NULL CHECK(state IN ('enabled', 'disabled', 'removed')),
            configuration BLOB NOT NULL,
            credential_read INTEGER NOT NULL CHECK(credential_read IN (0, 1)),
            website_session TEXT NOT NULL,
            cleanup BLOB,
            CHECK(state != 'removed' OR credential_read = 0)
        );
        PRAGMA user_version = 4;
        """
}
