import Foundation
import SnowlitCore
import SnowlitStorage
import Testing
#if canImport(SwiftUI)
import UniformTypeIdentifiers
#endif
import YingxueKit
@testable import Snowlit

@MainActor
struct SourceLibraryModelTests {
    #if canImport(SwiftUI)
    @Test func fileImporterAcceptsProvidersWithoutSourceUTI() {
        #expect(SourceLibraryView.sourceImportTypes.contains(.item))
        #expect(SourceLibraryView.sourceImportTypes.contains(.javaScript))
        #expect(SourceLibraryView.sourceImportTypes.contains(.json))
        #expect(SourceLibraryView.sourceImportTypes.contains(.plainText))
        #expect(SourceLibraryView.sourceImportTypes.contains(.data))
    }
    #endif

    @Test func previewCancelAndSaveDoNotActivateOrGrantCredentials() async throws {
        try await withLibrary { path, library in
            let model = makeModel(library)
            await model.preview(bytes: Self.fixture, fileName: "source.js")
            #expect(model.review?.manifest.capabilities.contains(.credentialsRead) == true)
            #expect(try await library.sourceImports().isEmpty)
            model.cancelPreview()
            await model.saveReviewedImport()
            #expect(try await library.sourceImports().isEmpty)
            await model.preview(bytes: Self.fixture, fileName: "source.js")
            await model.saveReviewedImport()
            #expect(model.review == nil && model.savedName == "Fixture")
            #expect(model.imports.count == 1 && model.installations.isEmpty)
            #expect(model.imports.first?.script.bytes == Self.fixture)
            #expect(try await library.sourceInstallations().isEmpty)
            try await library.close()
            let reopened = try LibraryDatabase(existingAt: path)
            let next = makeModel(reopened)
            await next.refresh()
            #expect(next.imports.count == 1 && next.installations.isEmpty)
            #expect(next.imports.first?.receipt.fileName == "source.js")
            try await reopened.close()
        }
    }

