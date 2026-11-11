import Foundation
import SnowlitCore
import SnowlitStorage
import Testing
@testable import Snowlit

@MainActor
struct BackupModelTests {
    @Test func lateCancelledSuccessIsNeverOfferedToShare() async throws {
        let fixture = Fixture()
        let model = BackupModel(export: { _ in await fixture.export() }, inspect: { _ in Self.summary }, clear: { await fixture.clear() })
        let operation = Task { await model.run(.export(includeCache: true)) }
        await fixture.waitForStart()
        operation.cancel()
        await fixture.finish()
        await operation.value
        #expect(!model.isBusy && model.exported == nil && model.preview == nil && model.problem == nil)
        #expect(await fixture.cleanups == 1)
    }

    @Test func failureDoesNotLeavePreviousSuccessAndCleanupFailureIsVisible() async {
        let fixture = Fixture()
        let model = BackupModel(export: { _ in .init(file: URL(fileURLWithPath: "/backup"), summary: Self.summary) },
            inspect: { _ in throw LibraryBackupFailure.damagedArchive }, clear: { try await fixture.failingClear() })
        await model.run(.export(includeCache: false))
        #expect(model.exported != nil)
        await model.run(.preview(URL(fileURLWithPath: "/damaged")))
        #expect(model.exported == nil && model.preview == nil && !model.isBusy)
        #expect(model.problem?.message.contains("清理") == true)
    }

    @Test func activeOperationRejectsASecondMutationOfItsTemporaryFiles() async {
        let fixture = Fixture()
        let model = BackupModel(export: { _ in await fixture.export() }, inspect: { _ in Self.summary }, clear: { await fixture.clear() })
        let operation = Task { await model.run(.export(includeCache: true)) }
        await fixture.waitForStart()
        await model.run(.preview(URL(fileURLWithPath: "/other")))
        #expect(model.isBusy && model.preview == nil)
        await fixture.finish()
        await operation.value
        #expect(model.exported != nil && model.preview == nil && !model.isBusy)
    }

    @Test func restoreUsesTheValidatedCandidateAndRefreshesVisibleData() async {
        let fixture = Fixture()
        let model = BackupModel(export: { _ in .init(file: URL(fileURLWithPath: "/backup"), summary: Self.summary) },
            inspect: { _ in Self.summary },
            restore: { Self.summary },
            clear: { await fixture.clear() },
            refresh: { await fixture.refresh() })
        await model.run(.preview(URL(fileURLWithPath: "/backup")))
        #expect(model.preview == Self.summary)
        await model.run(.restore)
        #expect(model.restored == Self.summary && model.preview == nil && model.problem == nil)
        #expect(await fixture.refreshes == 1)
    }

    #if canImport(CryptoKit)
    @Test func workspacePreviewAndAdoptSwitchTheWholeLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitBackupWorkspace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove backup workspace fixture") }
        }
        let bootstrap = LibraryBootstrap(directory: root)
        let database = try await bootstrap.open()
        let first = try await database.addBook(
            reference: .init(installationID: .init(), referenceVersion: 1, key: "first"),
            title: "Before", author: nil)
        do {
            let workspace = BackupWorkspace(openLibrary: { try await bootstrap.open() },
                adoptDataset: { try await bootstrap.restore($0) })
            let exported = try await workspace.export(includeCache: false)
            // The UI selects an external file. Keep the exported temp file out
            // of the workspace's reclaimable directory before importing it.
            let selected = root.appendingPathComponent("selected.snowlitbackup")
            try FileManager.default.copyItem(at: exported.file, to: selected)
            _ = try await database.addBook(
                reference: .init(installationID: .init(), referenceVersion: 1, key: "second"),
                title: "After", author: nil)
            let preview = try await workspace.preview(selected)
            #expect(preview.books == 1)
            let adopted = try await workspace.adopt()
            #expect(adopted.books == 1)
            let active = try await bootstrap.open()
            #expect(try await active.books() == [first])
            try await active.close()
        } catch {
            do { try await database.close() } catch { Issue.record(error, "Unable to close backup fixture") }
            throw error
        }
    }
    #endif

    nonisolated private static let summary = LibraryBackupSummary(createdAt: Date(timeIntervalSince1970: 0), includesCache: false, sources: 0, books: 0, cachedChapters: 0)

    private actor Fixture {
        var cleanups = 0
        var refreshes = 0
        func refresh() { refreshes += 1 }
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var exportWaiter: CheckedContinuation<BackupModel.Export, Never>?

        func export() async -> BackupModel.Export {
            await withCheckedContinuation { continuation in
                exportWaiter = continuation
                started = true; startWaiter?.resume(); startWaiter = nil
            }
        }
        func waitForStart() async {
            if started { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func finish() { exportWaiter?.resume(returning: .init(file: URL(fileURLWithPath: "/backup"), summary: BackupModelTests.summary)); exportWaiter = nil }
        func clear() { cleanups += 1 }
        func failingClear() throws { throw LibraryBackupFailure.invalidPath }
    }
}
