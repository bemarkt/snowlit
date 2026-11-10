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
final class SourceExecutionSession: Identifiable {
    enum Phase { case waitingForView, validating, cleanupRequired, finished }
    enum Failure: Error { case unavailable, rejected, cleanupRequired }
    let id = UUID()
    let installationID: SourceInstallationID
    let sourceName: String
    let sourceID: String
    var isCandidate: Bool { request != nil }
    private(set) var phase: Phase = .waitingForView
    private(set) var formSession: SourceFormSession?
    private(set) var webInteraction: SourceWebInteraction?
    @ObservationIgnored private let request: SourceManagementModel.ValidationRequest?
    @ObservationIgnored private let installation: SourceInstallationSnapshot?
    @ObservationIgnored private let library: LibraryDatabase?
    @ObservationIgnored private let script: SourceScriptSnapshot
    @ObservationIgnored private let manifest: YingxueWire.Manifest
    @ObservationIgnored private let worker: SourceWorkerSession
    @ObservationIgnored private let gate: SourceOperationGate
    @ObservationIgnored private let policy: SourceHostPolicy
    @ObservationIgnored private let configuration: SourceConfiguration
    @ObservationIgnored private let workspace: SourceCandidateWorkspace?
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let website: SourceWebsiteSession
    @ObservationIgnored private var stateAccess: SourcePublicStateAccess?
    @ObservationIgnored private var revocation: Task<Void, any Error>?
    @ObservationIgnored private var host: SourceNativeHost?
    @ObservationIgnored private weak var container: UIView?
    @ObservationIgnored private var mountWaiter: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var closing: Task<Void, any Error>?
    @ObservationIgnored private var closed = false

    init(request: SourceManagementModel.ValidationRequest) throws {
        self.request = request
        let candidate = request.candidate
        installation = nil; library = nil; script = candidate.script; manifest = candidate.manifest
        website = SourceWebsiteSession(dataStore: .nonPersistent())
        installationID = candidate.installationID; sourceName = candidate.manifest.name; sourceID = candidate.manifest.sourceID
        worker = SourceWorkerSession(program: try .init())
        policy = try .init(installationID: installationID, scriptSHA256: candidate.script.sha256, manifest: candidate.manifest)
        configuration = try .init(policy: policy, revision: 0, saved: request.configuration)
        let consent: YingxueKit.SourceCredentialReadConsent? = request.allowCredentialRead
            ? try .init(confirmedFor: installationID, scriptSHA256: candidate.script.sha256) : nil
        let credentialPolicy = try SourceCredentialPolicy(installationID: installationID, scriptSHA256: candidate.script.sha256,
            manifest: candidate.manifest, consent: consent)
        gate = try .init(installationID: installationID, scriptSHA256: candidate.script.sha256,
            configurationRevision: 0, sessionRevision: 0, credentialPolicy: credentialPolicy)
        let state = try candidate.prepared?.targetState ?? SourcePublicState(stateVersion: candidate.manifest.stateVersion, revision: 0, entries: [])
        let workspace = SourceCandidateWorkspace(installationID: installationID, state: state)
        self.workspace = workspace; credentials = workspace
    }

    init(installation: SourceInstallationSnapshot, script: SourceScriptSnapshot, library: LibraryDatabase) throws {
        guard installation.canExecute, installation.scriptSHA256 == script.sha256,
              installation.metadata == script.metadata else { throw SourceInstallationFailure.staleInstallation }
        request = nil; workspace = nil
        self.installation = installation; self.library = library; self.script = script
        manifest = try SourceFileHeader(bytes: script.bytes).manifest
        installationID = installation.id; sourceName = manifest.name; sourceID = manifest.sourceID
        worker = SourceWorkerSession(program: try .init())
        policy = try .init(installationID: installationID, scriptSHA256: script.sha256, manifest: manifest)
        configuration = try .init(policy: policy, revision: installation.revision, saved: installation.configuration)
        let consent: YingxueKit.SourceCredentialReadConsent? = installation.allowsCredentialRead
            ? try .init(confirmedFor: installationID, scriptSHA256: script.sha256) : nil
        let credentialPolicy = try SourceCredentialPolicy(installationID: installationID, scriptSHA256: script.sha256,
            manifest: manifest, consent: consent)
        gate = try .init(installationID: installationID, scriptSHA256: script.sha256,
            configurationRevision: installation.revision, sessionRevision: installation.revision, credentialPolicy: credentialPolicy)
        credentials = try KeychainCredentialStore()
        website = SourceWebsiteSession(dataStore: WKWebsiteDataStore(forIdentifier: installation.websiteSessionID))
    }

