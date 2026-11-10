import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase {
    /// SQL constraints cover structural ownership; decoding and the domain
    /// snapshots also check the relationships contained inside JSON values.
    static func validateBackupData(_ db: Database, digest: LibraryBackup.Digest) throws {
        guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw LibraryBackupFailure.inconsistentLibrary }
        let scripts = try Row.fetchCursor(db, sql: "SELECT * FROM source_script")
        while let row = try scripts.next() {
            try Task.checkCancellation()
            let bytes: Data = row["metadata"]
            let script = try SourceScriptSnapshot(bytes: row["bytes"], metadata: JSONDecoder().decode(SourceScriptMetadata.self, from: bytes), digest: digest)
            guard script.sha256 == row["sha256"] as String else { throw LibraryBackupFailure.inconsistentLibrary }
        }
        let imports = try Row.fetchCursor(db, sql: "SELECT * FROM source_import")
        while let row = try imports.next() { _ = try decodeSourceImport(row) }
        let installations = try String.fetchAll(db, sql: "SELECT id FROM source_installation")
        for raw in installations {
            guard let uuid = UUID(uuidString: raw) else { throw LibraryBackupFailure.inconsistentLibrary }
            let id = SourceInstallationID(uuid)
            let installed = try installation(db, id)
            let history = try savedReferenceHistory(db, id)
            _ = try SourceReferenceHistory(history)
            guard history.allSatisfy({ $0.installationRevision <= installed.revision }),
                  history.last.map({ $0.changes.targetVersion == installed.metadata.referenceVersion }) ?? true else {
                throw LibraryBackupFailure.inconsistentLibrary
            }
            for transition in history {
                for mapping in transition.changes.books {
                    guard let owner = try String.fetchOne(db, sql: "SELECT book_id FROM book_reference WHERE installation=? AND reference_version=? AND remote_key=?",
                        arguments: [raw, mapping.original.referenceVersion, mapping.original.key]), let ownerID = UUID(uuidString: owner) else {
                        throw LibraryBackupFailure.inconsistentLibrary
                    }
                    let bookID = LocalBookID(ownerID)
                    if case .mapped(let reference) = mapping.outcome, try !ownsReference(db, bookID: bookID, reference: reference) {
                        throw LibraryBackupFailure.inconsistentLibrary
                    }
                    let known = Set(try savedChapterReferences(db, bookID))
                    for chapter in mapping.chapters {
                        guard known.contains(chapter.original) else { throw LibraryBackupFailure.inconsistentLibrary }
                        if case .mapped(let reference) = chapter.outcome, !known.contains(reference) {
                            throw LibraryBackupFailure.inconsistentLibrary
                        }
                    }
                }
            }
        }
        let books = try Row.fetchCursor(db, sql: "SELECT * FROM library_book")
        while let row = try books.next() {
            try Task.checkCancellation()
            let book = try decodeBook(row)
            let references = try Row.fetchAll(db, sql: "SELECT * FROM book_reference WHERE book_id=?", arguments: [book.id.rawValue.uuidString]).map { row in
                let raw: String = row["installation"]
                guard let uuid = UUID(uuidString: raw) else { throw LibraryBackupFailure.inconsistentLibrary }
                return try SourceBookReference(installationID: .init(uuid), referenceVersion: row["reference_version"], key: row["remote_key"])
            }
            let catalog = try savedCatalog(db, book.id)
            let ordinals = try Int.fetchAll(db, sql: "SELECT ordinal FROM catalog_entry WHERE book_id=? ORDER BY ordinal", arguments: [book.id.rawValue.uuidString])
            guard ordinals.elementsEqual(0..<ordinals.count), catalog != nil || ordinals.isEmpty else {
                throw LibraryBackupFailure.inconsistentLibrary
            }
            _ = try SourceUpdateBookSnapshot(book: book, references: references,
                chapterReferences: savedChapterReferences(db, book.id), catalog: catalog, checkpoint: savedCheckpoint(db, book.id))
        }
        for bytes in try Data.fetchAll(db, sql: "SELECT value FROM reader_preferences") {
            _ = try JSONDecoder().decode(ReaderPreferences.self, from: bytes)
        }
        let states = try Row.fetchCursor(db, sql: "SELECT * FROM source_public_state")
        while let row = try states.next() {
            let raw: String = row["installation"]
            guard let uuid = UUID(uuidString: raw) else { throw LibraryBackupFailure.inconsistentLibrary }
            _ = try publicState(db, installationID: .init(uuid), version: row["state_version"])
        }
    }
}
