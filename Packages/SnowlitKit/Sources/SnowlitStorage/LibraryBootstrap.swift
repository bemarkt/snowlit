import Foundation

/// Owns the active library and coalesces finite startup attempts. The durable
/// descriptor prevents a missing dataset from being mistaken for first launch.
public actor LibraryBootstrap {
    public enum Failure: Error, Equatable, Sendable {
        case unsupportedDescriptor
        case restoreBusy
        case invalidRestoreCandidate
        case rollbackFailed
    }

    /// Test-only injection points for the restore switch. A process crash at
    /// any of these points must leave either the old or the new dataset openable.
    enum RestoreFault: String, CaseIterable, Sendable {
        case candidateCopied
        case oldClosed
        case descriptorCommitted
        case adopted
    }

    private struct Descriptor: Codable, Equatable {
        let formatVersion: Int
        let directory: String
        static let legacy = Descriptor(formatVersion: 1, directory: "Library")
    }

    private struct OpenedDataset: Sendable {
        let database: LibraryDatabase
        let descriptor: Descriptor
        let root: URL
    }

    private struct Opening {
        let id: UUID
        let task: Task<OpenedDataset, any Error>
    }

    private let directory: URL?
    private var database: LibraryDatabase?
    private var opening: Opening?
    private var descriptor: Descriptor?
    private var rootURL: URL?
    private var restoring = false

    public init(directory: URL? = nil) { self.directory = directory }

    public func open() async throws -> LibraryDatabase {
        try Task.checkCancellation()
        if let database { return database }
        if restoring { throw Failure.restoreBusy }
        let operation: Opening
        if let opening {
            operation = opening
        } else {
            let directory = directory
            // The bootstrap owns this bounded initialization task. Cancelling one
            // UI waiter must not interrupt creation needed by another waiter.
            operation = Opening(id: UUID(), task: Task { try await Self.openDataset(in: directory) })
            opening = operation
        }
        let result: OpenedDataset
        do {
            result = try await operation.task.value
        } catch {
            if opening?.id == operation.id { opening = nil }
            throw error
        }
        if opening?.id == operation.id {
            database = result.database
            descriptor = result.descriptor
            rootURL = result.root
            opening = nil
        }
        try Task.checkCancellation()
        return result.database
    }

    /// Replaces the active dataset with a closed, validated backup candidate.
    /// The descriptor write is the commit point. The previous dataset directory
    /// is never removed, so a failed open can fall back to it.
    public func restore(_ prepared: PreparedLibraryBackup) async throws -> LibraryBackupSummary {
        _ = try await open()
        try Task.checkCancellation()
        return try await restore(prepared, fault: nil, checkpoint: { _ in })
    }

    func restore(_ prepared: PreparedLibraryBackup, fault: RestoreFault?,
                 checkpoint: @Sendable (RestoreFault) throws -> Void) async throws -> LibraryBackupSummary {
        try Task.checkCancellation()
        guard !restoring else { throw Failure.restoreBusy }
        guard let current = database, let root = rootURL, let previousDescriptor = descriptor else {
            throw Failure.restoreBusy
        }
        restoring = true
        defer { restoring = false }
        try BackupPaths.require(prepared.directory, type: .typeDirectory)
        try BackupPaths.require(prepared.databaseURL, type: .typeRegular)
        let manager = FileManager()
        let datasets = root.appendingPathComponent("Datasets", isDirectory: true)
        if manager.fileExists(atPath: datasets.path) {
            try BackupPaths.require(datasets, type: .typeDirectory)
        } else {
            try manager.createDirectory(at: datasets, withIntermediateDirectories: false)
        }
        let nextID = UUID()
        let destination = datasets.appendingPathComponent(nextID.uuidString, isDirectory: true)
        guard !manager.fileExists(atPath: destination.path) else { throw Failure.invalidRestoreCandidate }
        let staging = root.appendingPathComponent(".restore-\(UUID())", isDirectory: true)
        let previousURL = try Self.datasetURL(root: root, descriptor: previousDescriptor)
        var staged = false
        var committed = false
        do {
            try manager.copyItem(at: prepared.directory, to: staging)
            staged = true
            let check = try LibraryDatabase(existingAt: staging.appendingPathComponent("library.sqlite"), readOnly: true)
            try await check.close()
            try manager.moveItem(at: staging, to: destination)
            staged = false
            try Self.reach(.candidateCopied, fault: fault, checkpoint: checkpoint)
            try Task.checkCancellation()
            // From here the old writer must be closed before the pointer moves.
            database = nil
            try await current.close()
            try Self.reach(.oldClosed, fault: fault, checkpoint: checkpoint)
            try Task.checkCancellation()
            let nextDescriptor = Descriptor(formatVersion: 2, directory: "Datasets/\(nextID.uuidString)")
            try Self.writeDescriptor(nextDescriptor, to: root)
            descriptor = nextDescriptor
            committed = true
            try Self.reach(.descriptorCommitted, fault: fault, checkpoint: checkpoint)
            database = try LibraryDatabase(existingAt: destination.appendingPathComponent("library.sqlite"))
            try Self.reach(.adopted, fault: fault, checkpoint: checkpoint)
            return prepared.summary
        } catch let primary {
            do {
                if committed {
                    if database == nil {
                        do {
                            database = try LibraryDatabase(existingAt: destination.appendingPathComponent("library.sqlite"))
                        } catch {
                            // The candidate validated but cannot be reopened after the
                            // pointer moved. Put the retained previous dataset back.
                            try Self.writeDescriptor(previousDescriptor, to: root)
                            descriptor = previousDescriptor
                            database = try LibraryDatabase(existingAt: previousURL.appendingPathComponent("library.sqlite"))
                        }
                    }
                } else {
                    if staged { try? manager.removeItem(at: staging) }
                    if database == nil {
                        database = try LibraryDatabase(existingAt: previousURL.appendingPathComponent("library.sqlite"))
                    }
                }
            } catch {
                throw Failure.rollbackFailed
            }
            throw primary
        }
    }

    private static func openDataset(in suppliedDirectory: URL?) async throws -> OpenedDataset {
        let manager = FileManager()
        let root: URL
        if let suppliedDirectory {
            root = suppliedDirectory
        } else {
            root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
                .appendingPathComponent("Snowlit", isDirectory: true)
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptorURL = root.appendingPathComponent("library.json")
        if manager.fileExists(atPath: descriptorURL.path) {
            let descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: descriptorURL))
            let dataset = try datasetURL(root: root, descriptor: descriptor)
            let database = try LibraryDatabase(existingAt: dataset.appendingPathComponent("library.sqlite"))
            return .init(database: database, descriptor: descriptor, root: root)
        }

        let legacy = root.appendingPathComponent("Library", isDirectory: true)
        let file = legacy.appendingPathComponent("library.sqlite")
        if !manager.fileExists(atPath: legacy.path) {
            // Only a completely initialized, closed database is adopted. Interrupted
            // candidates remain separate; they never replace an existing dataset.
            let staging = root.appendingPathComponent(".creating-library-\(UUID())", isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            let candidate = try LibraryDatabase.create(at: staging.appendingPathComponent("library.sqlite"))
            try await candidate.close()
            try manager.moveItem(at: staging, to: legacy)
        }
        // A crash after directory adoption but before descriptor write resumes by
        // opening that exact database. Corruption or a missing file fails visibly.
        let database = try LibraryDatabase(existingAt: file)
        do {
            try writeDescriptor(.legacy, to: root)
        } catch let primary {
            do { try await database.close() }
            catch { throw BootstrapFailure(primary: primary, closing: error) }
            throw primary
        }
        return .init(database: database, descriptor: .legacy, root: root)
    }

    private static func datasetURL(root: URL, descriptor: Descriptor) throws -> URL {
        let dataset: URL
        switch descriptor.formatVersion {
        case 1:
            guard descriptor.directory == "Library" else { throw Failure.unsupportedDescriptor }
            dataset = root.appendingPathComponent("Library", isDirectory: true)
        case 2:
            let parts = descriptor.directory.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "Datasets",
                  let id = UUID(uuidString: String(parts[1])) else { throw Failure.unsupportedDescriptor }
            dataset = root.appendingPathComponent("Datasets", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
        default:
            throw Failure.unsupportedDescriptor
        }
        let resolvedRoot = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        guard dataset.standardizedFileURL.path.hasPrefix(resolvedRoot) else { throw Failure.unsupportedDescriptor }
        return dataset
    }

    private static func writeDescriptor(_ descriptor: Descriptor, to root: URL) throws {
        try JSONEncoder().encode(descriptor).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }

    private static func reach(_ point: RestoreFault, fault: RestoreFault?,
                              checkpoint: @Sendable (RestoreFault) throws -> Void) throws {
        try checkpoint(point)
        if point == fault { throw RestoreInjected(point: point) }
    }

    private struct RestoreInjected: Error {
        let point: RestoreFault
    }

    private struct BootstrapFailure: Error {
        let primary: any Error
        let closing: any Error
    }
}
