#if os(iOS)
import CryptoKit
import Foundation
import SnowlitCore
import SnowlitStorage
import Testing
import UIKit
import WebKit
@testable import YingxueKit

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct SourceContractProbeTests {
    @Test(arguments: [false, true])
    func authorExampleRunsReadingAndManagedAuthenticationThroughNativeHostContracts(inWorker: Bool) async throws {
        try await FixtureScenario.withScenario { fixture in
            let (status, bytes) = try await fixture.request("author.source.js")
            try #require(status == 200)
            let file = try SourceFileHeader(bytes: bytes)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            print("SourceContractObservation sourceSHA256=\(digest) protocol=\(file.manifest.protocolVersion)")
            let host = try NativeContractProbe(file: file, digest: digest, inWorker: inWorker)
            do {
                let inspected = try await host.prepare(at: fixture.url("page"), bytes: bytes)
                #expect(inspected.bytes == bytes && inspected.sha256 == digest)
                let search = try await host.invoke(.search(.init(kind: .search, input: .init(query: "Synthetic", cursor: nil))))
                guard case .search(let result) = search else { throw FixtureScenario.Failure.invalidResponse }
                let book = try #require(result.value.items.first?.reference)
                #expect(result.value.items.first?.title == "Synthetic book")
                let details = try await host.invoke(.book(.init(kind: .book, input: .init(reference: book))))
                guard case .book(let details) = details else { throw FixtureScenario.Failure.invalidResponse }
                #expect(details.value.reference == book)
                let first = try await host.invoke(.chapters(.init(kind: .chapters, input: .init(book: book, cursor: nil))))
                guard case .chapters(let first) = first else { throw FixtureScenario.Failure.invalidResponse }
                let second = try await host.invoke(.chapters(.init(kind: .chapters, input: .init(book: book, cursor: first.value.nextCursor))))
                guard case .chapters(let second) = second else { throw FixtureScenario.Failure.invalidResponse }
                #expect(first.value.items.map(\.key) == ["c1"])
                #expect(second.value.items.map(\.key) == ["c2"] && second.value.nextCursor == nil)
                let chapter = YingxueWire.OperationInput.chapter(.init(kind: .chapter, input: .init(reference: .init(book: book, key: "c1"))))
                let anonymous = try await host.invoke(chapter)
                guard case .failure(let anonymous) = anonymous else { throw FixtureScenario.Failure.invalidResponse }
                #expect(anonymous.error.code == .needsAuthentication)
                host.cancelForm = true
                let cancelled = try await host.invoke(.authenticate(.init(kind: .authenticate, input: .init(reason: .signIn))))
                guard case .failure(let cancelled) = cancelled else { throw FixtureScenario.Failure.invalidResponse }
                #expect(cancelled.error.code == .cancelled)
                host.cancelForm = false
                let authenticated = try await host.invoke(.authenticate(.init(kind: .authenticate, input: .init(reason: .expired))))
                guard case .authenticate(let authenticated) = authenticated else { throw FixtureScenario.Failure.invalidResponse }
                #expect(authenticated.value.status == .authenticated)
                try await host.gate.replace(scriptSHA256: digest, configurationRevision: 0, sessionRevision: 1,
                    enabled: true, credentialPolicy: host.credentialsPolicy)
                let content = try await host.invoke(chapter)
                guard case .chapter(let content) = content, case .text(let text) = content.value.body else {
                    throw FixtureScenario.Failure.invalidResponse
                }
                #expect(text.text == "中文\n\n第二段")
                #expect(host.methods.isSuperset(of: [.http, .decodeText, .dom, .interact, .readConfiguration]))
                #expect(host.submittedCredentialHandles == 1)
                #expect(host.replyContainsSecret == false)
                try await host.close()
            } catch {
                do { try await host.close() } catch { Issue.record(error, "Native contract fixture cleanup failed") }
                throw error
            }
        }
    }
}

