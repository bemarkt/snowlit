import Foundation

/// Owns the active library and coalesces finite startup attempts. The durable
/// descriptor prevents a missing dataset from being mistaken for first launch.
public actor LibraryBootstrap {
    public enum Failure: Error, Equatable, Sendable {
        case unsupportedDescriptor
    }

    private struct Descriptor: Codable {
        let formatVersion: Int
        let directory: String
    }

    private struct Opening {
        let id: UUID
        let task: Task<LibraryDatabase, any Error>
    }

    private let directory: URL?
    private var database: LibraryDatabase?
    private var opening: Opening?

    public init(directory: URL? = nil) { self.directory = directory }

    public func open() async throws -> LibraryDatabase {
        try Task.checkCancellation()
        if let database { return database }
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
        let result: LibraryDatabase
        do {
            result = try await operation.task.value
        } catch {
            if opening?.id == operation.id { opening = nil }
            throw error
        }
        if opening?.id == operation.id {
            database = result
            opening = nil
        }
        try Task.checkCancellation()
        return result
    }

    private static func openDataset(in suppliedDirectory: URL?) async throws -> LibraryDatabase {
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
        let dataset = root.appendingPathComponent("Library", isDirectory: true)
        let file = dataset.appendingPathComponent("library.sqlite")
        if manager.fileExists(atPath: descriptorURL.path) {
            let descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: descriptorURL))
            guard descriptor.formatVersion == 1, descriptor.directory == "Library" else {
                throw Failure.unsupportedDescriptor
            }
            return try LibraryDatabase(existingAt: file)
        }

        if !manager.fileExists(atPath: dataset.path) {
            // Only a completely initialized, closed database is adopted. Interrupted
            // candidates remain separate; they never replace an existing dataset.
            let staging = root.appendingPathComponent(".creating-library-\(UUID())", isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            let candidate = try LibraryDatabase.create(at: staging.appendingPathComponent("library.sqlite"))
            try await candidate.close()
            try manager.moveItem(at: staging, to: dataset)
        }
        // A crash after directory adoption but before descriptor write resumes by
        // opening that exact database. Corruption or a missing file fails visibly.
        let database = try LibraryDatabase(existingAt: file)
        do {
            let descriptor = Descriptor(formatVersion: 1, directory: "Library")
            try JSONEncoder().encode(descriptor).write(to: descriptorURL, options: .atomic)
        } catch let primary {
            do { try await database.close() }
            catch { throw BootstrapFailure(primary: primary, closing: error) }
            throw primary
        }
        return database
    }

    private struct BootstrapFailure: Error {
        let primary: any Error
        let closing: any Error
    }
}
