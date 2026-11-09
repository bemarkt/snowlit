import Foundation
import SnowlitStorage
import Testing

struct StorageBootstrapTests {
    @Test func repeatedPreparationPreservesExistingFiles() async throws {
        try await withTemporaryDirectory { root in
            let directory = root.appendingPathComponent("nested/Snowlit", isDirectory: true)
            let storage = StorageBootstrap(directory: directory)
            try await storage.prepare()
            let marker = directory.appendingPathComponent("existing-data")
            let content = Data("keep this data".utf8)
            try content.write(to: marker)

            try await storage.prepare()

            #expect(try Data(contentsOf: marker) == content)
        }
    }

    @Test func conflictingFileFailsWithoutReplacingIt() async throws {
        try await withTemporaryDirectory { root in
            let conflict = root.appendingPathComponent("Snowlit")
            let content = Data("existing file".utf8)
            try content.write(to: conflict)
            let storage = StorageBootstrap(directory: conflict)

            await #expect(throws: (any Error).self) {
                try await storage.prepare()
            }

            #expect(try Data(contentsOf: conflict) == content)
        }
    }

    @Test func preparationCanRetryAfterTheCauseIsResolved() async throws {
        try await withTemporaryDirectory { root in
            let directory = root.appendingPathComponent("Snowlit")
            try Data("conflict".utf8).write(to: directory)
            let storage = StorageBootstrap(directory: directory)
            await #expect(throws: (any Error).self) {
                try await storage.prepare()
            }

            // Only the test removes its own conflicting file, never the bootstrapper.
            try FileManager.default.removeItem(at: directory)
            try await storage.prepare()

            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            #expect(values.isDirectory == true)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnowlitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record(error, "Unable to remove the test's temporary directory")
            }
        }
        try await body(directory)
    }
}
