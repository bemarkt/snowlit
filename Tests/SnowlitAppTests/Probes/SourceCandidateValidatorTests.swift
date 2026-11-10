import CryptoKit
import Foundation
import SnowlitCore
import SnowlitStorage
import SwiftUI
import Testing
import UIKit
import WebKit
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
            let result = try await retry.value
            #expect(result == nil)
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

    @Test func installedRuntimeAuthenticatesWithNativeFormPersistsCookiesAndSignsOutWithoutChangingBooks() async throws {
        try await FixtureScenario.withScenario { fixture in
            let (status, bytes) = try await fixture.request("author.source.js")
            #expect(status == 200)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitInstalledRuntime-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: directory) }
                catch { Issue.record(error, "Unable to remove installed-runtime fixture") }
            }
            let library = try LibraryDatabase.create(at: directory.appendingPathComponent("library.sqlite"))
            let runtime = SourceRuntime(openLibrary: { library }, digest: Self.digest)
            let cleaner = SourceCandidateValidator()
            var installed: SourceInstallationSnapshot?
            do {
                let preview = try SourceImportPreview(bytes: bytes)
                let inspected = try await SourceFileInspector.inspect(preview.header.source,
                    requirements: SourceModuleInspection.requirements(for: preview.header.manifest))
                let script = try preview.acceptInspection(inspected, digest: Self.digest)
                let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: YingxueWire.schemaSHA256,
                    fileName: "author.source.js", importedAt: Date())
                try await library.stageSourceScript(script, receipt: receipt)
                let current = try await library.installSource(importID: receipt.id, id: .init(), configuration: [], consent: .managedOnly)
                installed = current
                let book = try await library.addBook(reference: .init(installationID: current.id, referenceVersion: 1, key: "book"),
                    title: "Local retained book", author: nil)
                let login = YingxueWire.OperationInput.authenticate(.init(kind: .authenticate, input: .init(reason: .signIn)))
                let cancelled = try await invoke(runtime, input: login, expected: current, form: { await $0.cancel() })
                guard case .failure(let failure) = cancelled else { throw FixtureScenario.Failure.invalidResponse }
                #expect(failure.error.code == .cancelled)
                let reply = try await invoke(runtime, input: login, expected: current, form: { form in
                    form.setValue("fixture-password", for: "password")
                    await form.submit()
                })
                guard case .authenticate(let authentication) = reply else { throw FixtureScenario.Failure.invalidResponse }
                #expect(authentication.value.status == .authenticated)
                let chapter = YingxueWire.OperationInput.chapter(.init(kind: .chapter,
                    input: .init(reference: .init(book: .init(key: "book"), key: "c1"))))
                let protected = try await invoke(runtime, input: chapter, expected: current)
                guard case .chapter = protected else { throw FixtureScenario.Failure.invalidResponse }
                #expect(try await library.books() == [book])
                let management = SourceManagementModel(openLibrary: { library }, digest: Self.digest,
                    validate: { _ in throw FixtureScenario.Failure.invalidResponse },
                    invalidate: { try await runtime.invalidate($0) }, cleanup: { try await cleaner.cleanup($0, token: $1) })
                let signedOutResult = await management.perform(.signOut, expected: current)
                let signedOut = try #require(signedOutResult)
                installed = signedOut
                #expect(signedOut.websiteSessionID != current.websiteSessionID && signedOut.id == current.id)
                #expect(signedOut.pendingCleanup == nil && management.problem == nil)
                // Cleanup retries use the exact deleted ID and must not create
                // a fresh network session or alter the replacement store.
                try await cleaner.cleanup(current.id, token: .init(websiteSessionID: current.websiteSessionID))
                let anonymous = try await invoke(runtime, input: chapter, expected: signedOut)
                guard case .failure(let anonymous) = anonymous else { throw FixtureScenario.Failure.invalidResponse }
                #expect(anonymous.error.code == .needsAuthentication)
                #expect(try await library.books() == [book])
                let webSource = String(decoding: bytes, as: UTF8.self)
                    .replacingOccurrences(of: "\"scriptVersion\": \"1\"", with: "\"scriptVersion\": \"2\"")
                    .replacingOccurrences(of: "[\"http\", \"dom\"]", with: "[\"http\", \"dom\", \"browser\"]")
                    .replacingOccurrences(of: "[\"form\"]", with: "[\"web\"]")
                    .replacingOccurrences(of: "export async function authenticate", with: "async function oldAuthenticate") + """
                    \nexport async function authenticate(ctx, input) {
                      await ctx.interact({kind: 'web', title: 'Website verification', purpose: 'signIn',
                        target: {url: '\(fixture.url("page").absoluteString)'}});
                      return {status: 'anonymous'};
                    }
                    """
                let webPreview = try SourceImportPreview(bytes: Data(webSource.utf8))
                let webInspection = try await SourceFileInspector.inspect(webPreview.header.source,
                    requirements: SourceModuleInspection.requirements(for: webPreview.header.manifest))
                let webScript = try webPreview.acceptInspection(webInspection, digest: Self.digest)
                let webReceipt = try SourceImportRecord(scriptSHA256: webScript.sha256, inspectionContractSHA256: YingxueWire.schemaSHA256,
                    fileName: "web.source.js", importedAt: Date())
                try await library.stageSourceScript(webScript, receipt: webReceipt)
                let webInstalled = try await library.updateSource(importID: webReceipt.id, replacing: signedOut,
                    configuration: [], consent: .managedOnly)
                installed = webInstalled
                let completed = try await invoke(runtime, input: login, expected: webInstalled, web: { $0.complete() })
                guard case .authenticate(let completed) = completed else { throw FixtureScenario.Failure.invalidResponse }
                #expect(completed.value.status == .anonymous)
                await #expect(throws: CancellationError.self) {
                    try await invoke(runtime, input: login, expected: webInstalled, web: { _ in runtime.cancel() })
                }
                #expect(runtime.active == nil)
                #expect(try await library.books() == [book])
                try await runtime.invalidate(webInstalled.id)
                try await cleaner.cleanup(webInstalled.id, token: .init(websiteSessionID: webInstalled.websiteSessionID))
                try await library.close()
            } catch {
                if let installed {
                    do {
                        try await runtime.invalidate(installed.id)
                        try await cleaner.cleanup(installed.id, token: .init(websiteSessionID: installed.websiteSessionID))
                    } catch { Issue.record(error, "Installed-runtime session cleanup failed") }
                }
                do { try await library.close() } catch { Issue.record(error, "Installed-runtime database cleanup failed") }
                throw error
            }
        }
    }

    private func invoke(_ runtime: SourceRuntime, input: YingxueWire.OperationInput, expected: SourceInstallationSnapshot,
                        form action: (@MainActor (SourceFormModel) async -> Void)? = nil,
                        web webAction: (@MainActor (SourceWebInteraction) -> Void)? = nil) async throws -> YingxueWire.OperationReply {
        let work = Task { try await runtime.invoke(input, expected: expected) }
        try await FixtureScenario.eventually { runtime.active != nil }
        let session = try #require(runtime.active)
        let websiteLifetime = WebsiteLifetime(session.websiteDataStore)
        #expect(websiteLifetime.store != nil)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(scenes.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SourceExecutionView(session: session,
            cancel: { runtime.cancel() }, retryCleanup: { try await runtime.retryCleanup() }))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        var retainedWebInteraction: SourceWebInteraction?
        weak var presentedPage: WKWebView?
        do {
            if let action {
                try await FixtureScenario.eventually { session.formSession?.form != nil }
                let form = try #require(session.formSession?.form)
                await action(form)
            }
            if let webAction {
                try await FixtureScenario.eventually { session.webInteraction != nil }
                let interaction = try #require(session.webInteraction)
                retainedWebInteraction = interaction
                presentedPage = interaction.container.subviews.first as? WKWebView
                #expect(presentedPage != nil)
                webAction(interaction)
            }
            let reply = try await work.value
            #expect(runtime.active == nil && session.phase == .finished)
            #expect(session.websiteDataStore == nil && websiteLifetime.store == nil)
            if let retainedWebInteraction {
                #expect(retainedWebInteraction.container.subviews.isEmpty && presentedPage == nil)
            }
            return reply
        } catch {
            do { try await runtime.invalidate(expected.id) }
            catch { Issue.record(error, "Installed operation cleanup failed") }
            _ = await work.result
            #expect(session.websiteDataStore == nil && websiteLifetime.store == nil)
            if let retainedWebInteraction {
                #expect(retainedWebInteraction.container.subviews.isEmpty && presentedPage == nil)
            }
            throw error
        }
    }

    nonisolated private static let digest: SourceScriptSnapshot.Digest = {
        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private final class WebsiteLifetime {
        weak var store: WKWebsiteDataStore?
        init(_ store: WKWebsiteDataStore?) { self.store = store }
    }

    private func activeSession(_ validator: SourceCandidateValidator) async throws -> SourceExecutionSession {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while validator.active == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(validator.active)
    }

    private func withPresentation(_ validator: SourceCandidateValidator, session: SourceExecutionSession,
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
