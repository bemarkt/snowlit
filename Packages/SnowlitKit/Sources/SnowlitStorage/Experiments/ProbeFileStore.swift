import Foundation
import GRDB

/// One owner of one isolated directory. Exercises commit ordering; not a product cache/schema.
actor ProbeFileStore {
    typealias Digest = @Sendable (Data) throws -> String

    enum FaultPoint: String, CaseIterable, Sendable { case temporaryWritten, filePromoted, beforeCommit, afterCommit }
    enum Failure: Error, Equatable {
        case exists
        case missing
        case invalidStore
        case invalidFilename
        case checksum
        case injected(FaultPoint)
    }
    struct BackupFailure: Error {
        let primary: any Error
        let closing: any Error
    }
    private struct Record: Sendable {
        let key: String
        let filename: String
        let digest: String
        let count: Int
    }

    private let root: URL
    private let queue: DatabaseQueue
    private let digest: Digest
    private var files: URL { root.appendingPathComponent("objects", isDirectory: true) }
    private var temporary: URL { root.appendingPathComponent("staging", isDirectory: true) }

    init(root: URL, create: Bool, digest: @escaping Digest) throws {
        let manager = FileManager.default
        let database = root.appendingPathComponent("catalog.sqlite")
        if create {
            guard !manager.fileExists(atPath: root.path) else { throw Failure.exists }
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            for name in ["objects", "staging"] {
                try manager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
            }
        } else {
            guard manager.fileExists(atPath: database.path),
                  (try root.appendingPathComponent("objects").resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  (try root.appendingPathComponent("staging").resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            else { throw Failure.missing }
        }
        var configuration = Configuration()
        if create { configuration.journalMode = .wal }
        let queue = try DatabaseQueue(path: database.path, configuration: configuration)
        if create {
            try queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE object_ref (
                        logical_key TEXT PRIMARY KEY NOT NULL,
                        filename TEXT UNIQUE NOT NULL,
                        digest TEXT NOT NULL,
                        byte_count INTEGER NOT NULL CHECK(byte_count >= 0)
                    );
                    PRAGMA user_version=1;
                    """)
            }
        } else {
            try queue.read { db in
                guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 1,
                      try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else { throw Failure.invalidStore }
                _ = try Row.fetchAll(db, sql: "SELECT logical_key, filename, digest, byte_count FROM object_ref LIMIT 0")
            }
        }
        self.root = root
        self.queue = queue
        self.digest = digest
    }

    func save(key: String, data: Data, failAt fault: FaultPoint? = nil,
              checkpoint: @Sendable (FaultPoint) throws -> Void = { _ in }) throws {
        let identifier = UUID().uuidString
        let temporaryURL = temporary.appendingPathComponent(identifier + ".tmp")
        let filename = identifier + ".blob"
        let finalURL = files.appendingPathComponent(filename)
        let checksum = try digest(data)
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try checkpoint(.temporaryWritten)
        try fail(fault, at: .temporaryWritten)
        guard try digest(Data(contentsOf: temporaryURL)) == checksum else { throw Failure.checksum }
        // Both paths belong to the same store/volume. The final name is immutable and unique.
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        try checkpoint(.filePromoted)
        try fail(fault, at: .filePromoted)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO object_ref (logical_key, filename, digest, byte_count) VALUES (?, ?, ?, ?)
                ON CONFLICT(logical_key) DO UPDATE SET filename=excluded.filename,
                    digest=excluded.digest, byte_count=excluded.byte_count
                """, arguments: [key, filename, checksum, data.count])
            try checkpoint(.beforeCommit)
            try fail(fault, at: .beforeCommit)
        }
        try checkpoint(.afterCommit)
        try fail(fault, at: .afterCommit)
    }

    func load(key: String) throws -> Data {
        guard let record = try records().first(where: { $0.key == key }) else { throw Failure.missing }
        return try verifiedData(record, directory: files)
    }

    /// Validate all committed references before removing only generated, unreferenced files.
    /// The single owner must be quiescent; this is not cross-process cache coordination.
    func recoverOrphans() throws -> Int {
        let committed = try records()
        for record in committed { _ = try verifiedData(record, directory: files) }
        let referenced = Set(committed.map(\.filename))
        var removed = 0
        for (directory, suffix) in [(temporary, "tmp"), (files, "blob")] {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if Self.isGeneratedFilename(file.lastPathComponent, extension: suffix),
                   !referenced.contains(file.lastPathComponent) {
                    try FileManager.default.removeItem(at: file)
                    removed += 1
                }
            }
        }
        return removed
    }

    /// A synchronous actor operation freezes this store's writes while copying an SQLite
    /// snapshot and its immutable referenced files. Credentials and unrelated files are absent.
    func backup(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.exists }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let destinationFiles = destination.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: destinationFiles, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("staging"), withIntermediateDirectories: false)
        let backup = try DatabaseQueue(path: destination.appendingPathComponent("catalog.sqlite").path)
        do {
            try queue.backup(to: backup)
            let references = try Self.records(in: backup)
            for record in references {
                let data = try verifiedData(record, directory: files)
                let copy = destinationFiles.appendingPathComponent(record.filename)
                try data.write(to: copy, options: .withoutOverwriting)
                _ = try verifiedData(record, directory: destinationFiles)
            }
            try backup.close()
        } catch let primary {
            do { try backup.close() }
            catch { throw BackupFailure(primary: primary, closing: error) }
            throw primary
        }
    }

    func validate() throws {
        for record in try records() { _ = try verifiedData(record, directory: files) }
    }

    func close() throws { try queue.close() }

    private func verifiedData(_ record: Record, directory: URL) throws -> Data {
        guard Self.isGeneratedFilename(record.filename, extension: "blob") else { throw Failure.invalidFilename }
        let file = directory.appendingPathComponent(record.filename)
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw Failure.invalidFilename }
        let data = try Data(contentsOf: file)
        guard data.count == record.count, try digest(data) == record.digest else { throw Failure.checksum }
        return data
    }

    private func records() throws -> [Record] { try Self.records(in: queue) }

    private static func records(in queue: DatabaseQueue) throws -> [Record] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM object_ref ORDER BY logical_key").map {
                Record(key: $0["logical_key"], filename: $0["filename"], digest: $0["digest"], count: $0["byte_count"])
            }
        }
    }

    private static func isGeneratedFilename(_ name: String, extension suffix: String) -> Bool {
        let pieces = name.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 2 && pieces[1] == suffix && UUID(uuidString: String(pieces[0])) != nil
    }

    private func fail(_ requested: FaultPoint?, at point: FaultPoint) throws {
        if requested == point { throw Failure.injected(point) }
    }
}
