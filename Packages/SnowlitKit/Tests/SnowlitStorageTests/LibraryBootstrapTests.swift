import Foundation
import SnowlitCore
import Testing
@testable import SnowlitStorage

struct LibraryBootstrapTests {
    @Test func concurrentStartupOpensOneLibraryAndSavedDataSurvivesRestart() async throws {
        try await withDirectory { root in
            let bootstrap = LibraryBootstrap(directory: root)
            async let first = bootstrap.open()
            async let second = bootstrap.open()
            let (a, b) = try await (first, second)
            #expect(a === b)
            let reference = try SourceBookReference(installationID: SourceInstallationID(), referenceVersion: 1, key: "book")
            let book = try await a.addBook(reference: reference, title: "saved", author: nil)
            try await a.close()
            let reopened = try await LibraryBootstrap(directory: root).open()
            #expect(try await reopened.books() == [book])
            try await reopened.close()
        }
    }

    @Test func missingPreviouslyInitializedDatabaseNeverCreatesAReplacement() async throws {
        try await withDirectory { root in
            let database = try await LibraryBootstrap(directory: root).open()
            try await database.close()
            let dataset = root.appendingPathComponent("Library")
            let preserved = root.appendingPathComponent("preserved-library")
            try FileManager.default.moveItem(at: dataset, to: preserved)
            await #expect(throws: LibraryDatabase.Failure.missingDatabase) {
                try await LibraryBootstrap(directory: root).open()
            }
            #expect(!FileManager.default.fileExists(atPath: dataset.path))
            #expect(FileManager.default.fileExists(atPath: preserved.appendingPathComponent("library.sqlite").path))
        }
    }

    @Test func interruptedDescriptorPublicationReopensTheAdoptedLibrary() async throws {
        try await withDirectory { root in
            let dataset = root.appendingPathComponent("Library")
            try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: false)
            let database = try LibraryDatabase.create(at: dataset.appendingPathComponent("library.sqlite"))
            let preferences = try ReaderPreferences(fontSize: 23, theme: .dark)
            try await database.savePreferences(preferences)
            try await database.close()
            let recovered = try await LibraryBootstrap(directory: root).open()
            #expect(try await recovered.preferences() == preferences)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
            try await recovered.close()
        }
    }

    @Test func unknownDescriptorAndCorruptAdoptedDatabaseAreNotReset() async throws {
        try await withDirectory { root in
            let descriptor = root.appendingPathComponent("library.json")
            let unknown = Data(#"{"formatVersion":999,"directory":"Library"}"#.utf8)
            try unknown.write(to: descriptor)
            await #expect(throws: LibraryBootstrap.Failure.unsupportedDescriptor) {
                try await LibraryBootstrap(directory: root).open()
            }
            #expect(try Data(contentsOf: descriptor) == unknown)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
        }
        try await withDirectory { root in
            let dataset = root.appendingPathComponent("Library")
            try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: false)
            let path = dataset.appendingPathComponent("library.sqlite")
            let corrupt = Data("do not replace a corrupt dataset".utf8)
            try corrupt.write(to: path)
            await #expect(throws: (any Error).self) { try await LibraryBootstrap(directory: root).open() }
            #expect(try Data(contentsOf: path) == corrupt)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
        }
    }

    @Test func startupCanRetryAfterTheDirectoryConflictIsRepaired() async throws {
        try await withDirectory { root in
            let conflict = root.appendingPathComponent("app-support")
            let preserved = root.appendingPathComponent("preserved-conflict")
            try Data("original file".utf8).write(to: conflict)
            let bootstrap = LibraryBootstrap(directory: conflict)
            await #expect(throws: (any Error).self) { try await bootstrap.open() }
            try FileManager.default.moveItem(at: conflict, to: preserved)
            let database = try await bootstrap.open()
            #expect(try await database.books().isEmpty)
            #expect(try Data(contentsOf: preserved) == Data("original file".utf8))
            try await database.close()
        }
    }

    #if !os(Windows)
    @Test func descriptorPublicationFailurePreservesTheAdoptedLibraryForRetry() async throws {
        try await withDirectory { root in
            let dataset = root.appendingPathComponent("Library")
            try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: false)
            let database = try LibraryDatabase.create(at: dataset.appendingPathComponent("library.sqlite"))
            let reference = try SourceBookReference(installationID: .init(), referenceVersion: 1, key: "saved")
            let book = try await database.addBook(reference: reference, title: "keep", author: nil)
            try await database.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            defer {
                do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
                catch { Issue.record(error, "Unable to restore test directory permissions") }
            }
            let bootstrap = LibraryBootstrap(directory: root)
            await #expect(throws: (any Error).self) { try await bootstrap.open() }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
            let preserved = try LibraryDatabase(existingAt: dataset.appendingPathComponent("library.sqlite"))
            #expect(try await preserved.books() == [book])
            try await preserved.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let retried = try await bootstrap.open()
            #expect(try await retried.books() == [book])
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
            try await retried.close()
        }
    }
    #endif

    @Test func restoreSwitchesTheWholeDatasetAndSurvivesReopen() async throws {
        try await withDirectory { root in
            let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: false)
            let bootstrap = LibraryBootstrap(directory: root)
            let original = try await bootstrap.open()
            let originalReference = try SourceBookReference(installationID: .init(), referenceVersion: 1, key: "original")
            let originalBook = try await original.addBook(reference: originalReference, title: "Original", author: nil)
            let prepared = try await preparedBackup(title: "Restored", in: fixtures)
            let summary = try await bootstrap.restore(prepared)
            #expect(summary.books == 1 && summary.sources == 0)
            let switched = try await bootstrap.open()
            #expect(try await switched.books().map(\.title) == ["Restored"])
            await #expect(throws: LibraryDatabase.Failure.closed) { try await original.books() }

            let descriptor = try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("library.json"))) as? [String: Any]
            #expect(descriptor?["formatVersion"] as? Int == 2)
            #expect((descriptor?["directory"] as? String)?.hasPrefix("Datasets/") == true)
            let retained = try LibraryDatabase(existingAt: root.appendingPathComponent("Library").appendingPathComponent("library.sqlite"))
            #expect(try await retained.books() == [originalBook])
            try await retained.close()
            try await switched.close()

            let reopened = try await LibraryBootstrap(directory: root).open()
            #expect(try await reopened.books().map(\.title) == ["Restored"])
            try await reopened.close()
        }
    }

    @Test func invalidRestoreCandidateKeepsTheOriginalDataset() async throws {
        try await withDirectory { root in
            let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: false)
            let bootstrap = LibraryBootstrap(directory: root)
            let original = try await bootstrap.open()
            let reference = try SourceBookReference(installationID: .init(), referenceVersion: 1, key: "original")
            let book = try await original.addBook(reference: reference, title: "Original", author: nil)
            let prepared = try await preparedBackup(title: "Restored", in: fixtures)
            try Data("not a database".utf8).write(to: prepared.databaseURL)
            await #expect(throws: (any Error).self) { try await bootstrap.restore(prepared) }
            let active = try await bootstrap.open()
            #expect(try await active.books() == [book])
            let descriptor = try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("library.json"))) as? [String: Any]
            #expect(descriptor?["formatVersion"] as? Int == 1)
            try await active.close()
        }
    }

    @Test func restoreFaultAfterClosingTheOldWriterReopensTheOriginalDataset() async throws {
        try await withDirectory { root in
            let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: false)
            let bootstrap = LibraryBootstrap(directory: root)
            let original = try await bootstrap.open()
            let reference = try SourceBookReference(installationID: .init(), referenceVersion: 1, key: "original")
            let book = try await original.addBook(reference: reference, title: "Original", author: nil)
            let prepared = try await preparedBackup(title: "Restored", in: fixtures)
            await #expect(throws: (any Error).self) {
                try await bootstrap.restore(prepared, fault: .oldClosed, checkpoint: { _ in })
            }
            let active = try await bootstrap.open()
            #expect(try await active.books() == [book])
            try await active.close()
        }
    }

    @Test func restoreFaultAfterDescriptorCommitReopensTheNewDataset() async throws {
        try await withDirectory { root in
            let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: false)
            let bootstrap = LibraryBootstrap(directory: root)
            _ = try await bootstrap.open()
            let prepared = try await preparedBackup(title: "Restored", in: fixtures)
            await #expect(throws: (any Error).self) {
                try await bootstrap.restore(prepared, fault: .descriptorCommitted, checkpoint: { _ in })
            }
            let active = try await bootstrap.open()
            #expect(try await active.books().map(\.title) == ["Restored"])
            try await active.close()
            let reopened = try await LibraryBootstrap(directory: root).open()
            #expect(try await reopened.books().map(\.title) == ["Restored"])
            try await reopened.close()
        }
    }

    private static let digest: LibraryBackup.Digest = { try ProbeFileStoreTests.sha256($0) }

    private func preparedBackup(title: String, in directory: URL) async throws -> PreparedLibraryBackup {
        let source = directory.appendingPathComponent("source-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let database = try LibraryDatabase.create(at: source.appendingPathComponent("library.sqlite"))
        do {
            let reference = try SourceBookReference(installationID: .init(), referenceVersion: 1, key: "restored")
            _ = try await database.addBook(reference: reference, title: title, author: nil)
            let archive = directory.appendingPathComponent("backup-\(UUID()).snowlitbackup")
            _ = try await database.exportBackup(to: archive, includeCache: false, digest: Self.digest)
            try await database.close()
            return try await LibraryBackup.preflight(file: archive,
                into: directory.appendingPathComponent("candidate-\(UUID())"), digest: Self.digest)
        } catch {
            do { try await database.close() } catch { Issue.record(error, "Unable to close backup source") }
            throw error
        }
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitBootstrap-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove test data") }
        }
        try await body(root)
    }
}
