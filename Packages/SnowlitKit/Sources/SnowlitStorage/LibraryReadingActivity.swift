import Foundation
import GRDB

extension LibraryDatabase {
    static func migrateReadingActivity(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE reading_activity (
                book_id TEXT PRIMARY KEY NOT NULL REFERENCES library_book(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL UNIQUE CHECK(typeof(ordinal)='integer' AND ordinal > 0)
            );
            PRAGMA user_version=10;
            """)
    }

    static func markRecentlyRead(_ db: Database, bookID: String) throws {
        let previous = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(ordinal), 0) FROM reading_activity") ?? 0
        guard previous < Int64.max else { throw Failure.invalidSequence }
        try db.execute(sql: """
            INSERT INTO reading_activity(book_id, ordinal) VALUES (?, ?)
            ON CONFLICT(book_id) DO UPDATE SET ordinal=excluded.ordinal
            """, arguments: [bookID, previous + 1])
    }
}
