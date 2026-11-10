import Foundation
import Testing
import SnowlitCore
import SnowlitStorage
import YingxueKit
@testable import Snowlit

@Suite(.serialized)
@MainActor
struct SourceManagementModelTests {
    @Test func validationDoesNotInstallAndConfirmationPersistsOnlyTheSelectedGrant() async throws {
        try await withLibrary { path, library in
            let receipt = try await Self.stage(library)
            let model = Self.model(library)
            await model.prepare(importID: receipt.id)
            let candidate = try #require(model.candidate)
            #expect(candidate.requestsCredentialRead)
            #expect(try await library.sourceInstallations().isEmpty)
            await model.confirm(candidateID: UUID(), allowCredentialRead: true, restoreAssociation: false, configuration: [])
            #expect(try await library.sourceInstallations().isEmpty)
            await model.confirm(candidateID: candidate.id, allowCredentialRead: false, restoreAssociation: false, configuration: [])
            let installations = try await library.sourceInstallations()
            let installed = try #require(installations.first)
            #expect(installed.canExecute && !installed.allowsCredentialRead)
            #expect(installed.importID == receipt.id && model.candidate == nil && model.changed == 1)
            let reopened = try LibraryDatabase(existingAt: path)
            #expect(try await reopened.sourceInstallations() == installations)
            try await reopened.close()
        }
    }

    @Test func aGrantRequiresTheCandidateDeclaration() async throws {
        try await withLibrary { _, library in
            let receipt = try await Self.stage(library, credentials: false)
            let model = Self.model(library)
            await model.prepare(importID: receipt.id)
            let candidate = try #require(model.candidate)
            await model.confirm(candidateID: candidate.id, allowCredentialRead: true, restoreAssociation: false, configuration: [])
            #expect(model.problem != nil)
            #expect(try await library.sourceInstallations().isEmpty)
        }
    }

    @Test func validationUsesOnlyTheExplicitlyConfirmedConfigurationAndPermission() async throws {
        try await withLibrary { _, library in
            let receipt = try await Self.stage(library, withConfiguration: true)
            var observed: SourceManagementModel.ValidationRequest?
            let model = Self.model(library, validate: { request in observed = request; return nil })
            await model.prepare(importID: receipt.id)
            let candidate = try #require(model.candidate)
            #expect(observed == nil)
            #expect(candidate.configuration == [.text(key: "category", value: "all")])
            let confirmed: [SourceSettingValue] = [.text(key: "category", value: "fiction")]
            await model.confirm(candidateID: UUID(), allowCredentialRead: true, restoreAssociation: false, configuration: confirmed)
            #expect(observed == nil)
            await model.confirm(candidateID: candidate.id, allowCredentialRead: true, restoreAssociation: false, configuration: confirmed)
            let request = try #require(observed)
            #expect(request.candidate.id == candidate.id)
            #expect(request.candidate.script.sha256 == candidate.script.sha256)
            #expect(request.configuration == confirmed && request.allowCredentialRead)
            let installed = try await library.sourceInstallations()
            #expect(installed.first?.configuration == confirmed && installed.first?.allowsCredentialRead == true)
        }
    }

    @Test func invalidConfigurationCannotStartCandidateCode() async throws {
        try await withLibrary { _, library in
            let receipt = try await Self.stage(library, withConfiguration: true)
            var called = false
            let model = Self.model(library, validate: { _ in called = true; return nil })
            await model.prepare(importID: receipt.id)
            let candidate = try #require(model.candidate)
            await model.confirm(candidateID: candidate.id, allowCredentialRead: false, restoreAssociation: false,
                configuration: [.boolean(key: "category", value: true)])
            #expect(!called && model.problem != nil)
            #expect(try await library.sourceInstallations().isEmpty)
        }
    }

