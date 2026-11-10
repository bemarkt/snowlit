import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase {
    static func savedReferenceHistory(_ db: Database, _ installation: SourceInstallationID) throws -> [SourceReferenceTransition] {
        try Row.fetchAll(db, sql: "SELECT * FROM source_reference_transition WHERE installation=? ORDER BY revision",
                         arguments: [installation.rawValue.uuidString]).map { row in
            let payload: Data = row["payload"], revision: Int64 = row["revision"]
            let rawImport: String = row["import_id"]
            guard let importID = UUID(uuidString: rawImport) else { throw Failure.inconsistentData }
            let result = try JSONDecoder().decode(SourceReferenceTransition.self, from: payload)
            guard result.installationID == installation, result.installationRevision == revision,
                  try result.changes.targetVersion == importedMetadata(db, importID).referenceVersion else {
                throw Failure.inconsistentData
            }
            return result
        }
    }

    static func adoptReferenceChanges(_ db: Database, plan: SourceReferenceAdoption) throws {
        let owners = Dictionary(uniqueKeysWithValues: plan.inventory.books.map { ($0.reference, $0.localBookID) })
        // Establish ownership before registering chapter identities. Historical
        // destination collisions are also checked by the database constraints.
        for mapping in plan.changes.books {
            guard let owner = owners[mapping.original] else { throw SourceUpdateFailure.invalidInventory }
            if case .mapped(let reference) = mapping.outcome {
                try recordBookReference(db, bookID: owner, reference: reference)
            }
            for chapter in mapping.chapters {
                if case .mapped(let reference) = chapter.outcome {
                    try recordChapterReference(db, bookID: owner, reference: reference)
                }
            }
        }
        for item in plan.prepared.books {
            let binding = try plan.binding(for: item.book)
            try db.execute(sql: """
                UPDATE library_book SET reference_version=?, remote_key=?, reference_invalidation=? WHERE id=?
                """, arguments: [binding.reference.referenceVersion, binding.reference.key,
                    binding.invalidation?.rawValue, item.book.id.rawValue.uuidString])
        }
        let installation = plan.prepared.installation
        guard installation.revision < 9_007_199_254_740_991 else { throw SourceInstallationFailure.revisionExhausted }
        let transition = try SourceReferenceTransition(installationID: installation.id,
            installationRevision: Int64(installation.revision) + 1, changes: plan.changes)
        try db.execute(sql: """
            INSERT INTO source_reference_transition (installation, revision, import_id, payload) VALUES (?, ?, ?, ?)
            """, arguments: [installation.id.rawValue.uuidString, transition.installationRevision,
                plan.prepared.candidate.id.uuidString, try JSONEncoder().encode(transition)])
    }

    static func migrateSourceReferenceHistory(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE library_book ADD COLUMN reference_invalidation TEXT
                CHECK(reference_invalidation IN ('removed', 'unavailable', 'changedIdentity'));
            CREATE TABLE source_reference_transition (
                installation TEXT NOT NULL REFERENCES source_installation(id),
                revision INTEGER NOT NULL CHECK(revision > 0 AND revision <= 9007199254740991),
                import_id TEXT NOT NULL REFERENCES source_import(id),
                payload BLOB NOT NULL,
                PRIMARY KEY(installation, revision)
            );
            """)
        for (name, definition) in inventoryTriggers(for: ["source_reference_transition"]) {
            try db.execute(sql: "CREATE TRIGGER \(name) \(definition)")
        }
        try db.execute(sql: "PRAGMA user_version=8;")
    }

    static func validateSourceReferenceHistorySchema(_ db: Database) throws {
        _ = try Row.fetchAll(db, sql: "SELECT installation, revision, import_id, payload FROM source_reference_transition LIMIT 0")
        _ = try Row.fetchAll(db, sql: "SELECT reference_invalidation FROM library_book LIMIT 0")
        for (name, _) in inventoryTriggers(for: ["source_reference_transition"]) {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='trigger' AND name=?)",
                                   arguments: [name]) == true else { throw Failure.inconsistentData }
        }
    }
}