    @Test func malformedOrRejectedFilesLeaveStorageAndCurrentPreviewUntouched() async throws {
        try await withLibrary { (_, library) async throws in
            let malformed = makeModel(library)
            await malformed.preview(bytes: Data([0xff]), fileName: "bad.js")
            #expect(malformed.problem != nil && malformed.review == nil && !malformed.isInspecting)
            let rejected = makeModel(library, inspect: { _, _ in
                Data(#"{"kind":"accepted","exports":[]}"#.utf8)
            })
            await rejected.preview(bytes: Self.fixture, fileName: "bad.js")
            #expect(rejected.problem != nil && rejected.review == nil)
            #expect(try await library.sourceImports().isEmpty)
            #expect(try await library.sourceInstallations().isEmpty)
        }
    }

    @Test func cancelledInspectionCannotRepublishLateResult() async throws {
        try await withLibrary { (_, library) async throws in
            let pending = PendingInspection()
            let model = makeModel(library, inspect: { _, _ in try await pending.run() })
            // The test owns and joins the deliberately delayed callback task.
            let task = Task { await model.preview(bytes: Self.fixture, fileName: "cancelled.js") }
            await pending.waitUntilStarted()
            model.cancelPreview()
            pending.finish()
            await task.value
            #expect(model.review == nil && !model.isInspecting && model.problem == nil)
            #expect(try await library.sourceImports().isEmpty)
        }
    }

    @Test func newestFileSelectionWinsWhenPreviousInspectionFinishesLate() async throws {
        try await withLibrary { (_, library) async throws in
            let pending = PendingInspection()
            var calls = 0
            let model = makeModel(library, inspect: { _, _ in
                calls += 1
                return calls == 1 ? try await pending.run() : Self.accepted
            })
            let old = Task { await model.preview(bytes: Self.fixture, fileName: "old.js") }
            await pending.waitUntilStarted()
            await model.preview(bytes: Self.fixture, fileName: "new.js")
            #expect(model.review?.receipt.fileName == "new.js")
            pending.finish()
            await old.value
            #expect(model.review?.receipt.fileName == "new.js")
        }
    }

    @Test func lateFileReadCannotReplaceASelectionMadeAfterCancellation() async throws {
        try await withLibrary { (_, library) async throws in
            let read = PendingInspection()
            let model = SourceLibraryModel(openLibrary: { library }, inspect: { _, _ in Self.accepted },
                digest: Self.digest, readFile: { _ in try await read.run() })
            let old = Task { await model.previewFile(URL(fileURLWithPath: "/private/old.js")) }
            await read.waitUntilStarted()
            model.cancelPreview()
            await model.preview(bytes: Self.fixture, fileName: "new.js")
            read.finish(Self.fixture)
            await old.value
            #expect(model.review?.receipt.fileName == "new.js")
            #expect(model.problem == nil)
        }
    }

    @Test func removedSourcePreviewNamesRetainedBooksWithoutRestoringThem() async throws {
        try await withLibrary { (_, library) async throws in
            let model = makeModel(library)
            await model.preview(bytes: Self.fixture, fileName: "source.js")
            await model.saveReviewedImport()
            let receipt = try #require(model.imports.first?.receipt)
            let installed = try await library.installSource(importID: receipt.id, id: SourceInstallationID(), configuration: [], consent: .approvedForCandidate)
            let book = try await library.addBook(reference: .init(installationID: installed.id, referenceVersion: 1, key: "book"), title: "Saved", author: nil)
            let removed = try await library.removeSource(expected: installed)
            await model.preview(bytes: Self.fixture, fileName: "reimport.js")
            #expect(model.review?.existing?.id == installed.id && model.review?.retainedBooks == 1)
            #expect(model.review?.upgrade?.credentialReadConsentRequired == true)
            await model.saveReviewedImport()
            #expect(try await library.sourceInstallations() == [removed])
            #expect(try await library.books() == [book])
            #expect(!removed.allowsCredentialRead)
        }
    }

    private func makeModel(_ library: LibraryDatabase,
        inspect: @escaping @MainActor (String, [String]) async throws -> Data = { _, _ in Self.accepted }) -> SourceLibraryModel {
        SourceLibraryModel(openLibrary: { library }, inspect: inspect, digest: Self.digest,
            readFile: { _ in Self.fixture })
    }

    nonisolated private static let digest: SourceScriptSnapshot.Digest = { _ in String(repeating: "a", count: 64) }
    nonisolated fileprivate static let accepted = Data(#"{"kind":"accepted","exports":["search","book","chapters","chapter"]}"#.utf8)
    nonisolated private static let fixture = Data("""
        /* @yingxue
        {"protocolVersion":1,"sourceID":"org.example.preview","name":"Fixture","scriptVersion":"1","referenceVersion":1,"stateVersion":1,"capabilities":["credentials.read"],"origins":[],"authentication":[],"publicConfiguration":[]}
        */
        export async function search(ctx, input) {}
        export async function book(ctx, input) {}
        export async function chapters(ctx, input) {}
        export async function chapter(ctx, input) {}
        """.utf8)

    private func withLibrary(_ body: (URL, LibraryDatabase) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitImportModel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error, "Unable to remove isolated import data") }
        }
        let path = directory.appendingPathComponent("library.sqlite")
        let library = try LibraryDatabase.create(at: path)
        do { try await body(path, library); try await library.close() }
        catch {
            do { try await library.close() } catch { Issue.record(error, "Unable to close import fixture") }
            throw error
        }
    }
}

@MainActor
private final class PendingInspection {
    private var continuation: CheckedContinuation<Data, any Error>?
    private var observer: CheckedContinuation<Void, Never>?
    private var started = false

    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started = true; observer?.resume(); observer = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finish(_ data: Data = SourceLibraryModelTests.accepted) {
        continuation?.resume(returning: data); continuation = nil
    }
}
