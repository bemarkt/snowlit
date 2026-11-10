import Foundation
import GRDB
import Testing
#if canImport(CryptoKit)
import CryptoKit
#elseif os(Windows)
import WinSDK
#endif
@testable import SnowlitStorage

struct ProbeFileStoreTests {
    #if os(iOS)
    @Test(arguments: ["staging", "objects"])
    func filesystemPermissionFailurePreservesCommittedContentAndCanRecover(folder: String) async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("store")
            let store = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            let original = Data("original committed chapter".utf8)
            let replacement = Data("replacement after permissions recover".utf8)
            try await store.save(key: "chapter", data: original)
            let objects = root.appendingPathComponent("objects")
            let before = try fileSnapshot(objects)
            let restricted = root.appendingPathComponent(folder)
            let attributes = try FileManager.default.attributesOfItem(atPath: restricted.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            defer {
                do { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: restricted.path) }
                catch { Issue.record(error, "Unable to restore the isolated directory permissions") }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: restricted.path)
            do {
                try await store.save(key: "chapter", data: replacement)
                Issue.record("Writing through the restricted directory unexpectedly succeeded")
            } catch {
                let failure = error as NSError
                #expect(failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileWriteNoPermission.rawValue)
            }
            #expect(try await store.load(key: "chapter") == original)
            #expect(try fileSnapshot(objects) == before)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: restricted.path)
            #expect(try await store.recoverOrphans() == (folder == "objects" ? 1 : 0))
            #expect(try await store.recoverOrphans() == 0)
            try await store.save(key: "chapter", data: replacement)
            try await store.close()
            let reopened = try ProbeFileStore(root: root, create: false, digest: Self.sha256)
            #expect(try await reopened.load(key: "chapter") == replacement)
            try await reopened.validate()
            try await reopened.close()
        }
    }
    #endif

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

    @Test func readOnlySaveLeavesEveryCandidateFileUnchanged() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("candidate")
            let writer = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            let content = Data("original candidate".utf8)
            try await writer.save(key: "chapter", data: content)
            try await writer.close()
            let candidate = try ProbeFileStore(root: root, create: false, readOnly: true, digest: Self.sha256)
            let before = try fileSnapshot(root)
            await #expect(throws: ProbeFileStore.Failure.readOnly) {
                try await candidate.save(key: "chapter", data: Data("rejected update".utf8))
            }
            #expect(try fileSnapshot(root) == before)
            #expect(try await candidate.load(key: "chapter") == content)
            try await candidate.close()
        }
    }

    @Test func readOnlyRecoveryLeavesOrphansUnchangedAndCanExport() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("candidate")
            let writer = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            let content = Data("original candidate".utf8)
            try await writer.save(key: "chapter", data: content)
            try await writer.close()
            try Data("unfinished".utf8).write(to: root.appendingPathComponent("staging/\(UUID()).tmp"))
            try Data("unreferenced".utf8).write(to: root.appendingPathComponent("objects/\(UUID()).blob"))
            let candidate = try ProbeFileStore(root: root, create: false, readOnly: true, digest: Self.sha256)
            let before = try fileSnapshot(root)
            await #expect(throws: ProbeFileStore.Failure.readOnly) { try await candidate.recoverOrphans() }
            #expect(try fileSnapshot(root) == before)
            try await candidate.validate()
            let exported = directory.appendingPathComponent("exported")
            try await candidate.backup(to: exported)
            #expect(try fileSnapshot(root) == before)
            let restored = try ProbeFileStore(root: exported, create: false, digest: Self.sha256)
            #expect(try await restored.load(key: "chapter") == content)
            #expect(try await restored.recoverOrphans() == 0)
            try await restored.close()
            try await candidate.close()
        }
    }

    @Test func closedStoreRejectsOperationsBeforeCreatingFiles() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("store")
            let store = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            try await store.save(key: "chapter", data: Data("original".utf8))
            try await store.close()
            let before = try fileSnapshot(root)
            await #expect(throws: ProbeFileStore.Failure.closed) {
                try await store.save(key: "chapter", data: Data("rejected update".utf8))
            }
            #expect(try fileSnapshot(root) == before)
            let destination = directory.appendingPathComponent("exported")
            await #expect(throws: ProbeFileStore.Failure.closed) { try await store.backup(to: destination) }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            await #expect(throws: ProbeFileStore.Failure.closed) { try await store.load(key: "chapter") }
            await #expect(throws: ProbeFileStore.Failure.closed) { try await store.validate() }
            await #expect(throws: ProbeFileStore.Failure.closed) { try await store.recoverOrphans() }
            try await store.close()
        }
    }

    @Test(arguments: ["objects", "staging"])
    func orphanRecoveryRejectsDirectoriesBeforeRemovingAnyFiles(folder: String) async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("store")
            let store = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            let content = Data("committed content".utf8)
            try await store.save(key: "chapter", data: content)
            try Data("ordinary orphan".utf8).write(to: root.appendingPathComponent("objects/\(UUID()).blob"))
            try Data("unfinished".utf8).write(to: root.appendingPathComponent("staging/\(UUID()).tmp"))
            let suffix = folder == "objects" ? "blob" : "tmp"
            let disguised = root.appendingPathComponent("\(folder)/\(UUID()).\(suffix)")
            try FileManager.default.createDirectory(at: disguised, withIntermediateDirectories: false)
            try Data("must not recursively delete".utf8).write(to: disguised.appendingPathComponent("sentinel.txt"))
            let before = try fileSnapshot(root)
            await #expect(throws: ProbeFileStore.Failure.invalidFilename) { try await store.recoverOrphans() }
            let after = try fileSnapshot(root)
            let changedFiles = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
            #expect(Set(before.keys) == Set(after.keys))
            // Reading references can advance SQLite WAL reader marks in shared memory.
            // All paths and every persistent file's bytes must remain unchanged.
            #expect(changedFiles.allSatisfy { $0 == "catalog.sqlite-shm" })
            #expect(try await store.load(key: "chapter") == content)
            try await store.close()
        }
    }

    @Test(arguments: ["root", "objects", "staging"])
    func openingStoreRejectsRedirectedDirectories(component: String) async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("store")
            let store = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            try await store.save(key: "chapter", data: Data("committed content".utf8))
            try await store.close()
            let original = component == "root" ? root : root.appendingPathComponent(component)
            let detached = directory.appendingPathComponent("detached")
            try FileManager.default.moveItem(at: original, to: detached)
            try makeDirectoryLink(at: original, to: detached)
            defer { removeTestLink(original) }
            let before = try fileSnapshot(detached)
            await #expect(throws: ProbeFileStore.Failure.invalidStore) {
                let candidate = try ProbeFileStore(root: root, create: false, readOnly: true, digest: Self.sha256)
                try await candidate.close()
            }
            #expect(try fileSnapshot(detached) == before)
        }
    }

    @Test func readonlyBackupCannotBeWrittenInsideItsSource() async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("candidate")
            let writer = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            try await writer.save(key: "chapter", data: Data("original".utf8))
            try await writer.close()
            let store = try ProbeFileStore(root: root, create: false, readOnly: true, digest: Self.sha256)
            let alias = directory.appendingPathComponent("alias")
            try makeDirectoryLink(at: alias, to: root.appendingPathComponent("objects"))
            defer { removeTestLink(alias) }
            let before = try fileSnapshot(root)
            var destinations = [root.appendingPathComponent("nested-backup"), alias.appendingPathComponent("redirected-backup")]
            let caseAlias = URL(fileURLWithPath: root.path.uppercased())
            if FileManager.default.fileExists(atPath: caseAlias.path) {
                destinations.append(caseAlias.appendingPathComponent("case-backup"))
            }
            for destination in destinations {
                await #expect(throws: ProbeFileStore.Failure.invalidStore) { try await store.backup(to: destination) }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                #expect(try fileSnapshot(root) == before)
            }
            try await store.close()
        }
    }

    @Test(arguments: ["objects", "staging"])
    func redirectedDirectoriesAreRejectedAgainBeforeEveryOperation(folder: String) async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("store")
            let store = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            try await store.save(key: "chapter", data: Data("committed content".utf8))
            let original = root.appendingPathComponent(folder)
            let detached = directory.appendingPathComponent("detached")
            try FileManager.default.moveItem(at: original, to: detached)
            try makeDirectoryLink(at: original, to: detached)
            defer { removeTestLink(original) }
            let before = try fileSnapshot(detached)
            await #expect(throws: ProbeFileStore.Failure.invalidStore) { try await store.load(key: "chapter") }
            await #expect(throws: ProbeFileStore.Failure.invalidStore) { try await store.validate() }
            await #expect(throws: ProbeFileStore.Failure.invalidStore) { try await store.save(key: "chapter", data: Data("rejected".utf8)) }
            await #expect(throws: ProbeFileStore.Failure.invalidStore) { try await store.recoverOrphans() }
            let destination = directory.appendingPathComponent("backup")
            await #expect(throws: ProbeFileStore.Failure.invalidStore) { try await store.backup(to: destination) }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try fileSnapshot(detached) == before)
            try await store.close()
        }
    }

    @Test(arguments: ["catalog.sqlite-wal", "catalog.sqlite-shm", "catalog.sqlite-journal"])
    func nonFileDatabaseSidecarsAreRejectedBeforeOpening(name: String) async throws {
        try await withDirectory { directory in
            let root = directory.appendingPathComponent("store")
            let writer = try ProbeFileStore(root: root, create: true, digest: Self.sha256)
            try await writer.save(key: "chapter", data: Data("committed content".utf8))
            try await writer.close()
            let sidecar = root.appendingPathComponent(name)
            let retained = directory.appendingPathComponent("retained-\(name)")
            let hadSidecar = FileManager.default.fileExists(atPath: sidecar.path)
            // Closing SQLite need not remove WAL/SHM. Preserve the closed fixture's
            // files while substituting a directory to exercise pre-open validation.
            if hadSidecar {
                try #require(sidecar.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
                try FileManager.default.moveItem(at: sidecar, to: retained)
            }
            try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
            try Data("must remain unchanged".utf8).write(to: sidecar.appendingPathComponent("sentinel.txt"))
            let before = try fileSnapshot(root)
            await #expect(throws: ProbeFileStore.Failure.invalidStore) {
                let candidate = try ProbeFileStore(root: root, create: false, readOnly: true, digest: Self.sha256)
                try await candidate.close()
            }
            #expect(try fileSnapshot(root) == before)
            try FileManager.default.moveItem(at: sidecar, to: directory.appendingPathComponent("rejected-\(name)"))
            if hadSidecar { try FileManager.default.moveItem(at: retained, to: sidecar) }
            let reopened = try ProbeFileStore(root: root, create: false, readOnly: true, digest: Self.sha256)
            #expect(try await reopened.load(key: "chapter") == Data("committed content".utf8))
            try await reopened.close()
        }
    }

    private func makeDirectoryLink(at link: URL, to target: URL) throws {
        #if os(Windows)
        // Junctions need no symlink privilege. Do not inherit the concurrently
        // running storage tests' file handles into this short-lived helper.
        let executable = try #require(ProcessInfo.processInfo.environment["SNOWLIT_PROBE_POWERSHELL"])
        let quotedLink = link.path.replacingOccurrences(of: "'", with: "''")
        let quotedTarget = target.path.replacingOccurrences(of: "'", with: "''")
        let script = "New-Item -ItemType Junction -Path '\(quotedLink)' -Value '\(quotedTarget)' -ErrorAction Stop | Out-Null"
        let encoded = try #require(script.data(using: .utf16LittleEndian)).base64EncodedString()
        let application = Array(executable.utf16) + [0]
        var command = Array("\"\(executable)\" -NoProfile -NonInteractive -EncodedCommand \(encoded)".utf16) + [0]
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var process = PROCESS_INFORMATION()
        let created = application.withUnsafeBufferPointer { app in
            command.withUnsafeMutableBufferPointer { command in
                CreateProcessW(app.baseAddress, command.baseAddress, nil, nil, false, DWORD(CREATE_NO_WINDOW), nil, nil, &startup, &process)
            }
        }
        try #require(created)
        defer { _ = CloseHandle(process.hThread); _ = CloseHandle(process.hProcess) }
        let waited = WaitForSingleObject(process.hProcess, 30_000)
        if waited == DWORD(WAIT_TIMEOUT) {
            _ = TerminateProcess(process.hProcess, 1)
        }
        try #require(waited == DWORD(WAIT_OBJECT_0))
        var status: DWORD = 1
        try #require(GetExitCodeProcess(process.hProcess, &status))
        try #require(status == 0)
        #else
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #endif
    }

    private func removeTestLink(_ link: URL) {
        do { try FileManager.default.removeItem(at: link) }
        catch { Issue.record(error, "Unable to remove the isolated test link") }
    }

    private func fileSnapshot(_ root: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                for (name, data) in try fileSnapshot(entry) {
                    snapshot[entry.lastPathComponent + "/" + name] = data
                }
            } else {
                snapshot[entry.lastPathComponent] = try Data(contentsOf: entry)
            }
        }
        return snapshot
    }

    static func sha256(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #elseif os(Windows)
        // Avoid child-process handle inheritance during parallel file operations.
        var provider: BCRYPT_ALG_HANDLE?
        let algorithm = Array("SHA256".utf16) + [0]
        let opened = algorithm.withUnsafeBufferPointer { BCryptOpenAlgorithmProvider(&provider, $0.baseAddress, nil, 0) }
        try #require(opened == 0)
        defer { _ = BCryptCloseAlgorithmProvider(provider, 0) }
        var input = Array(data)
        var output = [UInt8](repeating: 0, count: 32)
        let status = input.withUnsafeMutableBufferPointer {
            BCryptHash(provider, nil, 0, $0.baseAddress, ULONG($0.count), &output, 32)
        }
        try #require(status == 0)
        return output.map { String(format: "%02x", $0) }.joined()
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
