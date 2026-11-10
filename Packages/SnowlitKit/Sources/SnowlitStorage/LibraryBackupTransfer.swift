import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase {
    /// A write transaction is also the cache-file lease: independent writers and
    /// collectors cannot change the referenced bytes until the snapshot is done.
    /// Read-only connections can export metadata, but cannot lease cache files.
    public func exportBackup(to destination: URL, includeCache: Bool, digest: @escaping LibraryBackup.Digest) throws -> LibraryBackupSummary {
        try checkOpen(); try Task.checkCancellation()
        guard !includeCache || !readOnly else { throw LibraryBackupFailure.readOnlyCacheSnapshot }
        let source = chapterFiles.root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let target = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard target != source, !target.hasPrefix(source + "/"), !target.hasPrefix(source + "\\") else {
            throw LibraryBackupFailure.invalidPath
        }
        try BackupPaths.requireNew(destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".backup-\(UUID()).tmp")
        try Data().write(to: temporary, options: .withoutOverwriting)
        do {
            let summary = try BackupHandles.withFile(FileHandle(forWritingTo: temporary)) { handle in
                try handle.write(contentsOf: BackupArchiveFormat.magic)
                let writer = BackupFrameWriter(file: handle, digest: digest)
                let snapshot: (Database) throws -> LibraryBackupSummary = { db in
                    try Self.validateBackupData(db, digest: digest)
                    let counts = try BackupArchiveFormat.tables.map { table in
                        table.name == "chapter_cache" && !includeCache ? 0 : try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.name)") ?? 0
                    }
                    let summary = LibraryBackupSummary(createdAt: Date(), includesCache: includeCache,
                        sources: counts[2], books: counts[3], cachedChapters: counts[12])
                    try writer.write(BackupArchiveFormat.Manifest(formatVersion: 1, dataVersion: 1, summary: summary, rowCounts: counts))
                    for (table, count) in zip(BackupArchiveFormat.tables, counts) where count > 0 {
                        let columns = table.columns.joined(separator: ",") + (table.name == "chapter_cache" ? ",filename" : "")
                        let cursor = try Row.fetchCursor(db, sql: "SELECT \(columns) FROM \(table.name) ORDER BY rowid")
                        var written = 0
                        while let row = try cursor.next() {
                            try Task.checkCancellation()
                            var values = table.columns.map { BackupArchiveFormat.Value(row[$0] as DatabaseValue) }
                            try table.validate(values)
                            if table.name == "chapter_cache" {
                                let bytes = try self.chapterFiles.read(row["filename"], count: row["byte_count"], digest: row["revision"], using: digest)
                                try Self.validateBackupChapter(db, row: row, bytes: bytes, digest: digest)
                                values.append(.blob(bytes))
                            }
                            try writer.write(values)
                            written += 1
                        }
                        guard written == count else { throw LibraryBackupFailure.inconsistentLibrary }
                    }
                    return summary
                }
                let summary = try readOnly ? queue.read(snapshot) : queue.write(snapshot)
                try handle.synchronize()
                return summary
            }
            try Task.checkCancellation()
            // Publish only a completely written archive, without overwriting an
            // existing export or any active-library file.
            try FileManager.default.moveItem(at: temporary, to: destination)
            return summary
        } catch let primary {
            do { try FileManager.default.removeItem(at: temporary) }
            catch { throw BackupCleanupFailure(primary: primary, cleanup: error) }
            throw primary
        }
    }

    func readBackup(file: URL, digest: @escaping LibraryBackup.Digest) throws -> LibraryBackupSummary {
        try checkOpen(); try Task.checkCancellation()
        return try BackupHandles.withFile(FileHandle(forReadingFrom: file)) { handle in
            guard try handle.read(upToCount: 8) == BackupArchiveFormat.magic else { throw LibraryBackupFailure.unsupportedFormat }
            let reader = BackupFrameReader(file: handle, digest: digest)
            let manifest = try reader.read(BackupArchiveFormat.Manifest.self)
            guard manifest.formatVersion == 1, manifest.dataVersion == 1 else { throw LibraryBackupFailure.unsupportedFormat }
            let counts = manifest.rowCounts
            guard counts.count == BackupArchiveFormat.tables.count, counts.allSatisfy({ $0 >= 0 }),
                  manifest.summary.sources == counts[2], manifest.summary.books == counts[3], manifest.summary.cachedChapters == counts[12],
                  manifest.summary.includesCache || counts[12] == 0 else { throw LibraryBackupFailure.damagedArchive }
            try queue.write { db in
                for (table, count) in zip(BackupArchiveFormat.tables, counts) {
                    for _ in 0..<count {
                        var values = try reader.read([BackupArchiveFormat.Value].self)
                        var content: Data?
                        if table.name == "chapter_cache" {
                            guard case .blob(let bytes) = values.last else { throw LibraryBackupFailure.damagedArchive }
                            content = bytes
                            values.removeLast()
                        }
                        try table.validate(values)
                        var columns = table.columns
                        if table.name == "source_installation" {
                            columns += ["credential_read", "website_session", "cleanup"]
                            values += [.integer(0), .text(UUID().uuidString), .null]
                        } else if table.name == "reading_checkpoint" {
                            columns += ["session_id", "sequence"]
                            values += [.text(UUID().uuidString), .integer(0)]
                        } else if let content {
                            let fields: [String: (any DatabaseValueConvertible)?] = Dictionary(
                                uniqueKeysWithValues: zip(columns, values.map { $0.databaseValue as (any DatabaseValueConvertible)? }))
                            let row = Row(fields)
                            try Self.validateBackupChapter(db, row: row, bytes: content, digest: digest)
                            let name = try chapterFiles.store(content, expected: row["revision"], digest: digest)
                            columns += ["filename"]
                            values += [.text(name)]
                        }
                        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ",")
                        try db.execute(sql: "INSERT INTO \(table.name) (\(columns.joined(separator: ","))) VALUES (\(placeholders))",
                                       arguments: StatementArguments(values.map(\.databaseValue)))
                    }
                }
                try reader.requireEnd()
                try Self.validateBackupData(db, digest: digest)
                try Task.checkCancellation()
            }
            return manifest.summary
        }
    }

    static func validateBackupChapter(_ db: Database, row: Row, bytes: Data, digest: LibraryBackup.Digest) throws {
        let content = try JSONDecoder().decode(ChapterContent.self, from: bytes)
        let document = try ChapterDocument(content: content, digest: digest)
        let bookID: String = row["book_id"]
        guard let id = UUID(uuidString: bookID), bytes.count == row["byte_count"] as Int,
              document.revision == row["revision"] as String, document.textDigest == row["text_digest"] as String,
              content.chapter.book.referenceVersion == row["reference_version"] as Int,
              content.chapter.book.key == row["book_key"] as String, content.chapter.key == row["chapter_key"] as String,
              try savedChapterReferences(db, LocalBookID(id)).contains(content.chapter) else {
            throw LibraryBackupFailure.inconsistentLibrary
        }
        try SourceScriptSnapshot.validateDigest(row["script_sha256"])
    }
}
