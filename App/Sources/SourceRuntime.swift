import Foundation
import Observation
import SnowlitCore
import SnowlitStorage
import YingxueKit

/// One foreground source operation owns its Worker, native requests and UI.
/// Management awaits invalidation before changing the installed snapshot.
@MainActor
@Observable
final class SourceRuntime {
    enum Failure: Error { case busy, cleanupRequired }
    private(set) var active: SourceExecutionSession?
    private(set) var isPreparing = false
    var presentation: SourceExecutionSession? {
        guard let active, active.needsPresentation || active.phase == .cleanupRequired else { return nil }
        return active
    }
    @ObservationIgnored private let openLibrary: @Sendable () async throws -> LibraryDatabase
    @ObservationIgnored private let digest: SourceScriptSnapshot.Digest
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var installationID: SourceInstallationID?
    @ObservationIgnored private var work: Task<YingxueWire.OperationReply, any Error>?

    init(openLibrary: @escaping @Sendable () async throws -> LibraryDatabase, digest: @escaping SourceScriptSnapshot.Digest) {
        self.openLibrary = openLibrary; self.digest = digest
    }

    func invoke(_ input: YingxueWire.OperationInput, expected: SourceInstallationSnapshot) async throws -> YingxueWire.OperationReply {
        if let previous = work, previous.isCancelled, let id = operationID {
            _ = await previous.result
            try await finish(id)
        }
        try Task.checkCancellation()
        guard work == nil && active == nil else { throw Failure.busy }
        let id = UUID()
        operationID = id; installationID = expected.id; isPreparing = true
        // Finite work is owned here so view cancellation, backgrounding and
        // source management all cancel and await the same task.
        let task = Task { @MainActor [self] in
            let library = try await openLibrary()
            guard let script = try await library.sourceScript(sha256: expected.scriptSHA256, digest: digest) else {
                throw SourceInstallationFailure.missingImport
            }
            try Task.checkCancellation()
            let session = try SourceExecutionSession(installation: expected, script: script, library: library)
            active = session; isPreparing = false
            return try await session.runOperation(input)
        }
        work = task
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        try await finish(id)
        try Task.checkCancellation()
        if task.isCancelled { throw CancellationError() }
        return try result.get()
    }

    func cancel() { work?.cancel(); active?.requestRevocation() }

    func invalidate(_ installation: SourceInstallationID) async throws {
        guard installationID == installation, let id = operationID else { return }
        let pending = work
        pending?.cancel()
        active?.requestRevocation()
        if let pending { _ = await pending.result }
        try await finish(id)
    }

    func retryCleanup() async throws {
        guard active?.phase == .cleanupRequired, let id = operationID else { return }
        try await finish(id)
    }

    private func finish(_ id: UUID) async throws {
        guard operationID == id else { return }
        if let session = active {
            do { try await session.close() }
            catch { throw Failure.cleanupRequired }
            guard operationID == id, active === session else { return }
        }
        active = nil; work = nil; operationID = nil; installationID = nil; isPreparing = false
    }
}
