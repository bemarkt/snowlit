import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase {
    public typealias ChapterDigest = @Sendable (Data) throws -> String

    public func beginChapterUpdate(bookID: LocalBookID, chapter: ChapterReference) throws -> ChapterWriteToken {
        try checkOpen(); try Task.checkCancellation()
        guard !readOnly else { throw ChapterAccessFailure.readOnly }
        return try queue.write { db in
            let book = try Self.decodeBook(Self.bookRow(db, bookID))
            guard try Self.savedChapterReferences(db, bookID).contains(chapter) else { throw ChapterAccessFailure.unavailableReference }
            let history = try SourceReferenceHistory(Self.savedReferenceHistory(db, chapter.book.installationID))
            let resolved = history.resolve(chapter)
            guard resolved.invalidation == nil, resolved.reference.book == book.networkReference else {
                throw ChapterAccessFailure.unavailableReference
            }
            let installed = try Self.installation(db, chapter.book.installationID)
            guard installed.canExecute, resolved.reference.book.referenceVersion == installed.metadata.referenceVersion else {
                throw ChapterAccessFailure.unavailableReference
            }
            let token = ChapterWriteToken(id: UUID(), bookID: bookID, requested: chapter,
                resolved: resolved.reference, installation: installed)
            try db.execute(sql: """
                INSERT INTO chapter_request (book_id, reference_version, book_key, chapter_key, request_id)
                VALUES (?, ?, ?, ?, ?) ON CONFLICT(book_id, reference_version, book_key, chapter_key)
                DO UPDATE SET request_id=excluded.request_id
                """, arguments: Self.requestArguments(token) + [token.id.uuidString])
            return token
        }
    }

    public func revokeChapterUpdate(_ token: ChapterWriteToken) throws {
        try checkOpen()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM chapter_request WHERE book_id=? AND reference_version=? AND book_key=? AND chapter_key=? AND request_id=?",
                arguments: Self.requestArguments(token) + [token.id.uuidString])
        }
    }

    /// Immutable bytes are promoted before their SQL reference. A failed commit
    /// leaves only an unreferenced file, collected by the next cache maintenance.
    public func publishChapter(_ document: ChapterDocument, using token: ChapterWriteToken,
                               digest: ChapterDigest) throws {
        try checkOpen(); try Task.checkCancellation()
        guard !readOnly else { throw ChapterAccessFailure.readOnly }
        guard document.content.chapter == token.resolved else { throw ChapterContentError.differentDocument }
        let bytes = try document.content.canonicalBytes()
        let verified = try ChapterDocument(content: document.content, digest: digest)
        guard verified == document else { throw ChapterAccessFailure.cacheCorrupt }
        try queue.write { db in
            guard try Self.installation(db, token.installation.id) == token.installation,
                  token.installation.canExecute,
                  try String.fetchOne(db, sql: "SELECT request_id FROM chapter_request WHERE book_id=? AND reference_version=? AND book_key=? AND chapter_key=?",
                    arguments: Self.requestArguments(token)) == token.id.uuidString else { throw ChapterAccessFailure.stale }
            try Task.checkCancellation()
            try Self.recordChapterReference(db, bookID: token.bookID, reference: document.content.chapter)
            let filename = try chapterFiles.store(bytes, expected: document.revision, digest: digest)
            try Task.checkCancellation()
            let previous = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(received), 0) FROM chapter_cache") ?? 0
            guard previous < Int64.max else { throw LibraryDatabase.Failure.invalidSequence }
            try db.execute(sql: """
                INSERT INTO chapter_cache (book_id, reference_version, book_key, chapter_key, revision, text_digest, filename, byte_count, script_sha256, accessed, received)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(book_id, reference_version, book_key, chapter_key, revision)
                DO UPDATE SET filename=excluded.filename, byte_count=excluded.byte_count, accessed=excluded.accessed, script_sha256=excluded.script_sha256, received=excluded.received
                """, arguments: [token.bookID.rawValue.uuidString, token.resolved.book.referenceVersion,
                    token.resolved.book.key, token.resolved.key, document.revision, document.textDigest,
                    filename, bytes.count, token.installation.scriptSHA256, Date().timeIntervalSince1970, previous + 1])
            try db.execute(sql: "DELETE FROM chapter_request WHERE request_id=?", arguments: [token.id.uuidString])
            try Task.checkCancellation()
        }
    }

    /// Offline lookup only reads local identity/history and bytes. An exact
    /// checkpoint revision never resolves to a different document or chapter.
    public func cachedChapter(bookID: LocalBookID, chapter: ChapterReference, revision: String? = nil,
                              digest: ChapterDigest) throws -> ChapterDocument? {
        try checkOpen(); try Task.checkCancellation()
        let read: (Database) throws -> ChapterDocument? = { db in
            guard try Self.ownsReference(db, bookID: bookID, reference: chapter.book) else { throw LibraryModelError.differentBook }
            var references = [chapter]
            if revision == nil {
                let history = try SourceReferenceHistory(Self.savedReferenceHistory(db, chapter.book.installationID))
                let resolved = history.resolve(chapter).reference
                if resolved != chapter { references.insert(resolved, at: 0) }
            }
            for reference in references {
                let args: StatementArguments = [bookID.rawValue.uuidString, reference.book.referenceVersion, reference.book.key, reference.key]
                let suffix = revision == nil ? " ORDER BY received DESC LIMIT 1" : " AND revision=? LIMIT 1"
                guard let row = try Row.fetchOne(db, sql: "SELECT rowid AS cache_id, * FROM chapter_cache WHERE book_id=? AND reference_version=? AND book_key=? AND chapter_key=?" + suffix,
                    arguments: args + (revision.map { [$0] } ?? [])) else { continue }
                let expected: String = row["revision"], textDigest: String = row["text_digest"]
                let bytes = try self.chapterFiles.read(row["filename"], count: row["byte_count"], digest: expected, using: digest)
                let content: ChapterContent
                do { content = try JSONDecoder().decode(ChapterContent.self, from: bytes) }
                catch { throw ChapterAccessFailure.cacheCorrupt }
                let document = try ChapterDocument(content: content, digest: digest)
                guard content.chapter == reference, document.revision == expected, document.textDigest == textDigest else {
                    throw ChapterAccessFailure.cacheCorrupt
                }
                if !self.readOnly {
                    try db.execute(sql: "UPDATE chapter_cache SET accessed=? WHERE rowid=?", arguments: [Date().timeIntervalSince1970, row["cache_id"] as Int64])
                }
                return document
            }
            return nil
        }
        // Writable cache reads update usage under the same writer lock as file
        // collection. Read-only access changes no files or metadata. A concurrent
        // writer may evict its file after the SQL lookup, reported as cacheMissing;
        // a WAL read transaction alone is not a snapshot of the cache directory.
        return try readOnly ? queue.read(read) : queue.write(read)
    }

    public func chapterCacheUsage() throws -> ChapterCacheUsage {
        try checkOpen()
        return try queue.read { db in
            .init(documents: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter_cache") ?? 0,
                bytes: try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count), 0) FROM chapter_cache") ?? 0)
        }
    }

    /// Evicts least-recently-read documents; book identities, catalogs and
    /// checkpoints remain. A zero limit explicitly clears all cached documents.
    public func trimChapterCache(toByteLimit limit: Int64) throws -> ChapterCacheUsage {
        try checkOpen(); try Task.checkCancellation()
        guard !readOnly else { throw ChapterAccessFailure.readOnly }
        guard limit >= 0 else { throw ChapterAccessFailure.invalidLimit }
        try queue.write { db in
            var total = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count), 0) FROM chapter_cache") ?? 0
            for row in try Row.fetchAll(db, sql: "SELECT rowid, byte_count FROM chapter_cache ORDER BY accessed, rowid") {
                guard total > limit else { break }
                try db.execute(sql: "DELETE FROM chapter_cache WHERE rowid=?", arguments: [row["rowid"] as Int64])
                total -= row["byte_count"] as Int64
            }
        }
        // File removal follows the committed metadata change. If deletion fails,
        // the next maintenance retries the unreferenced files.
        _ = try collectChapterCacheFiles()
        return try chapterCacheUsage()
    }

    @discardableResult
    public func collectChapterCacheFiles() throws -> Int {
        try checkOpen()
        guard !readOnly else { throw ChapterAccessFailure.readOnly }
        return try queue.write { db in
            let files = try String.fetchAll(db, sql: "SELECT filename FROM chapter_cache")
            return try chapterFiles.collect(except: Set(files))
        }
    }

    private static func requestArguments(_ token: ChapterWriteToken) -> StatementArguments {
        [token.bookID.rawValue.uuidString, token.resolved.book.referenceVersion, token.resolved.book.key, token.resolved.key]
    }

    static func migrateChapterCache(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE chapter_request (
                book_id TEXT NOT NULL REFERENCES library_book(id) ON DELETE CASCADE,
                reference_version INTEGER NOT NULL, book_key TEXT NOT NULL, chapter_key TEXT NOT NULL,
                request_id TEXT NOT NULL UNIQUE,
                PRIMARY KEY(book_id, reference_version, book_key, chapter_key)
            );
            CREATE TABLE chapter_cache (
                book_id TEXT NOT NULL REFERENCES library_book(id) ON DELETE CASCADE,
                reference_version INTEGER NOT NULL, book_key TEXT NOT NULL, chapter_key TEXT NOT NULL,
                revision TEXT NOT NULL, text_digest TEXT NOT NULL, filename TEXT NOT NULL UNIQUE,
                byte_count INTEGER NOT NULL CHECK(byte_count > 0), script_sha256 TEXT NOT NULL, accessed REAL NOT NULL,
                received INTEGER NOT NULL CHECK(typeof(received)='integer' AND received > 0),
                UNIQUE(book_id, reference_version, book_key, chapter_key, revision)
            );
            PRAGMA user_version=9;
            """)
    }

    static func validateChapterCacheSchema(_ db: Database) throws {
        _ = try Row.fetchAll(db, sql: "SELECT book_id, reference_version, book_key, chapter_key, request_id FROM chapter_request LIMIT 0")
        _ = try Row.fetchAll(db, sql: "SELECT book_id, reference_version, book_key, chapter_key, revision, text_digest, filename, byte_count, script_sha256, accessed, received FROM chapter_cache LIMIT 0")
    }
}
