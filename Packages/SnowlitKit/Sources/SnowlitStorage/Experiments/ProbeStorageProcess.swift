#if DEBUG
import Foundation

/// Entry point for an isolated simulator process experiment, absent from Release builds.
/// A checkpoint lets the external test stop the process without unwinding transactions.
@_spi(Experiments)
public enum ProbeStorageProcess {
    private static let original = Data("original committed chapter 🧪".utf8)
    private static let replacement = Data("replacement committed chapter 📖".utf8)

    public static func run(mode: String, root: URL, point: String,
                           digest: @escaping @Sendable (Data) throws -> String,
                           checkpoint: @escaping @Sendable (String) throws -> Void,
                           progress: @escaping @Sendable (String) throws -> Void = { _ in }) async throws -> [String: String] {
        if mode.hasPrefix("file-") {
            return try await file(mode: mode, root: root, point: point, digest: digest, checkpoint: checkpoint, progress: progress)
        }
        if mode.hasPrefix("dataset-") {
            return try await dataset(mode: mode, root: root, point: point, digest: digest, checkpoint: checkpoint, progress: progress)
        }
        throw ProbeFileStore.Failure.invalidStore
    }

    private static func file(mode: String, root: URL, point: String,
                             digest: @escaping ProbeFileStore.Digest,
                             checkpoint: @escaping @Sendable (String) throws -> Void,
                             progress: @Sendable (String) throws -> Void) async throws -> [String: String] {
        guard let fault = ProbeFileStore.FaultPoint(rawValue: point),
              ["file-seed", "file-write", "file-check", "file-recheck"].contains(mode) else {
            throw ProbeFileStore.Failure.invalidStore
        }
        try progress("opening-file-store")
        let store = try ProbeFileStore(root: root.appendingPathComponent("store"),
                                       create: mode == "file-seed", digest: digest)
        try progress("file-store-opened")
        var result: [String: String] = [:]
        switch mode {
        case "file-seed":
            try await store.save(key: "chapter", data: original)
        case "file-write":
            try await store.save(key: "chapter", data: replacement, checkpoint: { reached in
                if reached == fault { try checkpoint(reached.rawValue) }
            })
            // The supervisor must interrupt at the checkpoint; normal completion is a failure.
            throw ProbeFileStore.Failure.invalidStore
        default:
            let expected = fault == .afterCommit ? replacement : original
            let content = try await store.load(key: "chapter")
            guard content == expected else { throw ProbeFileStore.Failure.checksum }
            try await store.validate()
            let removed = try await store.recoverOrphans()
            guard removed == (mode == "file-check" ? 1 : 0),
                  try await store.recoverOrphans() == 0 else { throw ProbeFileStore.Failure.invalidStore }
            result = ["contentSHA256": try digest(content), "expected": fault == .afterCommit ? "replacement" : "original",
                      "removedOrphans": String(removed), "secondRecoveryRemoved": "0"]
        }
        try progress("closing-file-store")
        try await store.close()
        return result
    }

    private static func dataset(mode: String, root: URL, point: String,
                                digest: @escaping ProbeFileStore.Digest,
                                checkpoint: @escaping @Sendable (String) throws -> Void,
                                progress: @Sendable (String) throws -> Void) async throws -> [String: String] {
        guard let fault = ProbeDatasetStore.FaultPoint(rawValue: point),
              ["dataset-seed", "dataset-write", "dataset-check", "dataset-recheck"].contains(mode) else {
            throw ProbeDatasetStore.Failure.invalidPointer
        }
        let storeRoot = root.appendingPathComponent("store")
        let snapshotRoot = root.appendingPathComponent("snapshot")
        let originalIDFile = root.appendingPathComponent("original-id.txt")
        try progress("opening-dataset-store")
        let store = try ProbeDatasetStore(root: storeRoot, create: mode == "dataset-seed", digest: digest)
        try progress("dataset-store-opened")
        var result: [String: String] = [:]
        switch mode {
        case "dataset-seed":
            try await store.save(key: "chapter", data: original)
            let identifier = await store.datasetID
            try Data(identifier.uuidString.utf8).write(to: originalIDFile, options: .withoutOverwriting)
            let snapshot = try ProbeFileStore(root: snapshotRoot, create: true, digest: digest)
            try await snapshot.save(key: "chapter", data: replacement)
            try await snapshot.close()
        case "dataset-write":
            try await store.restore(from: snapshotRoot, checkpoint: { reached in
                if reached == fault { try checkpoint(reached.rawValue) }
            })
            throw ProbeDatasetStore.Failure.invalidPointer
        default:
            let committed = fault == .pointerCommitted || fault == .adopted
            try progress("loading-active-dataset")
            let content = try await store.load(key: "chapter")
            guard content == (committed ? replacement : original) else { throw ProbeFileStore.Failure.checksum }
            try await store.validate()
            let rawID = try String(contentsOf: originalIDFile, encoding: .utf8)
            guard let originalID = UUID(uuidString: rawID) else { throw ProbeDatasetStore.Failure.invalidPointer }
            let activeID = await store.datasetID
            guard (activeID != originalID) == committed else { throw ProbeDatasetStore.Failure.invalidPointer }
            try progress("opening-original-dataset")
            let previous = try ProbeFileStore(root: storeRoot.appendingPathComponent("datasets/\(originalID.uuidString)"),
                                              create: false, readOnly: true, digest: digest)
            guard try await previous.load(key: "chapter") == original else { throw ProbeFileStore.Failure.checksum }
            try await previous.validate()
            try progress("closing-original-dataset")
            try await previous.close()
            result = ["contentSHA256": try digest(content), "expected": committed ? "replacement" : "original",
                      "originalDataset": originalID.uuidString, "activeDataset": activeID.uuidString,
                      "originalContentSHA256": try digest(original)]
        }
        try progress("closing-dataset-store")
        try await store.close()
        return result
    }
}
#endif
