import Foundation
import GRDB

/// Version 1 is an uncompressed sequence of bounded, checksummed frames. Tables
/// and columns are defined here, never taken as SQL identifiers from the file.
/// Each frame: 8-byte big-endian length, 64 ASCII SHA256 bytes, JSON payload.
/// Checksums chain the previous checksum with this payload, including manifest.
/// There is no total-library allocation and no archive path to extract.
enum BackupArchiveFormat {
    static let magic = Data("SNOWBKP1".utf8)
    static let maximumFrameBytes = 64 * 1_024 * 1_024

    struct Manifest: Codable {
        let formatVersion: Int
        let dataVersion: Int
        let summary: LibraryBackupSummary
        let rowCounts: [Int]
    }

    struct Table: Sendable {
        let name: String
        let columns: [String]
        let types: [ValueType]
        let optional: Set<Int>

        init(_ name: String, _ columns: String, _ types: [ValueType], optional: Set<Int> = []) {
            self.name = name
            self.columns = columns.components(separatedBy: ",")
            self.types = types
            self.optional = optional
        }

        func validate(_ values: [Value]) throws {
            guard values.count == columns.count, types.count == columns.count else { throw LibraryBackupFailure.damagedArchive }
            for (index, value) in values.enumerated() {
                guard value.type == types[index] || (value.type == nil && optional.contains(index)) else {
                    throw LibraryBackupFailure.damagedArchive
                }
            }
        }
    }

    enum ValueType: Equatable, Sendable { case integer, real, text, blob }
    enum Value: Codable, Sendable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)

        init(_ value: DatabaseValue) {
            switch value.storage {
            case .null: self = .null
            case .int64(let value): self = .integer(value)
            case .double(let value): self = .real(value)
            case .string(let value): self = .text(value)
            case .blob(let value): self = .blob(value)
            }
        }

        var type: ValueType? {
            switch self {
            case .null: nil
            case .integer: .integer
            case .real: .real
            case .text: .text
            case .blob: .blob
            }
        }

        var databaseValue: DatabaseValue {
            switch self {
            case .null: .null
            case .integer(let value): value.databaseValue
            case .real(let value): value.databaseValue
            case .text(let value): value.databaseValue
            case .blob(let value): value.databaseValue
            }
        }
    }

    // Installation consent, session/cleanup IDs, request and write permits are
    // intentionally absent. Public state is separate from credential storage.
    static let tables: [Table] = [
        .init("source_script", "sha256,bytes,metadata", [.text, .blob, .blob]),
        .init("source_import", "id,script_sha256,inspection_contract_sha256,file_name,imported_at", [.text, .text, .text, .text, .real]),
        .init("source_installation", "id,source_id,import_id,revision,state,configuration", [.text, .text, .text, .integer, .text, .blob]),
        .init("library_book", "id,installation,reference_version,remote_key,title,author,catalog_revision,catalog_reference,reference_invalidation",
              [.text, .text, .integer, .text, .text, .text, .text, .blob, .text], optional: [5, 6, 7, 8]),
        .init("book_reference", "book_id,installation,reference_version,remote_key", [.text, .text, .integer, .text]),
        .init("chapter_reference", "book_id,installation,reference_version,book_key,chapter_key", [.text, .text, .integer, .text, .text]),
        .init("catalog_entry", "book_id,ordinal,remote_key,title", [.text, .integer, .text, .text]),
        .init("reading_checkpoint", "book_id,position", [.text, .blob], optional: [1]),
        .init("reading_activity", "book_id,ordinal", [.text, .integer]),
        .init("reader_preferences", "id,value", [.integer, .blob]),
        .init("source_public_state", "installation,state_version,revision,entries", [.text, .integer, .integer, .blob]),
        .init("source_reference_transition", "installation,revision,import_id,payload", [.text, .integer, .text, .blob]),
        .init("chapter_cache", "book_id,reference_version,book_key,chapter_key,revision,text_digest,byte_count,script_sha256,accessed,received",
              [.text, .integer, .text, .text, .text, .text, .integer, .text, .real, .integer])
    ]
}

final class BackupFrameWriter {
    private let file: FileHandle
    private let digest: LibraryBackup.Digest
    private var chain = String(repeating: "0", count: 64)

    init(file: FileHandle, digest: @escaping LibraryBackup.Digest) { self.file = file; self.digest = digest }

    func write<T: Encodable>(_ value: T) throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(value)
        guard data.count <= BackupArchiveFormat.maximumFrameBytes else { throw LibraryBackupFailure.recordTooLarge }
        chain = try digest(Data(chain.utf8) + data)
        guard chain.utf8.count == 64, chain.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw LibraryBackupFailure.damagedArchive
        }
        let length = UInt64(data.count)
        try file.write(contentsOf: Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) }))
        try file.write(contentsOf: Data(chain.utf8))
        try file.write(contentsOf: data)
    }
}

final class BackupFrameReader {
    private let file: FileHandle
    private let digest: LibraryBackup.Digest
    private var chain = String(repeating: "0", count: 64)

    init(file: FileHandle, digest: @escaping LibraryBackup.Digest) { self.file = file; self.digest = digest }

    func read<T: Decodable>(_ type: T.Type) throws -> T {
        try Task.checkCancellation()
        let bytes = try readExactly(8)
        let size = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard size > 0, size <= BackupArchiveFormat.maximumFrameBytes else { throw LibraryBackupFailure.recordTooLarge }
        let expected = try readExactly(64)
        let data = try readExactly(Int(size))
        chain = try digest(Data(chain.utf8) + data)
        guard expected == Data(chain.utf8) else { throw LibraryBackupFailure.damagedArchive }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw LibraryBackupFailure.damagedArchive }
    }

    func requireEnd() throws {
        guard try file.read(upToCount: 1)?.isEmpty != false else { throw LibraryBackupFailure.damagedArchive }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            try Task.checkCancellation()
            guard let part = try file.read(upToCount: min(count - data.count, 1_048_576)), !part.isEmpty else {
                throw LibraryBackupFailure.damagedArchive
            }
            data.append(part)
        }
        return data
    }
}
