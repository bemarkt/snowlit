import CryptoKit
import Foundation
import SnowlitCore
import SwiftUI
import Testing
import UIKit
import YingxueKit
@testable import Snowlit

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct SourceCandidateValidatorTests {
    @Test func nativePresentationMountsAndReleasesAValidCandidate() async throws {
        let validator = SourceCandidateValidator()
        let request = try request()
        let work = Task { try await validator.validate(request) }
        let session = try await activeSession(validator)
        try await withPresentation(validator, session: session) {
            let result = try await work.value
            #expect(result == nil && validator.active == nil)
            #expect(session.phase == .finished)
        }
    }

    @Test func cancellingBeforePresentationCannotLeaveAValidationOwner() async throws {
        let validator = SourceCandidateValidator()
        let work = Task { try await validator.validate(request()) }
        let session = try await activeSession(validator)
        #expect(session.phase == .waitingForView)
        validator.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(validator.active == nil && session.phase == .finished)
    }

    @Test func rejectedModuleClosesBeforeAnotherCandidateCanStart() async throws {
        let validator = SourceCandidateValidator()
        let work = Task { try await validator.validate(request(extra: "throw new Error('rejected candidate');")) }
        let session = try await activeSession(validator)
        try await withPresentation(validator, session: session) {
            await #expect(throws: (any Error).self) { try await work.value }
            #expect(validator.active == nil && session.phase == .finished)
        }
        let retry = Task { try await validator.validate(request()) }
        let next = try await activeSession(validator)
        try await withPresentation(validator, session: next) {
            #expect(try await retry.value == nil)
            #expect(validator.active == nil && next.phase == .finished)
        }
    }

    @Test func migrationUsesConfirmedConfigurationAndDisposableState() async throws {
        let validator = SourceCandidateValidator()
        let request = try request(extra: """
            export async function migrateState(ctx, input) {
              const config = await ctx.readConfiguration({});
              const before = await ctx.readPublicState({stateVersion: 2});
              const changed = await ctx.writePublicState({stateVersion: 2,
                expectedRevision: before.revision, entries: [{key: 'temporary', value: 'discard'}]});
              if (!changed.written) throw new Error('candidate CAS failed');
              return {fromVersion: input.fromVersion, toVersion: input.toVersion,
                expectedRevision: input.snapshot.revision,
                entries: [{key: 'selected', value: config.values[0].value}]};
            }
            """, upgrade: true)
        let original = try #require(request.candidate.prepared)
        let work = Task { try await validator.validate(request) }
        let session = try await activeSession(validator)
        try await withPresentation(validator, session: session) {
            let result = try await work.value
            #expect(result?.state?.stateVersion == 2)
            #expect(result?.state?.entries == [try SourcePublicStateEntry(key: "selected", value: "confirmed")])
            #expect(original.currentState.revision == 4 && original.currentState.entries.first?.value == "retained")
            #expect(original.targetState.entries.isEmpty && original.targetState.revision == 0)
            #expect(validator.active == nil && session.phase == .finished)
        }
    }

    private func activeSession(_ validator: SourceCandidateValidator) async throws -> SourceCandidateSession {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while validator.active == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(validator.active)
    }

    private func withPresentation(_ validator: SourceCandidateValidator, session: SourceCandidateSession,
                                  body: () async throws -> Void) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(scenes.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SourceCandidateView(validator: validator, session: session))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        do { try await body() }
        catch {
            do { try await validator.invalidate(session.installationID) }
            catch { Issue.record(error, "Candidate owner cleanup failed") }
            throw error
        }
    }

    private func request(extra: String = "", upgrade: Bool = false) throws -> SourceManagementModel.ValidationRequest {
        let version = upgrade ? 2 : 1
        let bytes = Data("""
            /* @yingxue
            {"protocolVersion":1,"sourceID":"org.example.candidate","name":"Candidate fixture","scriptVersion":"\(version)","referenceVersion":1,"stateVersion":\(version),"capabilities":["publicState"],"origins":[],"authentication":[],"publicConfiguration":[{"kind":"text","key":"choice","label":"Choice","initial":"default"}]}
            */
            export async function search(ctx, input) { return {items: [], nextCursor: null}; }
            export async function book(ctx, input) { throw new Error('unused'); }
            export async function chapters(ctx, input) { throw new Error('unused'); }
            export async function chapter(ctx, input) { throw new Error('unused'); }
            \(extra)
            """.utf8)
        let preview = try SourceImportPreview(bytes: bytes)
        let exports = ["search", "book", "chapters", "chapter"] + (upgrade ? ["migrateState"] : [])
        let inspected = try JSONSerialization.data(withJSONObject: ["kind": "accepted", "exports": exports])
        let script = try preview.acceptInspection(inspected) { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: YingxueWire.schemaSHA256,
            fileName: "candidate.js", importedAt: Date())
        let installation = SourceInstallationID()
        let prepared: SourceUpdateSnapshot?
        let assessment: SourceUpgradeAssessment?
        if upgrade {
            let oldMetadata = try SourceScriptMetadata(sourceID: script.metadata.sourceID, name: script.metadata.name,
                scriptVersion: "1", protocolVersion: 1, referenceVersion: 1, stateVersion: 1)
            let old = try SourceInstallationSnapshot(id: installation, importID: UUID(), scriptSHA256: String(repeating: "a", count: 64),
                metadata: oldMetadata, revision: 1, state: .enabled, configuration: [], allowsCredentialRead: false,
                websiteSessionID: UUID(), pendingCleanup: nil)
            prepared = try .init(installation: old, candidate: receipt, candidateMetadata: script.metadata, inventoryRevision: 0,
                books: [], currentState: .init(stateVersion: 1, revision: 4, entries: [.init(key: "original", value: "retained")]),
                targetState: .init(stateVersion: 2, revision: 0, entries: []))
            assessment = try .init(current: request().candidate.manifest, candidate: preview.header.manifest)
        } else { prepared = nil; assessment = nil }
        let configuration: [SourceSettingValue] = [.text(key: "choice", value: "confirmed")]
        let candidate = SourceManagementModel.Candidate(installationID: installation, receipt: receipt, script: script,
            manifest: preview.header.manifest, existing: prepared?.installation, prepared: prepared, upgrade: assessment,
            plan: try prepared.map(SourceUpdateMigrationPlan.init), configuration: configuration, configurationChanges: [])
        return .init(candidate: candidate, configuration: configuration, allowCredentialRead: false)
    }
}
