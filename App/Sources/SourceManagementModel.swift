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
        let upgrade: SourceUpgradeAssessment?
        let plan: SourceUpdateMigrationPlan?
        let configuration: [SourceSettingValue]
        let configurationChanges: [ConfigurationChange]
        var retainedBooks: Int { prepared?.books.count ?? 0 }
        var restoresAssociation: Bool { existing?.state == .removed }
        var requestsCredentialRead: Bool { manifest.capabilities.contains(.credentialsRead) }
    }

    struct Problem: Identifiable {
        let id = UUID()
        let message: String
    }

    struct ConfigurationChange: Identifiable {
        enum Reason { case removed, typeChanged, choiceRemoved }
        let previous: SourceSettingValue
        let label: String
        let reason: Reason
        let proposedDefault: SourceSettingValue?
        var id: Data { Data(previous.key.utf8) }
    }

    enum Action { case enable, disable, remove, signOut, retryCleanup }
    enum Failure: Error { case confirmationRequired, inconsistentValidation }

    /// Exact native confirmation for an isolated candidate run. These values do
    /// not grant the candidate write access to the active installation.
    struct ValidationRequest {
        let candidate: Candidate
        let configuration: [SourceSettingValue]
        let allowCredentialRead: Bool
    }

    typealias Validator = @MainActor (ValidationRequest) async throws -> SourceUpdateMigrationValues?

    private(set) var candidate: Candidate?
    private(set) var isPreparing = false
    private(set) var isValidating = false
    private(set) var isChanging = false
    private(set) var problem: Problem?
    private(set) var changed = 0

    @ObservationIgnored private let openLibrary: @Sendable () async throws -> LibraryDatabase
    @ObservationIgnored private let digest: SourceScriptSnapshot.Digest
    @ObservationIgnored private let validate: Validator
    @ObservationIgnored private let invalidate: @MainActor (SourceInstallationID) async throws -> Void
    @ObservationIgnored private let cleanup: @MainActor (SourceInstallationID, SourceSessionCleanup) async throws -> Void
    @ObservationIgnored private var preparationID: UUID?
    @ObservationIgnored private var validationID: UUID?
    // Finite candidate work is owned here so native cancellation also cancels
    // the backend task. Its identity prevents an uncooperative late result from
    // affecting a newer confirmation. No task owns the active installation.
    @ObservationIgnored private var validationTask: Task<SourceUpdateMigrationValues?, any Error>?

    init(openLibrary: @escaping @Sendable () async throws -> LibraryDatabase,
         digest: @escaping SourceScriptSnapshot.Digest,
         validate: @escaping Validator,
         invalidate: @escaping @MainActor (SourceInstallationID) async throws -> Void,
         cleanup: @escaping @MainActor (SourceInstallationID, SourceSessionCleanup) async throws -> Void) {
        self.openLibrary = openLibrary; self.digest = digest; self.validate = validate
        self.invalidate = invalidate; self.cleanup = cleanup
    }

    func prepare(importID: UUID) async {
        guard !isChanging, !isValidating else { return }
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
            let previousManifest: YingxueWire.Manifest?
            if let existing {
                guard let current = try await library.sourceScript(sha256: existing.scriptSHA256, digest: digest) else {
                    throw SourceInstallationFailure.missingImport
                }
                previousManifest = try SourceFileHeader(bytes: current.bytes).manifest
                upgrade = try previousManifest.map { try .init(current: $0, candidate: manifest) }
                prepared = try await library.captureSourceUpdate(importID: importID, expected: existing)
            } else {
                upgrade = nil; prepared = nil; previousManifest = nil
            }
            let policy = try SourceHostPolicy(installationID: installationID, scriptSHA256: script.sha256, manifest: manifest)
            let review = try Self.reviewConfiguration(policy: policy, manifest: manifest, previousManifest: previousManifest, existing: existing)
            let plan = try prepared.map { try SourceUpdateMigrationPlan(prepared: $0) }
            try Task.checkCancellation()
            guard preparationID == attempt else { return }
            candidate = .init(installationID: installationID, receipt: receipt, script: script, manifest: manifest,
                existing: existing, prepared: prepared, upgrade: upgrade, plan: plan,
                configuration: review.values, configurationChanges: review.changes)
        } catch {
            guard preparationID == attempt, !(error is CancellationError), !Task.isCancelled else { return }
            problem = .init(message: Self.message(for: error))
        }
    }

    func cancelPreparation() {
        guard !isChanging else { return }
        validationTask?.cancel(); validationTask = nil; validationID = nil; isValidating = false
        preparationID = nil; candidate = nil; isPreparing = false; problem = nil
    }

    func confirm(candidateID: UUID, allowCredentialRead: Bool, restoreAssociation: Bool,
                 configuration: [SourceSettingValue], acknowledgedConfigurationChanges: Set<Data> = []) async {
        guard !isChanging, !isValidating, let candidate, candidate.id == candidateID else { return }
        let attempt = UUID()
        validationID = attempt; isValidating = true; problem = nil
        var adopting = false
        defer {
            if validationID == attempt {
                validationTask = nil; validationID = nil; isValidating = false
            }
            if adopting { isChanging = false }
        }
        do {
            guard !candidate.restoresAssociation || restoreAssociation,
                  !allowCredentialRead || candidate.requestsCredentialRead,
                  Set(candidate.configurationChanges.map(\.id)) == acknowledgedConfigurationChanges else {
                throw Failure.confirmationRequired
            }
            let policy = try SourceHostPolicy(installationID: candidate.installationID,
                scriptSHA256: candidate.script.sha256, manifest: candidate.manifest)
            let values = try SourceConfiguration(policy: policy, revision: 0, saved: configuration).storedValues
            let consent: SnowlitCore.SourceCredentialReadConsent = allowCredentialRead ? .approvedForCandidate : .managedOnly
            let request = ValidationRequest(candidate: candidate, configuration: values, allowCredentialRead: allowCredentialRead)
            let work = Task { @MainActor [validate] in try await validate(request) }
            validationTask = work
            let migrations = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try Task.checkCancellation()
            guard validationID == attempt, self.candidate?.id == candidateID else { return }
            guard (candidate.prepared == nil) == (migrations == nil) else { throw Failure.inconsistentValidation }
            isValidating = false; isChanging = true; adopting = true
            let library = try await openLibrary()
            try Task.checkCancellation()
            if let existing = candidate.existing {
                // Stop old operations before changing the installation. Storage
                // repeats the complete CAS and revokes persistent write permits.
                try await invalidate(existing.id)
                try Task.checkCancellation()
                guard let prepared = candidate.prepared, let migrations else {
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
            guard validationID == attempt else { return }
            guard !(error is CancellationError), !Task.isCancelled else { return }
            if error as? SourceInstallationFailure == .staleInstallation || error as? SourceUpdateFailure == .staleInventory {
                self.candidate = nil; preparationID = nil
            }
            problem = .init(message: Self.message(for: error))
        }
    }

    /// Call remove only from the native removal confirmation. Reading data is
    /// retained by the store; website/Keychain cleanup remains separately retryable.
    @discardableResult
    func perform(_ action: Action, expected: SourceInstallationSnapshot) async -> SourceInstallationSnapshot? {
        guard !isChanging, !isPreparing, !isValidating else { return nil }
        isChanging = true; problem = nil; candidate = nil; preparationID = nil
        defer { isChanging = false }
        do {
            let library = try await openLibrary()
            try await invalidate(expected.id)
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
                return try .init(id: updated.id, importID: updated.importID, scriptSHA256: updated.scriptSHA256,
                    metadata: updated.metadata, revision: updated.revision + 1, state: updated.state,
                    configuration: updated.configuration, allowsCredentialRead: updated.allowsCredentialRead,
                    websiteSessionID: updated.websiteSessionID, pendingCleanup: nil)
            }
            return updated
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return nil }
            problem = .init(message: Self.message(for: error))
            return nil
        }
    }

    func clearProblem() { problem = nil }

    private static func reviewConfiguration(policy: SourceHostPolicy, manifest: YingxueWire.Manifest, previousManifest: YingxueWire.Manifest?,
                                            existing: SourceInstallationSnapshot?) throws
        -> (values: [SourceSettingValue], changes: [ConfigurationChange]) {
        let defaults = try SourceConfiguration(policy: policy, revision: 0, saved: []).storedValues
        guard let previousManifest, let existing else { return (defaults, []) }
        let oldPolicy = try SourceHostPolicy(installationID: existing.id, scriptSHA256: existing.scriptSHA256,
                                            manifest: previousManifest)
        // Validate the old version too; malformed stored settings are not
        // silently treated as an expected incompatibility in the new version.
        let oldValues = try SourceConfiguration(policy: oldPolicy, revision: 0, saved: existing.configuration).storedValues
        var retained: [SourceSettingValue] = []
        var changes: [ConfigurationChange] = []
        for old in oldValues {
            guard let oldField = previousManifest.publicConfiguration.first(where: { fieldKey($0).utf8.elementsEqual(old.key.utf8) }) else {
                throw Failure.inconsistentValidation
            }
            guard let newField = manifest.publicConfiguration.first(where: { fieldKey($0).utf8.elementsEqual(old.key.utf8) }) else {
                changes.append(.init(previous: old, label: fieldLabel(oldField), reason: .removed, proposedDefault: nil))
                continue
            }
            let reason: ConfigurationChange.Reason?
            switch (oldField, newField) {
            case (.text, .text), (.boolean, .boolean): reason = nil
            case (.choice, .choice(let field)):
                guard case .text(_, let selected) = old else { throw Failure.inconsistentValidation }
                reason = field.choices.contains { $0.value.utf8.elementsEqual(selected.utf8) } ? nil : .choiceRemoved
            default: reason = .typeChanged
            }
            if let reason {
                let proposed = defaults.first { $0.key.utf8.elementsEqual(old.key.utf8) }
                guard proposed != nil else { throw Failure.inconsistentValidation }
                changes.append(.init(previous: old, label: fieldLabel(newField), reason: reason, proposedDefault: proposed))
            } else {
                retained.append(old)
            }
        }
        return (try SourceConfiguration(policy: policy, revision: 0, saved: retained).storedValues, changes)
    }

    private static func fieldKey(_ field: YingxueWire.PublicSetting) -> String {
        switch field {
        case .text(let field): field.key
        case .boolean(let field): field.key
        case .choice(let field): field.key
        }
    }

    private static func fieldLabel(_ field: YingxueWire.PublicSetting) -> String {
        switch field {
        case .text(let field): field.label
        case .boolean(let field): field.label
        case .choice(let field): field.label
        }
    }

    private static func message(for error: any Error) -> String {
        if error as? SourceInstallationFailure == .cleanupPending {
            return "上次登录数据尚未清理完成。请先重试清理，再启用或恢复书源。"
        }
        if error as? SourceInstallationFailure == .alreadyCurrent { return "这个版本已安装，可在书源管理中启用或停用。" }
        if error as? SourceInstallationFailure == .staleInstallation || error as? SourceUpdateFailure == .staleInventory {
            return "书源或阅读数据已经变化，请重新验证此候选后确认。"
        }
        if error is SourceConfigurationFailure { return "已有设置不符合这个版本，当前设置已保留。请检查新版配置要求。" }
        if error is Failure { return "请核对设置变化、书源权限与恢复关联的确认，尚未采用此候选。" }
        return "操作未完成，请重试。阅读数据会保留；如有待清理的登录数据，请先完成清理。"
    }
}
