import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase {
    public func updateSource(prepared: SourceUpdateSnapshot, migratedState: SourcePublicState?,
                             configuration: [SourceSettingValue], consent: SourceCredentialReadConsent) throws -> SourceInstallationSnapshot {
        try adoptSourceState(prepared, migratedState: migratedState, restoring: false, configuration: configuration, consent: consent)
    }

    public func restoreSource(confirmed prepared: SourceUpdateSnapshot, migratedState: SourcePublicState?,
                              configuration: [SourceSettingValue], consent: SourceCredentialReadConsent) throws -> SourceInstallationSnapshot {
        try adoptSourceState(prepared, migratedState: migratedState, restoring: true, configuration: configuration, consent: consent)
    }

    private func adoptSourceState(_ prepared: SourceUpdateSnapshot, migratedState: SourcePublicState?, restoring: Bool,
                                  configuration: [SourceSettingValue], consent: SourceCredentialReadConsent) throws -> SourceInstallationSnapshot {
        try SourceSettingValue.validate(configuration)
        return try changeSource(prepared.installation) { db, current in
            guard (current.state == .removed) == restoring else { throw SourceInstallationFailure.invalidState }
            let actual = try Self.sourceUpdateSnapshot(db, importID: prepared.candidate.id, expected: current)
            guard actual == prepared else { throw SourceUpdateFailure.staleInventory }
            guard actual.candidateMetadata.referenceVersion == current.metadata.referenceVersion else {
                throw SourceInstallationFailure.migrationRequired
            }
            let stateChanges = actual.candidateMetadata.stateVersion != current.metadata.stateVersion
            if stateChanges {
                guard let migratedState, migratedState.stateVersion == actual.candidateMetadata.stateVersion,
                      migratedState.revision == 0 else { throw SourceUpdateFailure.invalidMigration }
                guard actual.targetState.revision < 9_007_199_254_740_991 else { throw SourcePublicStateFailure.revisionExhausted }
                // Keep the old version intact. If the target version existed in
                // a prior installation revision, continue its counter to avoid ABA.
                let next = try SourcePublicState(stateVersion: migratedState.stateVersion,
                    revision: actual.targetState.revision + 1, entries: migratedState.entries)
                try db.execute(sql: """
                    INSERT INTO source_public_state (installation, state_version, revision, entries) VALUES (?, ?, ?, ?)
                    ON CONFLICT(installation, state_version) DO UPDATE SET revision=excluded.revision, entries=excluded.entries
                    """, arguments: [current.id.rawValue.uuidString, next.stateVersion, next.revision, try JSONEncoder().encode(next.entries)])
            } else {
                guard migratedState == nil else { throw SourceUpdateFailure.invalidMigration }
            }
            try db.execute(sql: """
                UPDATE source_installation SET import_id=?, configuration=?, credential_read=?, state=? WHERE id=?
                """, arguments: [actual.candidate.id.uuidString, try JSONEncoder().encode(configuration), Self.credentialRead(consent),
                                  restoring ? "enabled" : current.state.rawValue, current.id.rawValue.uuidString])
            // changeSource advances the installation and revokes state/catalog
            // write permissions before committing this same SQL transaction.
        }
    }
}
