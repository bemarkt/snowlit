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
    private(set) var active: SourceCandidateSession?
    @ObservationIgnored private var work: Task<SourceUpdateMigrationValues?, any Error>?

    func validate(_ request: SourceManagementModel.ValidationRequest) async throws -> SourceUpdateMigrationValues? {
        guard active == nil else { throw Failure.busy }
        let session = try SourceCandidateSession(request: request)
        active = session
        let task = Task { @MainActor in try await session.run() }
        work = task
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        do { try await session.close() }
        catch { throw Failure.cleanupRequired }
        if active === session { active = nil; work = nil }
        try Task.checkCancellation()
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
        // Exact cleanup token remains in Storage until this awaited operation
        // succeeds. Creating the named store also makes a retry after deletion
        // idempotent, without touching another website-session identifier.
        let task = Task { @MainActor in
            let store = WKWebsiteDataStore(forIdentifier: token.websiteSessionID)
            let website = SourceWebsiteSession(dataStore: store)
            try await website.erase()
            try await WKWebsiteDataStore.remove(forIdentifier: token.websiteSessionID)
            try await KeychainCredentialStore().removeAll(for: installation)
        }
        try await task.value
    }
}

@MainActor
@Observable
final class SourceCandidateSession: Identifiable {
    enum Phase { case waitingForView, validating, cleanupRequired, finished }
    enum Failure: Error { case unavailable, rejected, cleanupRequired }
    let id = UUID()
    let installationID: SourceInstallationID
    let sourceName: String
    let sourceID: String
    private(set) var phase: Phase = .waitingForView
    private(set) var formSession: SourceFormSession?
    private(set) var webInteraction: SourceWebInteraction?
    @ObservationIgnored private let request: SourceManagementModel.ValidationRequest
    @ObservationIgnored private let worker: SourceWorkerSession
    @ObservationIgnored private let gate: SourceOperationGate
    @ObservationIgnored private let policy: SourceHostPolicy
    @ObservationIgnored private let configuration: SourceConfiguration
    @ObservationIgnored private let workspace: SourceCandidateWorkspace
    @ObservationIgnored private let website = SourceWebsiteSession(dataStore: .nonPersistent())
    @ObservationIgnored private var host: SourceNativeHost?
    @ObservationIgnored private weak var container: UIView?
    @ObservationIgnored private var mountWaiter: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var closing: Task<Void, any Error>?
    @ObservationIgnored private var closed = false

    init(request: SourceManagementModel.ValidationRequest) throws {
        self.request = request
        let candidate = request.candidate
        installationID = candidate.installationID; sourceName = candidate.manifest.name; sourceID = candidate.manifest.sourceID
        worker = SourceWorkerSession(program: try .init())
        policy = try .init(installationID: installationID, scriptSHA256: candidate.script.sha256, manifest: candidate.manifest)
        configuration = try .init(policy: policy, revision: 0, saved: request.configuration)
        let consent: YingxueKit.SourceCredentialReadConsent? = request.allowCredentialRead
            ? try .init(confirmedFor: installationID, scriptSHA256: candidate.script.sha256) : nil
        let credentials = try SourceCredentialPolicy(installationID: installationID, scriptSHA256: candidate.script.sha256,
            manifest: candidate.manifest, consent: consent)
        gate = try .init(installationID: installationID, scriptSHA256: candidate.script.sha256,
            configurationRevision: 0, sessionRevision: 0, credentialPolicy: credentials)
        let state = try candidate.prepared?.targetState ?? SourcePublicState(stateVersion: candidate.manifest.stateVersion, revision: 0, entries: [])
        workspace = .init(installationID: installationID, state: state)
    }

    func attach(to view: UIView) {
        guard !closed else { return }
        container = view
        mount(worker.webView)
        guard view.window != nil else { return }
        mountWaiter?.resume(); mountWaiter = nil
    }

    func run() async throws -> SourceUpdateMigrationValues? {
        try await waitForMount()
        phase = .validating
        try await worker.prepare(script: request.candidate.script, upgrade: request.candidate.upgrade)
        guard let plan = request.candidate.plan else { return nil }
        var references: [YingxueWire.ReferenceMigrationResult] = []
        var state: YingxueWire.StateMigrationResult?
        for input in plan.referenceInputs {
            let reply = try await execute(.migrateReferences(.init(kind: .migrateReferences, input: input)))
            guard case .migrateReferences(let value) = reply else { throw Failure.rejected }
            references.append(value.value)
        }
        if let input = plan.stateInput {
            let reply = try await execute(.migrateState(.init(kind: .migrateState, input: input)))
            guard case .migrateState(let value) = reply else { throw Failure.rejected }
            state = value.value
        }
        return try plan.validate(references: references, state: state)
    }

