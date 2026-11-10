import Foundation
import SnowlitCore

public enum LibraryBackupFailure: Error, Equatable, Sendable {
    case unsupportedFormat
    case damagedArchive
    case recordTooLarge
    case invalidPath
    case destinationExists
    case readOnlyCacheSnapshot
    case inconsistentLibrary
}

public struct LibraryBackupSummary: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let includesCache: Bool
    public let sources: Int
    public let books: Int
    public let cachedChapters: Int

    public init(createdAt: Date, includesCache: Bool, sources: Int, books: Int, cachedChapters: Int) {
        self.createdAt = createdAt; self.includesCache = includesCache
        self.sources = sources; self.books = books; self.cachedChapters = cachedChapters
    }
}

/// A closed, validated candidate. It is not the active dataset and cannot be
/// adopted by opening an arbitrary path from an archive.
public struct PreparedLibraryBackup: Sendable {
    public let directory: URL
    public let summary: LibraryBackupSummary
    public var databaseURL: URL { directory.appendingPathComponent("library.sqlite") }
}

public enum LibraryBackup {
    public typealias Digest = @Sendable (Data) throws -> String

    /// Rebuilds only the allowlisted data in a new schema owned by this App.
    /// No SQL, file paths, permissions or website sessions come from the archive.
    public static func preflight(file: URL, into directory: URL, digest: @escaping Digest) async throws -> PreparedLibraryBackup {
        try Task.checkCancellation()
        try BackupPaths.require(file, type: .typeRegular)
        try BackupPaths.requireNew(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var candidate: LibraryDatabase?
        do {
            let database = try LibraryDatabase.create(at: directory.appendingPathComponent("library.sqlite"))
            candidate = database
            let summary = try await database.readBackup(file: file, digest: digest)
            try Task.checkCancellation()
            try await database.close()
            candidate = nil
            // Exercise the same strict opener used on launch, after WAL closure.
            let reopened = try LibraryDatabase(existingAt: directory.appendingPathComponent("library.sqlite"), readOnly: true)
            candidate = reopened
            try await reopened.close()
            candidate = nil
            return .init(directory: directory, summary: summary)
        } catch let primary {
            if let candidate {
                do { try await candidate.close() }
                catch { throw BackupCleanupFailure(primary: primary, cleanup: error) }
            }
            do { try FileManager.default.removeItem(at: directory) }
            catch { throw BackupCleanupFailure(primary: primary, cleanup: error) }
            throw primary
        }
    }
}

struct BackupCleanupFailure: Error {
    let primary: any Error
    let cleanup: any Error
}

enum BackupPaths {
    static func requireNew(_ url: URL) throws {
        guard url.isFileURL else { throw LibraryBackupFailure.invalidPath }
        try require(url.deletingLastPathComponent(), type: .typeDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw LibraryBackupFailure.destinationExists }
        // Also catches a dangling link, which fileExists does not recognize.
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            throw LibraryBackupFailure.destinationExists
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return
        }
    }

    static func require(_ url: URL, type: FileAttributeType) throws {
        guard url.isFileURL else { throw LibraryBackupFailure.invalidPath }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let expected = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        guard attrs[.type] as? FileAttributeType == type,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              url.resolvingSymlinksInPath().standardizedFileURL.path == expected else {
            throw LibraryBackupFailure.invalidPath
        }
    }
}

enum BackupHandles {
    static func withFile<T>(_ handle: FileHandle, _ body: (FileHandle) throws -> T) throws -> T {
        let value: T
        do { value = try body(handle) }
        catch let primary {
            do { try handle.close() }
            catch { throw BackupCleanupFailure(primary: primary, cleanup: error) }
            throw primary
        }
        try handle.close()
        return value
    }
}
