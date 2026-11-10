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