    func close() async throws {
        if let closing { return try await closing.value }
        if phase == .finished { return }
        closed = true
        mountWaiter?.resume(throwing: CancellationError()); mountWaiter = nil
        webInteraction?.cancel()
        let task = Task { @MainActor [self] in
            await gate.close()
            var failed = false
            if let formSession { do { try await formSession.cancel() } catch { failed = true } }
            if let host { do { try await host.close() } catch { failed = true } }
            do { try await website.erase() } catch { failed = true }
            do { try await worker.close() } catch { failed = true }
            await workspace.close()
            if failed { throw Failure.cleanupRequired }
            formSession = nil; webInteraction = nil; host = nil; container = nil
        }
        closing = task
        defer { closing = nil }
        do { try await task.value; phase = .finished }
        catch { phase = .cleanupRequired; throw Failure.cleanupRequired }
    }

    private func execute(_ input: YingxueWire.OperationInput) async throws -> YingxueWire.OperationReply {
        guard !closed else { throw Failure.unavailable }
        let ticket = try await gate.begin(input)
        let forms = SourceFormSession(gate: gate, ticket: ticket, store: workspace, sourceName: sourceName, sourceID: sourceID)
        let native = SourceNativeHost(gate: gate, ticket: ticket, policy: policy, configuration: configuration,
            website: website, credentials: workspace, mount: { [weak self] view in self?.mount(view) },
            interact: { [self] request in try await present(request, forms: forms, ticket: ticket) },
            readState: { [workspace] request in try await workspace.readState(request) },
            writeState: { [workspace] request in try await workspace.writeState(request) })
        formSession = forms; host = native
        let reply = try await forms.run { [self] in
            let reply = try await worker.invoke(ticket, gate: gate, policy: policy) { try await native.reply(to: $0) }
            try await native.close()
            return reply
        }
        formSession = nil; host = nil
        return reply
    }

    private func present(_ request: YingxueWire.InteractionRequest, forms: SourceFormSession,
                         ticket: SourceOperationGate.Ticket) async throws -> YingxueWire.InteractionResult {
        let presentation = try await gate.beginInteraction(request, for: ticket, policy: policy)
        switch request {
        case .form: return try await forms.present(presentation)
        case .web(let request):
            guard let host, !closed else { throw Failure.unavailable }
            let page = try await host.browser.open(.init(target: request.target))
            guard let view = host.browser.webView(for: page.page.id), !closed else { throw Failure.unavailable }
            let interaction = SourceWebInteraction(title: request.title, sourceName: sourceName, view: view)
            webInteraction = interaction
            defer { if webInteraction === interaction { webInteraction = nil } }
            let result = try await interaction.response()
            try await gate.check(ticket)
            _ = try await host.browser.closePage(.init(id: page.page.id))
            return try await gate.completeInteraction(.init(id: presentation.id, result: result), for: ticket)
        }
    }

    private func mount(_ view: WKWebView) {
        guard !closed, let container else { return }
        view.frame = container.bounds; view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if view.superview !== container { container.addSubview(view) }
    }

    private func waitForMount() async throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure.unavailable }
        if worker.webView.window != nil { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled, !closed else { continuation.resume(throwing: CancellationError()); return }
                mountWaiter = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.mountWaiter?.resume(throwing: CancellationError()); self?.mountWaiter = nil
            }
        }
        try Task.checkCancellation()
    }
}

@MainActor
@Observable
final class SourceWebInteraction: Identifiable {
    let id = UUID()
    let title: String
    let sourceName: String
    let view: WKWebView
    private(set) var finished = false
    @ObservationIgnored private var result: YingxueWire.InteractionResult?
    @ObservationIgnored private var waiter: CheckedContinuation<YingxueWire.InteractionResult, Never>?

    init(title: String, sourceName: String, view: WKWebView) { self.title = title; self.sourceName = sourceName; self.view = view }
    func complete() { settle(.completed(.init(kind: .completed))) }
    func cancel() { settle(.cancelled(.init(kind: .cancelled))) }
    func response() async throws -> YingxueWire.InteractionResult {
        try Task.checkCancellation()
        let value = await withTaskCancellationHandler {
            if let result { return result }
            return await withCheckedContinuation { waiter = $0 }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        try Task.checkCancellation()
        return value
    }
    private func settle(_ value: YingxueWire.InteractionResult) {
        guard !finished else { return }
        finished = true; result = value; waiter?.resume(returning: value); waiter = nil
    }
}
#endif