    func attach(to view: UIView) {
        guard !closed else { return }
        container = view
        mount(worker.webView)
        guard view.window != nil else { return }
        mountWaiter?.resume(); mountWaiter = nil
    }

    func run() async throws -> SourceUpdateMigrationValues? {
        guard let request else { throw Failure.unavailable }
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

    /// The runtime owns and awaits this task before calling close. The exact
    /// installed snapshot is checked by Storage before any source code runs.
    func runOperation(_ input: YingxueWire.OperationInput) async throws -> YingxueWire.OperationReply {
        guard let installation, let library else { throw Failure.unavailable }
        guard input.operation != .migrateReferences && input.operation != .migrateState else { throw Failure.unavailable }
        try await waitForMount()
        stateAccess = try await library.beginInstalledPublicStateAccess(expected: installation)
        try Task.checkCancellation()
        // Form credentials are operation-scoped. This also removes orphaned
        // handles from an earlier process crash before creating new ones.
        try await credentials.removeAll(for: installationID)
        phase = .validating
        try await worker.prepare(script: script)
        return try await execute(input)
    }

    /// This finite task starts revocation immediately on native cancellation;
    /// close awaits it and also reclaims a permit acquired during preparation.
    func requestRevocation() {
        guard revocation == nil else { return }
        revocation = Task { @MainActor [self] in
            await gate.close()
            if let library, let stateAccess { try await library.revokePublicStateAccess(stateAccess) }
        }
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
            if let revocation {
                do { try await revocation.value } catch { failed = true }
                self.revocation = nil
            }
            if let library, let stateAccess {
                do { try await library.revokePublicStateAccess(stateAccess); self.stateAccess = nil }
                catch { failed = true }
            }
            if let formSession { do { try await formSession.cancel() } catch { failed = true } }
            if let host { do { try await host.close() } catch { failed = true } }
            if isCandidate { do { try await website.erase() } catch { failed = true } }
            else { await website.close() }
            do { try await worker.close() } catch { failed = true }
            await workspace?.close()
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
        let stateHost: SourcePublicStateHost?
        if let library, let stateAccess, manifest.capabilities.contains(.publicState) {
            guard let id = UUID(uuidString: ticket.call.context.requestID) else { throw Failure.unavailable }
            let operation = try await library.beginPublicStateOperation(requestID: id, using: stateAccess)
            stateHost = try .init(store: library, operation: operation, policy: policy)
        } else { stateHost = nil }
        let forms = SourceFormSession(gate: gate, ticket: ticket, store: credentials, sourceName: sourceName, sourceID: sourceID)
        let native = SourceNativeHost(gate: gate, ticket: ticket, policy: policy, configuration: configuration,
            website: website, credentials: credentials, mount: { [weak self] view in self?.mount(view) },
            interact: { [self] request in try await present(request, forms: forms, ticket: ticket) },
            readState: { [workspace, gate] request in
                if let workspace { return try await workspace.readState(request) }
                guard let stateHost else { throw SourceHostFailure.undeclaredCapability }
                return try await stateHost.read(request, gate: gate, ticket: ticket)
            },
            writeState: { [workspace, gate] request in
                if let workspace { return try await workspace.writeState(request) }
                guard let stateHost else { throw SourceHostFailure.undeclaredCapability }
                return try await stateHost.write(request, gate: gate, ticket: ticket)
            })
        formSession = forms; host = native
        let reply = try await forms.run { [self] in
            let reply = try await worker.invoke(ticket, gate: gate, policy: policy) { try await native.reply(to: $0) }
            if let library, let stateAccess { _ = try await library.readPublicState(using: stateAccess) }
            try await native.close()
            try await stateHost?.revoke()
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
