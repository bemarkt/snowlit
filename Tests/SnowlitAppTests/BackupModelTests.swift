import Foundation
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

    nonisolated private static let summary = LibraryBackupSummary(createdAt: Date(timeIntervalSince1970: 0), includesCache: false, sources: 0, books: 0, cachedChapters: 0)

    private actor Fixture {
        var cleanups = 0
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
