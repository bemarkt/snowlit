import Foundation
import GRDB
import Dispatch
import Synchronization
import Testing
@testable import SnowlitStorage

struct ProbeDatasetStoreTests {
    @Test func restoreBlocksNewOperationsUntilTheValidatedDatasetIsAdopted() async throws {
        try await withDirectory { directory in
            let incoming = Data("incoming dataset".utf8)
            let snapshot = directory.appendingPathComponent("snapshot")
            try await makeSnapshot(at: snapshot, data: incoming)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let didBlock = Mutex(false)
            let store = try ProbeDatasetStore(root: directory.appendingPathComponent("active"), create: true) { data in
                let block = data == incoming && didBlock.withLock { blocked in
                    if blocked { return false }
                    blocked = true
                    return true
                }
                if block {
                    entered.signal()
                    guard release.wait(timeout: .now() + 5) == .success else {
                        throw ProbeDatasetStore.Failure.busy
                    }
                }
                return try ProbeFileStoreTests.sha256(data)
            }
            try await store.save(key: "chapter", data: Data("old".utf8))
            let restoring = Task { try await store.restore(from: snapshot) }
            do {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(3))
                while entered.wait(timeout: .now()) != .success {
                    guard clock.now < deadline else { throw ProbeDatasetStore.Failure.busy }
                    try await Task.sleep(for: .milliseconds(10))
                }
                await #expect(throws: ProbeDatasetStore.Failure.busy) { try await store.load(key: "chapter") }
                await #expect(throws: ProbeDatasetStore.Failure.busy) {
                    try await store.save(key: "late", data: Data("must not write".utf8))
                }
                release.signal()
                try await restoring.value
            } catch {
                release.signal()
                // Settle the owned task before removing its directory; keep both errors observable.
                do { try await restoring.value } catch { Issue.record(error, "Restore failed during cleanup") }
                throw error
            }
            #expect(try await store.load(key: "chapter") == incoming)
            await #expect(throws: ProbeFileStore.Failure.missing) { try await store.load(key: "late") }
            try await store.close()
        }
    }

    @Test(arguments: ProbeDatasetStore.FaultPoint.allCases)
    func reopeningEachSwitchBoundarySelectsOneCompleteDatasetAndRetainsTheOldOne(point: ProbeDatasetStore.FaultPoint) async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("active")
            let store = try ProbeDatasetStore(root: root, create: true, digest: ProbeFileStoreTests.sha256)
            let old = Data("old dataset".utf8)
            let new = Data("new dataset".utf8)
            try await store.save(key: "chapter", data: old)
            let oldID = await store.datasetID
            let snapshot = directory.appendingPathComponent("snapshot")
            try await makeSnapshot(at: snapshot, data: new)
            await #expect(throws: ProbeDatasetStore.Failure.injected(point)) {
                try await store.restore(from: snapshot, failAt: point)
            }
            let expected = [.pointerCommitted, .adopted].contains(point) ? new : old
            #expect(try await store.load(key: "chapter") == expected)
            try await store.close()
            let reopened = try ProbeDatasetStore(root: root, create: false, digest: ProbeFileStoreTests.sha256)
            try await reopened.validate()
            #expect(try await reopened.load(key: "chapter") == expected)
            let retained = try ProbeFileStore(root: root.appendingPathComponent("datasets/\(oldID.uuidString)"),
                                             create: false, readOnly: true, digest: ProbeFileStoreTests.sha256)
            #expect(try await retained.load(key: "chapter") == old)
            try await retained.close()
            try await reopened.close()
        }
    }

    @Test func damagedSnapshotCannotChangeTheActivePointerOrData() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("active")
            let store = try ProbeDatasetStore(root: root, create: true, digest: ProbeFileStoreTests.sha256)
            let old = Data("keep".utf8)
            try await store.save(key: "chapter", data: old)
            let pointer = await store.datasetID
            let snapshot = directory.appendingPathComponent("snapshot")
            try await makeSnapshot(at: snapshot, data: Data("good".utf8))
            let file = try #require(FileManager.default.contentsOfDirectory(at: snapshot.appendingPathComponent("objects"), includingPropertiesForKeys: nil).first)
            try Data("evil".utf8).write(to: file)
            await #expect(throws: ProbeFileStore.Failure.checksum) { try await store.restore(from: snapshot) }
            #expect(await store.datasetID == pointer)
            #expect(try await store.load(key: "chapter") == old)
            try await store.save(key: "next", data: Data("writable".utf8))
            try await store.close()
        }
    }

    @Test func successfulRestoreSelectsValidatedDataAndLeavesUnrelatedFilesOut() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("active")
            let store = try ProbeDatasetStore(root: root, create: true, digest: ProbeFileStoreTests.sha256)
            try await store.save(key: "chapter", data: Data("old".utf8))
            let snapshot = directory.appendingPathComponent("snapshot")
            try await makeSnapshot(at: snapshot, data: Data("restored".utf8))
            try Data("SYNTHETIC_SECRET".utf8).write(to: snapshot.appendingPathComponent("website-session"))
            try await store.restore(from: snapshot)
            #expect(try await store.load(key: "chapter") == Data("restored".utf8))
            let current = await store.datasetID
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("datasets/\(current.uuidString)/website-session").path))
            try await store.close()
        }
    }

    @Test func unknownActivePointerVersionDoesNotCreateAnotherDataset() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("active")
            let store = try ProbeDatasetStore(root: root, create: true, digest: ProbeFileStoreTests.sha256)
            try await store.save(key: "chapter", data: Data("keep".utf8))
            try await store.close()
            let catalog = try DatabaseQueue(path: root.appendingPathComponent("active.sqlite").path)
            try await catalog.write { try $0.execute(sql: "PRAGMA user_version=999") }
            try catalog.close()
            let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("datasets").path)
            #expect(throws: ProbeDatasetStore.Failure.invalidPointer) {
                try ProbeDatasetStore(root: root, create: false, digest: ProbeFileStoreTests.sha256)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("datasets").path) == before)
        }
    }

    private func makeSnapshot(at url: URL, data: Data) async throws {
        let source = try ProbeFileStore(root: url, create: true, digest: ProbeFileStoreTests.sha256)
        try await source.save(key: "chapter", data: data)
        try await source.close()
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitDatasetProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove the isolated test directory") }
        }
        try await body(root)
    }
}
