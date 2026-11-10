import Foundation
import Observation
import SnowlitCore
import SnowlitStorage
import YingxueKit

/// Owns the native confirmation boundary. Candidate code can prepare values,
/// but only this model can adopt them after an explicit, current confirmation.
@MainActor
@Observable
final class SourceManagementModel {
    struct Candidate: Identifiable {
        let id = UUID()
        let installationID: SourceInstallationID
        let receipt: SourceImportRecord
        let script: SourceScriptSnapshot
        let manifest: YingxueWire.Manifest
        let existing: SourceInstallationSnapshot?
        let prepared: SourceUpdateSnapshot?
        let migrations: SourceUpdateMigrationValues?
        let configuration: [SourceSettingValue]
        var retainedBooks: Int { prepared?.books.count ?? 0 }
        var restoresAssociation: Bool { existing?.state == .removed }
        var requestsCredentialRead: Bool { manifest.capabilities.contains(.credentialsRead) }
    }

    struct Problem: Identifiable {
        let id = UUID()
        let message: String
    }

    enum Action { case enable, disable, remove, signOut, retryCleanup }
    enum Failure: Error { case confirmationRequired, inconsistentValidation }

    typealias Validator = @MainActor (SourceScriptSnapshot, SourceUpgradeAssessment?, SourceUpdateMigrationPlan?) async throws -> SourceUpdateMigrationValues?

    private(set) var candidate: Candidate?
    private(set) var isPreparing = false
    private(set) var isChanging = false
    private(set) var problem: Problem?
    private(set) var changed = 0

    @ObservationIgnored private let openLibrary: @Sendable () async throws -> LibraryDatabase
    @ObservationIgnored private let digest: SourceScriptSnapshot.Digest
    @ObservationIgnored private let validate: Validator
    @ObservationIgnored private let invalidate: @MainActor (SourceInstallationID) async -> Void
    @ObservationIgnored private let cleanup: @MainActor (SourceInstallationID, SourceSessionCleanup) async throws -> Void
    @ObservationIgnored private var preparationID: UUID?

    init(openLibrary: @escaping @Sendable () async throws -> LibraryDatabase,
         digest: @escaping SourceScriptSnapshot.Digest,
         validate: @escaping Validator,
         invalidate: @escaping @MainActor (SourceInstallationID) async -> Void,
         cleanup: @escaping @MainActor (SourceInstallationID, SourceSessionCleanup) async throws -> Void) {
        self.openLibrary = openLibrary; self.digest = digest; self.validate = validate
        self.invalidate = invalidate; self.cleanup = cleanup
    }

    func prepare(importID: UUID) async {
        guard !isChanging else { return }
        let attempt = UUID()
        preparationID = attempt; candidate = nil; problem = nil; isPreparing = true
        defer { if preparationID == attempt { isPreparing = false } }
        do {
            let library = try await openLibrary()
            let receipts = try await library.sourceImports()
            guard let receipt = receipts.first(where: { $0.id == importID }),
                  let script = try await library.sourceScript(sha256: receipt.scriptSHA256, digest: digest) else {
                throw SourceInstallationFailure.missingImport
            }
            let manifest = try SourceFileHeader(bytes: script.bytes).manifest
            let installations = try await library.sourceInstallations()
            let existing = installations.first { $0.metadata.sourceID.utf8.elementsEqual(manifest.sourceID.utf8) }
            if existing?.pendingCleanup != nil { throw SourceInstallationFailure.cleanupPending }
            if let existing, existing.state != .removed, existing.scriptSHA256 == script.sha256 {
                throw SourceInstallationFailure.alreadyCurrent
            }
            let installationID = existing?.id ?? SourceInstallationID()
            let upgrade: SourceUpgradeAssessment?
            let prepared: SourceUpdateSnapshot?
            if let existing {
                guard let current = try await library.sourceScript(sha256: existing.scriptSHA256, digest: digest) else {
                    throw SourceInstallationFailure.missingImport
                }
                upgrade = try .init(current: SourceFileHeader(bytes: current.bytes).manifest, candidate: manifest)
                prepared = try await library.captureSourceUpdate(importID: importID, expected: existing)
            } else {
                upgrade = nil; prepared = nil
            }
            // Incompatible public settings are not silently discarded. The
            // installed source keeps its settings until the user changes them.
            let policy = try SourceHostPolicy(installationID: installationID, scriptSHA256: script.sha256, manifest: manifest)
            let configuration = try SourceConfiguration(policy: policy, revision: 0, saved: existing?.configuration ?? []).storedValues
            let plan = try prepared.map { try SourceUpdateMigrationPlan(prepared: $0) }
            try Task.checkCancellation()
            guard preparationID == attempt else { return }
            let migrations = try await validate(script, upgrade, plan)
            guard (prepared == nil) == (migrations == nil) else { throw Failure.inconsistentValidation }
            try Task.checkCancellation()
            guard preparationID == attempt else { return }
            candidate = .init(installationID: installationID, receipt: receipt, script: script, manifest: manifest,
                existing: existing, prepared: prepared, migrations: migrations, configuration: configuration)
        } catch {
            guard preparationID == attempt, !(error is CancellationError), !Task.isCancelled else { return }
            problem = .init(message: Self.message(for: error))
        }
    }

