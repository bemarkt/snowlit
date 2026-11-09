import Foundation
import GRDB
import Testing
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import SnowlitStorage

struct ProbeFileStoreTests {
    @Test func hashAdapterMatchesThePublishedSHA256Vector() throws {
        #expect(try Self.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test(arguments: ProbeFileStore.FaultPoint.allCases)
    func reopeningAfterEachFaultPreservesOnlyCommittedContent(point: ProbeFileStore.FaultPoint) async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("store")
            let store = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            let old = Data("previous complete chapter".utf8)
            let replacement = Data("new complete chapter".utf8)
            try await store.save(key: "chapter", data: old)
            await #expect(throws: ProbeFileStore.Failure.injected(point)) {
                try await store.save(key: "chapter", data: replacement, failAt: point)
            }
            try await store.close()
            let reopened = try ProbeFileStore(root: root, create: false, digest: Self.sha256)
            #expect(try await reopened.load(key: "chapter") == (point == .afterCommit ? replacement : old))
            #expect(try await reopened.recoverOrphans() == 1)
            #expect(try await reopened.recoverOrphans() == 0)
            try await reopened.validate()
            try await reopened.close()
        }
    }

    @Test func backupRestoresOnlyReferencedFilesAndExcludesCredentialSentinels() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("store")
            let store = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            let content = Data("正文 👩🏽‍💻 e\u{301}".utf8)
            try await store.save(key: "chapter", data: content)
            let sentinel = Data("SYNTHETIC_CREDENTIAL_MUST_NOT_EXPORT".utf8)
            try sentinel.write(to: root.appendingPathComponent("website-session.txt"))
            try sentinel.write(to: root.appendingPathComponent("objects/\(UUID()).blob"))
            let backup = directory.appendingPathComponent("backup")
            try await store.backup(to: backup)
            let restored = try ProbeFileStore(root: backup, create: false, digest: Self.sha256)
            try await restored.validate()
            #expect(try await restored.load(key: "chapter") == content)
            let entries = try FileManager.default.contentsOfDirectory(atPath: backup.path)
            #expect(!entries.contains("website-session.txt"))
            let objects = try FileManager.default.contentsOfDirectory(at: backup.appendingPathComponent("objects"), includingPropertiesForKeys: nil)
            #expect(objects.count == 1)
            for file in objects { #expect(try Data(contentsOf: file).range(of: sentinel) == nil) }
            #expect(try Data(contentsOf: backup.appendingPathComponent("catalog.sqlite")).range(of: sentinel) == nil)
            #expect(try await store.load(key: "chapter") == content)
            try await restored.close()
            try await store.close()
        }
    }

    @Test func corruptedCandidateIsRejectedWhileTheOriginalRemainsUsable() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("store")
            let store = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            let content = Data("original".utf8)
            try await store.save(key: "chapter", data: content)
            let backup = directory.appendingPathComponent("candidate")
            try await store.backup(to: backup)
            let file = try #require(FileManager.default.contentsOfDirectory(at: backup.appendingPathComponent("objects"), includingPropertiesForKeys: nil).first)
            try Data("tampered".utf8).write(to: file) // Same length: checksum, not size, must catch this.
            let candidate = try ProbeFileStore(root: backup, create: false, digest: Self.sha256)
            await #expect(throws: ProbeFileStore.Failure.checksum) { try await candidate.validate() }
            await #expect(throws: ProbeFileStore.Failure.checksum) { try await candidate.recoverOrphans() }
            #expect(try await store.load(key: "chapter") == content)
            try await candidate.close()
            try await store.close()
        }
    }

    @Test func catalogPathTraversalIsRejectedBeforeFileAccess() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("store")
            let store = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            try await store.save(key: "chapter", data: Data("safe".utf8))
            try await store.close()
            let outside = directory.appendingPathComponent("outside")
            let marker = Data("outside marker".utf8)
            try marker.write(to: outside)
            let raw = try DatabaseQueue(path: root.appendingPathComponent("catalog.sqlite").path)
            try await raw.write { try $0.execute(sql: "UPDATE object_ref SET filename='../../outside'") }
            try raw.close()
            let reopened = try ProbeFileStore(root: root, create: false, digest: Self.sha256)
            await #expect(throws: ProbeFileStore.Failure.invalidFilename) { try await reopened.load(key: "chapter") }
            #expect(try Data(contentsOf: outside) == marker)
            try await reopened.close()
        }
    }

    static func sha256(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #elseif os(Windows)
        // Portable test adapter only. Node computes real SHA-256; it is never an App dependency.
        let executable = try #require(ProcessInfo.processInfo.environment["SNOWLIT_PROBE_NODE"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-e", "const c=require('node:crypto'),h=c.createHash('sha256');process.stdin.on('data',d=>h.update(d));process.stdin.on('end',()=>process.stdout.write(h.digest('hex')));"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let digest = try #require(String(data: result, encoding: .utf8))
        #expect(digest.count == 64)
        return digest
        #else
        throw ProbeFileStore.Failure.invalidStore
        #endif
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitFileProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove the isolated test directory") }
        }
        try await body(root)
    }
}