    @Test func updateStopsOldExecutionAndDoesNotInheritCredentialConsent() async throws {
        try await withLibrary { _, library in
            let current = try await Self.install(library, consent: .approvedForCandidate)
            let newer = try await Self.stage(library, version: 2)
            var invalidated: [SourceInstallationID] = []
            let model = Self.model(library, invalidate: { invalidated.append($0) })
            await model.prepare(importID: newer.id)
            let candidate = try #require(model.candidate)
            #expect(try await library.sourceInstallations() == [current])
            #expect(invalidated.isEmpty)
            await model.confirm(candidateID: candidate.id, allowCredentialRead: false, restoreAssociation: false, configuration: [])
            let installed = try await library.sourceInstallations()
            #expect(installed.first?.id == current.id && installed.first?.importID == newer.id)
            #expect(installed.first?.allowsCredentialRead == false)
            #expect(invalidated == [current.id])
        }
    }

    @Test func changedConfigurationRequiresEveryAcknowledgementAndPersistsConfirmedValues() async throws {
        try await withLibrary { path, library in
            let original = try await Self.stage(library, settings: #"[{"kind":"text","key":"keep","label":"Keep","initial":"old default"},{"kind":"boolean","key":"flag","label":"Flag","initial":false},{"kind":"choice","key":"valid","label":"Valid","initial":"a","choices":[{"value":"a","label":"A"},{"value":"b","label":"B"}]},{"kind":"text","key":"removed","label":"Removed","initial":"old"},{"kind":"boolean","key":"type","label":"Type","initial":false},{"kind":"choice","key":"choice","label":"Choice","initial":"a","choices":[{"value":"a","label":"A"},{"value":"b","label":"B"}]}]"#)
            let previous: [SourceSettingValue] = [.text(key: "keep", value: "personal"), .boolean(key: "flag", value: true),
                .text(key: "valid", value: "b"), .text(key: "removed", value: "retained until adoption"),
                .boolean(key: "type", value: true), .text(key: "choice", value: "b")]
            let current = try await library.installSource(importID: original.id, id: .init(), configuration: previous, consent: .managedOnly)
            let newer = try await Self.stage(library, version: 2, settings: #"[{"kind":"text","key":"keep","label":"Keep","initial":"new default"},{"kind":"boolean","key":"flag","label":"Flag","initial":false},{"kind":"choice","key":"valid","label":"Valid","initial":"a","choices":[{"value":"a","label":"A"},{"value":"b","label":"B"}]},{"kind":"text","key":"type","label":"New type","initial":"replacement"},{"kind":"choice","key":"choice","label":"Choice","initial":"c","choices":[{"value":"a","label":"A"},{"value":"c","label":"C"}]},{"kind":"text","key":"added","label":"Added","initial":"fresh"}]"#)
            var observed: [SourceManagementModel.ValidationRequest] = []
            var invalidated = false
            let model = Self.model(library, validate: { request in
                observed.append(request)
                return try request.candidate.plan?.validate(references: [], state: nil)
            }, invalidate: { _ in invalidated = true })
            await model.prepare(importID: newer.id)
            let candidate = try #require(model.candidate)
            let defaults: [SourceSettingValue] = [.text(key: "keep", value: "personal"), .boolean(key: "flag", value: true),
                .text(key: "valid", value: "b"), .text(key: "type", value: "replacement"),
                .text(key: "choice", value: "c"), .text(key: "added", value: "fresh")]
            #expect(candidate.configuration == defaults)
            #expect(candidate.configurationChanges.map(\.previous) == Array(previous.suffix(3)))
            #expect(candidate.configurationChanges.map(\.reason) == [.removed, .typeChanged, .choiceRemoved])
            #expect(candidate.configurationChanges.map(\.proposedDefault) == [nil, .text(key: "type", value: "replacement"), .text(key: "choice", value: "c")])
            let all = Set(candidate.configurationChanges.map(\.id))
            for acknowledgements in [Set<Data>(), Set([Data("removed".utf8)]), all.union([Data("unexpected".utf8)])] {
                await model.confirm(candidateID: candidate.id, allowCredentialRead: false, restoreAssociation: false,
                    configuration: defaults, acknowledgedConfigurationChanges: acknowledgements)
                #expect(observed.isEmpty && !invalidated && model.problem != nil)
                #expect(try await library.sourceInstallations() == [current])
            }
            let final = defaults.map { value in value.key == "type" ? .text(key: "type", value: "edited by owner") : value }
            await model.confirm(candidateID: candidate.id, allowCredentialRead: false, restoreAssociation: false,
                configuration: final, acknowledgedConfigurationChanges: all)
            #expect(model.problem == nil && model.candidate == nil && invalidated)
            #expect(observed.count == 1 && observed.first?.configuration == final)
            let installed = try await library.sourceInstallations()
            #expect(installed.first?.configuration == final && installed.first?.importID == newer.id)
            let reopened = try LibraryDatabase(existingAt: path)
            #expect(try await reopened.sourceInstallations() == installed)
            try await reopened.close()
        }
    }

    @Test(arguments: [false, true])
    func textAndChoiceKindChangesRequireReviewEvenWhenBothStoreText(choiceFirst: Bool) async throws {
        try await withLibrary { _, library in
            let text = #"[{"kind":"text","key":"category","label":"Category","initial":"all"}]"#
            let choice = #"[{"kind":"choice","key":"category","label":"Category","initial":"all","choices":[{"value":"all","label":"All"},{"value":"fiction","label":"Fiction"}]}]"#
            let original = try await Self.stage(library, settings: choiceFirst ? choice : text)
            _ = try await library.installSource(importID: original.id, id: .init(),
                configuration: [.text(key: "category", value: "fiction")], consent: .managedOnly)
            let newer = try await Self.stage(library, version: 2, settings: choiceFirst ? text : choice)
            let model = Self.model(library)
            await model.prepare(importID: newer.id)
            let candidate = try #require(model.candidate)
            #expect(candidate.configurationChanges.map(\.reason) == [.typeChanged])
            #expect(candidate.configurationChanges.first?.previous == .text(key: "category", value: "fiction"))
            #expect(candidate.configuration == [.text(key: "category", value: "all")])
        }
    }

    @Test func configurationReviewKeepsDistinctUTF8KeysDistinct() async throws {
        try await withLibrary { _, library in
            let original = try await Self.stage(library, settings: #"[{"kind":"text","key":"\u00e9","label":"First","initial":"one"},{"kind":"text","key":"e\u0301","label":"Second","initial":"two"}]"#)
            let current = try await library.installSource(importID: original.id, id: .init(),
                configuration: [.text(key: "\u{e9}", value: "one"), .text(key: "e\u{301}", value: "two")], consent: .managedOnly)
            let newer = try await Self.stage(library, version: 2)
            let model = Self.model(library)
            await model.prepare(importID: newer.id)
            let candidate = try #require(model.candidate)
            let ids = Set(candidate.configurationChanges.map(\.id))
            #expect(ids.count == 2)
            await model.confirm(candidateID: candidate.id, allowCredentialRead: false, restoreAssociation: false,
                configuration: [], acknowledgedConfigurationChanges: [Data("\u{e9}".utf8)])
            #expect(try await library.sourceInstallations() == [current])
            await model.confirm(candidateID: candidate.id, allowCredentialRead: false, restoreAssociation: false,
                configuration: [], acknowledgedConfigurationChanges: ids)
            #expect(model.problem == nil && model.candidate == nil)
            #expect(try await library.sourceInstallations().first?.configuration == [])
        }
    }

    @Test(arguments: ["cancel", "validation", "stale"])
    func unsuccessfulConfigurationUpgradePreservesOriginalSettings(outcome: String) async throws {
        try await withLibrary { path, library in
            let original = try await Self.stage(library, withConfiguration: true)
            let current = try await library.installSource(importID: original.id, id: .init(),
                configuration: [.text(key: "category", value: "my category")], consent: .approvedForCandidate)
            let newer = try await Self.stage(library, version: 2)
            let pending = PendingCandidateValidation()
            let model = Self.model(library, validate: { request in
                if outcome == "cancel" { await pending.run() }
                if outcome == "validation" { throw FixtureFailure.requested }
                if outcome == "stale" {
                    _ = try await library.addBook(reference: .init(installationID: current.id, referenceVersion: 1, key: "new"), title: "New", author: nil)
                }
                return try request.candidate.plan?.validate(references: [], state: nil)
            })
            await model.prepare(importID: newer.id)
            let candidate = try #require(model.candidate)
            let task = Task { await model.confirm(candidateID: candidate.id, allowCredentialRead: false,
                restoreAssociation: false, configuration: [],
                acknowledgedConfigurationChanges: Set(candidate.configurationChanges.map(\.id))) }
            if outcome == "cancel" {
                await pending.waitUntilStarted()
                model.cancelPreparation()
                pending.finish()
            }
            await task.value
            #expect(try await library.sourceInstallations() == [current])
            #expect(!model.isValidating && !model.isChanging && model.changed == 0)
            if outcome != "cancel" { #expect(model.problem != nil) }
            let reopened = try LibraryDatabase(existingAt: path)
            #expect(try await reopened.sourceInstallations() == [current])
            try await reopened.close()
        }
    }

    @Test func invalidOldSettingsAreNotSilentlyDiscardedDuringUpgrade() async throws {
        try await withLibrary { _, library in
            let original = try await Self.stage(library, withConfiguration: true)
            let current = try await library.installSource(importID: original.id, id: .init(),
                configuration: [.boolean(key: "category", value: true)], consent: .managedOnly)
            let newer = try await Self.stage(library, version: 2)
            let model = Self.model(library)
            await model.prepare(importID: newer.id)
            #expect(model.candidate == nil && model.problem != nil)
            #expect(try await library.sourceInstallations() == [current])
        }
    }

    @Test func failedRuntimeValidationPreservesTheActiveVersionAndConsent() async throws {
        try await withLibrary { _, library in
            let current = try await Self.install(library, consent: .approvedForCandidate)
            let newer = try await Self.stage(library, version: 2)
            let model = Self.model(library, validate: { _ in throw FixtureFailure.requested })
            await model.prepare(importID: newer.id)
            let candidate = try #require(model.candidate)
            await model.confirm(candidateID: candidate.id, allowCredentialRead: true, restoreAssociation: false, configuration: [])
            #expect(model.candidate?.id == candidate.id && model.problem != nil)
            #expect(try await library.sourceInstallations() == [current])
        }
    }

    @Test func restoringRequiresFreshConfirmationAndKeepsLocalIdentity() async throws {
        try await withLibrary { _, library in
            let current = try await Self.install(library, consent: .approvedForCandidate)
            let book = try await library.addBook(reference: .init(installationID: current.id, referenceVersion: 1, key: "book"), title: "Local book", author: nil)
            let removed = try await library.removeSource(expected: current)
            let cleanup = try #require(removed.pendingCleanup)
            #expect(try await library.finishSourceSessionCleanup(cleanup, installationID: current.id))
            let receipt = try await Self.stage(library)
            let model = Self.model(library)
            await model.prepare(importID: receipt.id)
            let candidate = try #require(model.candidate)
            #expect(candidate.restoresAssociation && candidate.retainedBooks == 1)
            await model.confirm(candidateID: candidate.id, allowCredentialRead: false, restoreAssociation: false, configuration: [])
            #expect(try await library.sourceInstallations().first?.state == .removed)
            await model.confirm(candidateID: candidate.id, allowCredentialRead: false, restoreAssociation: true, configuration: [])
            let installed = try await library.sourceInstallations()
            #expect(installed.first?.id == current.id && installed.first?.canExecute == true)
            #expect(installed.first?.allowsCredentialRead == false)
            #expect(try await library.books() == [book])
        }
    }

    @Test func changedReadingInventoryRejectsTheOldPreparedCandidate() async throws {
        try await withLibrary { _, library in
            let current = try await Self.install(library)
            let newer = try await Self.stage(library, version: 2)
            let pending = PendingCandidateValidation()
            let model = Self.model(library, validate: { request in
                await pending.run()
                return try request.candidate.plan?.validate(references: [], state: nil)
            })
            await model.prepare(importID: newer.id)
            let candidate = try #require(model.candidate)
            let task = Task { await model.confirm(candidateID: candidate.id, allowCredentialRead: false,
                restoreAssociation: false, configuration: []) }
            await pending.waitUntilStarted()
            let book = try await library.addBook(reference: .init(installationID: current.id, referenceVersion: 1, key: "added-later"), title: "New local book", author: nil)
            pending.finish()
            await task.value
            #expect(model.candidate == nil && model.problem != nil)
            #expect(try await library.sourceInstallations() == [current])
            #expect(try await library.books() == [book])
        }
    }

    @Test func cancelledValidationCannotAdoptAfterDismissal() async throws {
        try await withLibrary { _, library in
            let receipt = try await Self.stage(library)
            let pending = PendingCandidateValidation()
            var backendWasCancelled = false
            let model = Self.model(library, validate: { _ in
                await pending.run()
                backendWasCancelled = Task.isCancelled
                return nil
            })
            await model.prepare(importID: receipt.id)
            let candidate = try #require(model.candidate)
            let task = Task { await model.confirm(candidateID: candidate.id, allowCredentialRead: false,
                restoreAssociation: false, configuration: []) }
            await pending.waitUntilStarted()
            model.cancelPreparation()
            pending.finish()
            await task.value
            #expect(backendWasCancelled)
            #expect(model.candidate == nil && !model.isPreparing && !model.isValidating && !model.isChanging && model.problem == nil)
            #expect(try await library.sourceInstallations().isEmpty)
        }
    }

    @Test func lateCancelledValidationCannotReplaceANewerConfirmation() async throws {
        try await withLibrary { _, library in
            let receipt = try await Self.stage(library)
            let pending = PendingCandidateValidation()
            var calls = 0
            let model = Self.model(library, validate: { _ in
                calls += 1
                if calls == 1 { await pending.run() }
                return nil
            })
            await model.prepare(importID: receipt.id)
            let first = try #require(model.candidate)
            let task = Task { await model.confirm(candidateID: first.id, allowCredentialRead: true,
                restoreAssociation: false, configuration: []) }
            await pending.waitUntilStarted()
            model.cancelPreparation()
            await model.prepare(importID: receipt.id)
            let second = try #require(model.candidate)
            #expect(second.id != first.id && second.installationID != first.installationID)
            await model.confirm(candidateID: second.id, allowCredentialRead: false, restoreAssociation: false, configuration: [])
            pending.finish()
            await task.value
            let installed = try await library.sourceInstallations()
            #expect(installed.count == 1 && installed.first?.id == second.installationID)
            #expect(installed.first?.allowsCredentialRead == false)
            #expect(calls == 2 && model.changed == 1 && model.problem == nil)
            #expect(!model.isValidating && !model.isChanging)
        }
    }

    @Test func removalCleanupFailureRemainsBlockedAndRetriesTheSameToken() async throws {
        try await withLibrary { _, library in
            let current = try await Self.install(library)
            let book = try await library.addBook(reference: .init(installationID: current.id, referenceVersion: 1, key: "retained"), title: "Retained", author: nil)
            var attempted: [SourceSessionCleanup] = []
            let model = Self.model(library, cleanup: { _, token in
                attempted.append(token)
                if attempted.count == 1 { throw FixtureFailure.requested }
            })
            await model.perform(.remove, expected: current)
            let removedList = try await library.sourceInstallations()
            let removed = try #require(removedList.first)
            #expect(removed.state == .removed && removed.pendingCleanup != nil && !removed.canExecute)
            #expect(model.problem != nil)
            await model.prepare(importID: current.importID)
            #expect(model.candidate == nil)
            await model.perform(.retryCleanup, expected: removed)
            #expect(attempted.count == 2 && attempted[0] == attempted[1])
            let cleaned = try await library.sourceInstallations()
            #expect(cleaned.first?.pendingCleanup == nil && cleaned.first?.state == .removed)
            #expect(try await library.books() == [book])
        }
    }

    @Test func staleManagementActionCannotReenableANewerDisabledVersion() async throws {
        try await withLibrary { _, library in
            let current = try await Self.install(library)
            let disabled = try await library.setSourceEnabled(false, expected: current)
            let model = Self.model(library)
            await model.perform(.enable, expected: current)
            #expect(model.problem != nil)
            #expect(try await library.sourceInstallations() == [disabled])
        }
    }

    private enum FixtureFailure: Error { case requested }

    private static func model(_ library: LibraryDatabase,
        validate: @escaping SourceManagementModel.Validator = { request in try request.candidate.plan?.validate(references: [], state: nil) },
        invalidate: @escaping @MainActor (SourceInstallationID) async -> Void = { _ in },
        cleanup: @escaping @MainActor (SourceInstallationID, SourceSessionCleanup) async throws -> Void = { _, _ in }) -> SourceManagementModel {
        .init(openLibrary: { library }, digest: digest, validate: validate, invalidate: invalidate, cleanup: cleanup)
    }

    private static func install(_ library: LibraryDatabase, consent: SnowlitCore.SourceCredentialReadConsent = .managedOnly) async throws -> SourceInstallationSnapshot {
        let receipt = try await stage(library)
        return try await library.installSource(importID: receipt.id, id: .init(), configuration: [], consent: consent)
    }

    nonisolated private static let digest: SourceScriptSnapshot.Digest = { data in
        String(repeating: String(decoding: data, as: UTF8.self).contains("\"scriptVersion\":\"2\"") ? "b" : "a", count: 64)
    }

    private static func stage(_ library: LibraryDatabase, version: Int = 1, credentials: Bool = true,
                              withConfiguration: Bool = false, settings: String? = nil) async throws -> SourceImportRecord {
        let configuration = settings ?? (withConfiguration ? #"[{"kind":"text","key":"category","label":"Category","initial":"all"}]"# : "[]")
        let bytes = Data("""
            /* @yingxue
            {"protocolVersion":1,"sourceID":"org.example.management","name":"Fixture","scriptVersion":"\(version)","referenceVersion":1,"stateVersion":1,"capabilities":\(credentials ? "[\"credentials.read\"]" : "[]"),"origins":[],"authentication":[],"publicConfiguration":\(configuration)}
            */
            export async function search(ctx, input) {}
            export async function book(ctx, input) {}
            export async function chapters(ctx, input) {}
            export async function chapter(ctx, input) {}
            """.utf8)
        let script = try SourceImportPreview(bytes: bytes).acceptInspection(
            Data(#"{"kind":"accepted","exports":["search","book","chapters","chapter"]}"#.utf8), digest: digest)
        let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: YingxueWire.schemaSHA256,
            fileName: "fixture.js", importedAt: Date())
        try await library.stageSourceScript(script, receipt: receipt)
        return receipt
    }

    private func withLibrary(_ body: (URL, LibraryDatabase) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitManagement-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error, "Unable to remove isolated management data") }
        }
        let path = directory.appendingPathComponent("library.sqlite")
        let library = try LibraryDatabase.create(at: path)
        do { try await body(path, library); try await library.close() }
        catch {
            do { try await library.close() } catch { Issue.record(error, "Unable to close management fixture") }
            throw error
        }
    }
}

@MainActor
private final class PendingCandidateValidation {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var started = false
    func run() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true; observer?.resume(); observer = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
