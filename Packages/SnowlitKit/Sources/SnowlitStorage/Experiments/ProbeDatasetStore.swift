import Foundation
import GRDB

/// Exclusive-owner dataset switch experiment. Old datasets are retained for recovery.
/// No merge policy, credential import, production schema, or durability budget is implied.
actor ProbeDatasetStore {
    enum FaultPoint: String, CaseIterable, Sendable {
        case candidateValidated, oldClosed, pointerCommitted, adopted
    }
    enum Failure: Error, Equatable { case exists, invalidPointer, busy, closed, injected(FaultPoint) }
    struct RecoveryFailure: Error {
        let primary: any Error
        let recovery: any Error
    }
    private let root: URL
    private let digest: ProbeFileStore.Digest
    private let catalog: DatabaseQueue
    private var active: ProbeFileStore
    private(set) var datasetID: UUID
    private var operations = 0
    private var switching = false
    private var closed = false

    init(root: URL, create: Bool, digest: @escaping ProbeFileStore.Digest) throws {
        self.root = root
        self.digest = digest
        let manager = FileManager.default
        if create {
            guard !manager.fileExists(atPath: root.path) else { throw Failure.exists }
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            try manager.createDirectory(at: root.appendingPathComponent("datasets"), withIntermediateDirectories: false)
            let id = UUID()
            datasetID = id
            active = try ProbeFileStore(root: Self.datasetURL(root, id), create: true, digest: digest)
            let catalog = try DatabaseQueue(path: root.appendingPathComponent("active.sqlite").path)
            try catalog.write { db in
                try db.execute(sql: "CREATE TABLE active (singleton INTEGER PRIMARY KEY CHECK(singleton=1), dataset TEXT NOT NULL); PRAGMA user_version=1;")
                try db.execute(sql: "INSERT INTO active VALUES (1, ?)", arguments: [id.uuidString])
            }
            self.catalog = catalog
        } else {
            let path = root.appendingPathComponent("active.sqlite")
            guard manager.fileExists(atPath: path.path) else { throw Failure.invalidPointer }
            let catalog = try DatabaseQueue(path: path.path)
            let id = try catalog.read { db in
                guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 1,
                      let raw = try String.fetchOne(db, sql: "SELECT dataset FROM active WHERE singleton=1"),
                      let id = UUID(uuidString: raw) else { throw Failure.invalidPointer }
                return id
            }
            self.catalog = catalog
            datasetID = id
            active = try ProbeFileStore(root: Self.datasetURL(root, id), create: false, digest: digest)
        }
    }

    func save(key: String, data: Data) async throws {
        try beginOperation()
        defer { operations -= 1 }
        try await active.save(key: key, data: data)
    }

    func load(key: String) async throws -> Data {
        try beginOperation()
        defer { operations -= 1 }
        return try await active.load(key: key)
    }

    func validate() async throws {
        try beginOperation()
        defer { operations -= 1 }
        try await active.validate()
    }

    /// Refuses to start while operations are in flight. Actor reentrancy cannot admit
    /// new reads/writes during validation or switch; callers receive an explicit busy error.
    func restore(from snapshot: URL, failAt fault: FaultPoint? = nil,
                 checkpoint: @Sendable (FaultPoint) throws -> Void = { _ in }) async throws {
        guard !closed else { throw Failure.closed }
        guard !switching, operations == 0 else { throw Failure.busy }
        switching = true
        defer { switching = false }
        let previousID = datasetID
        let nextID = UUID()
        let nextURL = Self.datasetURL(root, nextID)
        var previousClosed = false
        var committed = false
        var candidate: ProbeFileStore?
        do {
            let source = try ProbeFileStore(root: snapshot, create: false, readOnly: true, digest: digest)
            do {
                try await source.validate()
                try await source.backup(to: nextURL)
                try await source.close()
            } catch let primary {
                do { try await source.close() }
                catch { throw RecoveryFailure(primary: primary, recovery: error) }
                throw primary
            }
            let prepared = try ProbeFileStore(root: nextURL, create: false, digest: digest)
            candidate = prepared
            try await prepared.validate()
            try Self.reach(.candidateValidated, fault: fault, checkpoint: checkpoint)
            try await active.close()
            previousClosed = true
            try Self.reach(.oldClosed, fault: fault, checkpoint: checkpoint)
            // The catalog transaction is the switch's commit point. The old directory
            // is never removed. Device power-loss/fsync behavior still needs evidence.
            try commitPointer(from: previousID, to: nextID)
            committed = true
            try Self.reach(.pointerCommitted, fault: fault, checkpoint: checkpoint)
            active = prepared
            datasetID = nextID
            try Self.reach(.adopted, fault: fault, checkpoint: checkpoint)
        } catch let primary {
            if committed, let candidate {
                // A lost acknowledgement after commit is not a partial dataset: adopt
                // the same validated dataset a restart selects and retain the old one.
                active = candidate
                datasetID = nextID
            } else {
                do {
                    if previousClosed {
                        active = try ProbeFileStore(root: Self.datasetURL(root, previousID), create: false, digest: digest)
                    }
                    if let candidate { try await candidate.close() }
                } catch {
                    closed = true
                    throw RecoveryFailure(primary: primary, recovery: error)
                }
            }
            throw primary
        }
    }

    func close() async throws {
        guard !switching, operations == 0 else { throw Failure.busy }
        closed = true
        try await active.close()
        try catalog.close()
    }

    private func beginOperation() throws {
        guard !closed else { throw Failure.closed }
        guard !switching else { throw Failure.busy }
        operations += 1
    }

    /// Synchronous transaction on GRDB's writer queue. No actor suspension can separate
    /// a successful commit from updating the in-memory committed flag in restore().
    private func commitPointer(from previous: UUID, to next: UUID) throws {
        try catalog.write { db in
            try db.execute(sql: "UPDATE active SET dataset=? WHERE singleton=1 AND dataset=?",
                           arguments: [next.uuidString, previous.uuidString])
            guard db.changesCount == 1 else { throw Failure.invalidPointer }
        }
    }

    private static func datasetURL(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent("datasets", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func reach(_ point: FaultPoint, fault: FaultPoint?,
                              checkpoint: @Sendable (FaultPoint) throws -> Void) throws {
        try checkpoint(point)
        if point == fault { throw Failure.injected(point) }
    }
}
