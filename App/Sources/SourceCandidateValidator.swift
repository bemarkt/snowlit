#if os(iOS)
import Foundation
import Observation
import UIKit
import WebKit
import SnowlitCore
import SnowlitStorage
import YingxueKit

@MainActor
@Observable
final class SourceCandidateValidator {
    enum Failure: Error { case busy, cleanupRequired }
    private(set) var active: SourceExecutionSession?
    @ObservationIgnored private var work: Task<SourceUpdateMigrationValues?, any Error>?

    func validate(_ request: SourceManagementModel.ValidationRequest) async throws -> SourceUpdateMigrationValues? {
        guard active == nil else { throw Failure.busy }
        let session = try SourceExecutionSession(request: request)
        active = session
        let task = Task { @MainActor in try await session.run() }
        work = task
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        do { try await session.close() }
        catch { throw Failure.cleanupRequired }
        if active === session { active = nil; work = nil }
        try Task.checkCancellation()
        if task.isCancelled { throw CancellationError() }
        return try result.get()
    }

    func cancel() { work?.cancel() }

    func invalidate(_ installation: SourceInstallationID) async throws {
        guard let session = active, session.installationID == installation else { return }
        work?.cancel()
        if let work { _ = await work.result }
        try await session.close()
        if active === session { active = nil; work = nil }
    }

    func retryCleanup() async throws {
        guard let session = active, session.phase == .cleanupRequired else { return }
        try await session.close()
        if active === session { active = nil; work = nil }
    }

    func cleanup(_ installation: SourceInstallationID, token: SourceSessionCleanup) async throws {
        try await invalidate(installation)
        // Exact cleanup token remains in Storage until deletion succeeds.
        // Do not open the named store here: querying/erasing it starts a network
        // session which prevents removal of that very store. Enumerating the
        // identifiers also makes a retry after deletion a no-op for website data.
        let task = Task { @MainActor in
            let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
            if identifiers.contains(token.websiteSessionID) {
                try await WKWebsiteDataStore.remove(forIdentifier: token.websiteSessionID)
            }
            try await KeychainCredentialStore().removeAll(for: installation)
        }
        try await task.value
    }
}

#endif