    func cancelPreparation() {
        guard !isChanging else { return }
        preparationID = nil; candidate = nil; isPreparing = false; problem = nil
    }

    func confirm(candidateID: UUID, allowCredentialRead: Bool, restoreAssociation: Bool,
                 configuration: [SourceSettingValue]) async {
        guard !isChanging, let candidate, candidate.id == candidateID else { return }
        isChanging = true; problem = nil
        defer { isChanging = false }
        do {
            guard !candidate.restoresAssociation || restoreAssociation,
                  !allowCredentialRead || candidate.requestsCredentialRead else { throw Failure.confirmationRequired }
            let policy = try SourceHostPolicy(installationID: candidate.installationID,
                scriptSHA256: candidate.script.sha256, manifest: candidate.manifest)
            let values = try SourceConfiguration(policy: policy, revision: 0, saved: configuration).storedValues
            let consent: SnowlitCore.SourceCredentialReadConsent = allowCredentialRead ? .approvedForCandidate : .managedOnly
            let library = try await openLibrary()
            try Task.checkCancellation()
            if let existing = candidate.existing {
                // Stop old operations before changing the installation. Storage
                // repeats the complete CAS and revokes persistent write permits.
                await invalidate(existing.id)
                try Task.checkCancellation()
                guard let prepared = candidate.prepared, let migrations = candidate.migrations else {
                    throw Failure.inconsistentValidation
                }
                if candidate.restoresAssociation {
                    _ = try await library.restoreSource(confirmed: prepared, migratedState: migrations.state,
                        referenceChanges: migrations.references, configuration: values, consent: consent)
                } else {
                    _ = try await library.updateSource(prepared: prepared, migratedState: migrations.state,
                        referenceChanges: migrations.references, configuration: values, consent: consent)
                }
            } else {
                _ = try await library.installSource(importID: candidate.receipt.id, id: candidate.installationID,
                    configuration: values, consent: consent)
            }
            self.candidate = nil; preparationID = nil; changed += 1
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            if error as? SourceInstallationFailure == .staleInstallation || error as? SourceUpdateFailure == .staleInventory {
                self.candidate = nil; preparationID = nil
            }
            problem = .init(message: Self.message(for: error))
        }
    }

    /// Call remove only from the native removal confirmation. Reading data is
    /// retained by the store; website/Keychain cleanup remains separately retryable.
    func perform(_ action: Action, expected: SourceInstallationSnapshot) async {
        guard !isChanging, !isPreparing else { return }
        isChanging = true; problem = nil; candidate = nil; preparationID = nil
        defer { isChanging = false }
        do {
            let library = try await openLibrary()
            await invalidate(expected.id)
            try Task.checkCancellation()
            let updated: SourceInstallationSnapshot
            switch action {
            case .enable: updated = try await library.setSourceEnabled(true, expected: expected)
            case .disable: updated = try await library.setSourceEnabled(false, expected: expected)
            case .remove: updated = try await library.removeSource(expected: expected)
            case .signOut: updated = try await library.signOutSource(expected: expected)
            case .retryCleanup:
                let actual = try await library.sourceInstallations().first { $0.id == expected.id }
                guard actual == expected else { throw SourceInstallationFailure.staleInstallation }
                updated = expected
            }
            changed += 1
            if let token = updated.pendingCleanup {
                try await cleanup(updated.id, token)
                guard try await library.finishSourceSessionCleanup(token, installationID: updated.id) else {
                    throw SourceInstallationFailure.staleInstallation
                }
                changed += 1
            }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            problem = .init(message: Self.message(for: error))
        }
    }

    func clearProblem() { problem = nil }

    private static func message(for error: any Error) -> String {
        if error as? SourceInstallationFailure == .cleanupPending {
            return "上次登录数据尚未清理完成。请先重试清理，再启用或恢复书源。"
        }
        if error as? SourceInstallationFailure == .alreadyCurrent { return "这个版本已安装，可在书源管理中启用或停用。" }
        if error as? SourceInstallationFailure == .staleInstallation || error as? SourceUpdateFailure == .staleInventory {
            return "书源或阅读数据已经变化，请重新验证此候选后确认。"
        }
        if error is SourceConfigurationFailure { return "已有设置不符合这个版本，当前设置已保留。请检查新版配置要求。" }
        if error is Failure { return "请核对书源权限与恢复关联的确认，尚未采用此候选。" }
        return "操作未完成，请重试。阅读数据会保留；如有待清理的登录数据，请先完成清理。"
    }
}