/// A test adapter, not the product runtime or form UI. It executes the real
/// author module and native contracts against an isolated HTTP site and Keychain
/// namespace. The form decision is supplied by the test; no user UI is simulated.
@MainActor
private final class NativeContractProbe: NSObject, WKScriptMessageHandlerWithReply {
    let gate: SourceOperationGate
    let credentialsPolicy: SourceCredentialPolicy
    var cancelForm = false
    private(set) var methods = Set<YingxueWire.HostMethod>()
    private(set) var submittedCredentialHandles = 0
    private(set) var replyContainsSecret = false
    private let installation: SourceInstallationID
    private let policy: SourceHostPolicy
    private let manifest: YingxueWire.Manifest
    private let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
    private let world = WKContentWorld.world(name: "Snowlit.ContractProbe")
    private let credentials: KeychainCredentialStore
    private let website = SourceWebsiteSession(dataStore: .nonPersistent())
    private var nativeHost: SourceNativeHost?
    private var operation: SourceOperationGate.Ticket?
    private let worker: SourceWorkerSession?
    private var window: UIWindow?
    private weak var previousWindow: UIWindow?

    init(file: SourceFileHeader, digest: String, inWorker: Bool) throws {
        worker = inWorker ? SourceWorkerSession(program: try .init()) : nil
        let installation = SourceInstallationID()
        self.installation = installation
        manifest = file.manifest
        policy = try .init(installationID: installation, scriptSHA256: digest, manifest: file.manifest)
        let credentialsPolicy = try SourceCredentialPolicy(installationID: installation, scriptSHA256: digest, manifest: file.manifest)
        self.credentialsPolicy = credentialsPolicy
        gate = try .init(installationID: installation, scriptSHA256: digest, configurationRevision: 0,
            sessionRevision: 0, credentialPolicy: credentialsPolicy)
        credentials = try .init(servicePrefix: "io.github.bemarkt.snowlit.tests.contract.\(UUID())")
        super.init()
        probe.webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: world, name: "contractHost")
    }

    func prepare(at url: URL, bytes: Data) async throws -> SourceScriptSnapshot {
        let preview = try SourceImportPreview(bytes: bytes)
        let source = preview.header.source
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first { $0.isKeyWindow }
        let mounted = UIWindow(windowScene: scene)
        let controller = UIViewController()
        mounted.rootViewController = controller
        probe.webView.frame = mounted.bounds
        probe.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(probe.webView)
        mounted.makeKeyAndVisible()
        window = mounted
        #expect(probe.webView.window === mounted)
        try await probe.load(url)
        let program = try SourceInspectionProgram()
        _ = try await probe.evaluate(program.bootstrap + "\nreturn 'ready';", contentWorld: world)
        let inspected = try await probe.evaluate(program.evaluationBody,
            arguments: ["source": source, "requirements": SourceModuleInspection.requirements(for: manifest)], contentWorld: world)
        let snapshot = try preview.acceptInspection(Data(inspected.utf8), digest: {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        })
        if let worker {
            probe.close()
            worker.webView.frame = mounted.bounds
            worker.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.addSubview(worker.webView)
            #expect(worker.webView.window === mounted)
            try await worker.prepare(script: snapshot)
        } else {
            _ = try await probe.evaluate("""
                const url = URL.createObjectURL(new Blob([source], {type: 'text/javascript'}));
                try { globalThis.contractModule = await import(url); }
                finally { URL.revokeObjectURL(url); }
                return 'loaded';
                """, arguments: ["source": source], contentWorld: world)
        }
        return snapshot
    }

    func invoke(_ input: YingxueWire.OperationInput) async throws -> YingxueWire.OperationReply {
        let ticket = try await gate.begin(input)
        operation = ticket
        let configuration = try SourceConfiguration(policy: policy, revision: ticket.call.context.configurationRevision)
        let nativeHost = SourceNativeHost(gate: gate, ticket: ticket, policy: policy, configuration: configuration,
            website: website, credentials: credentials, mount: { [weak self] view in
                guard let container = self?.window?.rootViewController?.view else { return }
                view.frame = container.bounds; container.addSubview(view)
            }, interact: { [self] request in try await interaction(request, operation: ticket) },
            readState: { _ in throw SourceHostFailure.undeclaredCapability },
            writeState: { _ in throw SourceHostFailure.undeclaredCapability })
        self.nativeHost = nativeHost
        do {
            let reply: YingxueWire.OperationReply
            if let worker {
                reply = try await worker.invoke(ticket, gate: gate, policy: policy) { [self] host in
                    try await hostReply(for: host)
                }
            } else {
                let json = try await probe.evaluate("""
                    const call = JSON.parse(callJSON);
                    const ctx = {identity: call.context};
                    let sequence = 0;
                    for (const method of ['http', 'dom', 'decodeText', 'interact', 'readConfiguration']) {
                      ctx[method] = async input => {
                        const id = (++sequence).toString(16).padStart(8, '0') + '-0000-0000-0000-000000000000';
                        const response = await window.webkit.messageHandlers.contractHost.postMessage(
                          JSON.stringify({id, context: call.context, request: {kind: method, input}}));
                        const reply = JSON.parse(response);
                        if (reply.kind === 'failure') throw reply.error;
                        return reply.value;
                      };
                    }
                    try {
                      const configuration = await ctx.readConfiguration({});
                      if (configuration.revision !== call.context.configurationRevision) throw new Error('Stale configuration');
                      const value = await globalThis.contractModule[call.request.kind](ctx, call.request.input);
                      return JSON.stringify({kind: call.request.kind, context: call.context, value});
                    } catch (error) {
                      return JSON.stringify({kind: 'failure', context: call.context, operation: call.request.kind,
                        error: {code: error.code ?? 'invalidData', stage: error.stage ?? 'execute', retryable: error.retryable ?? false}});
                    }
                    """, arguments: ["callJSON": String(decoding: try YingxueWireCodec.encode(ticket.call), as: UTF8.self)], contentWorld: world)
                reply = try await gate.validateReply(Data(json.utf8), for: ticket)
            }
            try await nativeHost.close()
            try await gate.finish(ticket)
            self.nativeHost = nil
            operation = nil
            return reply
        } catch {
            await gate.cancel(ticket)
            try await nativeHost.close()
            self.nativeHost = nil
            operation = nil
            throw error
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.webView === probe.webView, message.frameInfo.isMainFrame,
              let json = message.body as? String, let operation else { return (nil, "Invalid contract invocation") }
        do {
            let ticket = try await gate.acceptHostCall(Data(json.utf8), for: operation, policy: policy)
            let reply = try await hostReply(for: ticket)
            let bytes = try YingxueWireCodec.encode(reply)
            _ = try await gate.validateHostReply(bytes, for: ticket)
            try await gate.finish(ticket)
            let encoded = String(decoding: bytes, as: UTF8.self)
            replyContainsSecret = replyContainsSecret || encoded.contains("fixture-password")
            return (encoded, nil)
        } catch {
            Issue.record(error, "Native contract host call failed")
            return (nil, "Contract host call failed")
        }
    }

    private func hostReply(for host: SourceOperationGate.HostTicket) async throws -> YingxueWire.HostReply {
        let call = host.call
        methods.insert(call.request.method)
        let reply = try await #require(nativeHost).reply(to: host)
        let encoded = String(decoding: try YingxueWireCodec.encode(reply), as: UTF8.self)
        replyContainsSecret = replyContainsSecret || encoded.contains("fixture-password")
        return reply
    }

    private func interaction(_ request: YingxueWire.InteractionRequest, operation: SourceOperationGate.Ticket) async throws -> YingxueWire.InteractionResult {
        let presentation = try await gate.beginInteraction(request, for: operation, policy: policy)
        let result: YingxueWire.InteractionResult
        if cancelForm { result = .cancelled(.init(kind: .cancelled)) }
        else {
            let id = StoredCredentialID(installationID: installation)
            try await credentials.write(.init(utf8: "fixture-password"), for: id)
            let handle = try await gate.issueCredential(id, origins: manifest.origins, for: operation)
            submittedCredentialHandles += 1
            result = .submitted(.init(kind: .submitted, fields: [.credential(.init(kind: .credential, key: "password", handle: handle))]))
        }
        return try await gate.completeInteraction(.init(id: presentation.id, result: result), for: operation)
    }

    func close() async throws {
        await gate.close()
        if let worker { try await worker.close() }
        try await nativeHost?.close()
        window?.isHidden = true; window = nil; previousWindow?.makeKeyAndVisible()
        probe.webView.configuration.userContentController.removeScriptMessageHandler(forName: "contractHost", contentWorld: world)
        probe.close()
        try await website.erase()
        try await credentials.removeAll(for: installation)
    }
}

#endif
