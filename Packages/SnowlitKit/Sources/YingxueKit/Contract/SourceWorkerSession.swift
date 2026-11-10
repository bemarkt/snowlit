#if os(iOS)
import Foundation
import SnowlitCore
import WebKit

public enum SourceWorkerFailure: Error, Equatable, Sendable {
    case unavailable, busy, notMounted, timedOut, terminated, invalidResult, hostFailed, cleanupRequired, sourceRejected
}

/// Candidate execution owner. The App mounts this view, supplies native host
/// capabilities and must await close before releasing it. A deadline alone never
/// means JavaScript stopped; close invokes the worker's public terminate API.
@MainActor
public final class SourceWorkerSession: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    public let webView: WKWebView
    public typealias Host = @MainActor (SourceOperationGate.HostTicket) async throws -> YingxueWire.HostReply

    private struct Invocation {
        let ticket: SourceOperationGate.Ticket
        let gate: SourceOperationGate
        let policy: SourceHostPolicy
        let host: Host
    }
    private let program: SourceExecutionProgram
    private let waits = ProbeResultRegistry<String>()
    private var navigation: (WKNavigation, ProbeResultRegistry<String>.Ticket)?
    private var current: Invocation?
    private var hostTasks: [UUID: Task<String, any Error>] = [:]
    private var hostFailed = false
    private var prepared = false
    private var preparing = false
    private var workerMayExist = false
    private var processTerminated = false
    private var closed = false
    private var cleanup: Task<Void, any Error>?
    private var scriptIdentity: (sha256: String, sourceID: String)?
    private var installationID: String?

    public init(program: SourceExecutionProgram) {
        self.program = program
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "sourceHost")
    }

    public func prepare(script: SourceScriptSnapshot, upgrade: SourceUpgradeAssessment? = nil,
                        timeout: Duration = .seconds(10)) async throws {
        let header = try SourceFileHeader(bytes: script.bytes)
        try await prepare(source: header.source,
            requiredExports: GeneratedModulePolicy.requiredExports + SourceModuleInspection.requirements(for: header.manifest, upgrade: upgrade),
            timeout: timeout)
        scriptIdentity = (script.sha256, header.manifest.sourceID)
    }

    // Internal raw entry is used for adversarial top-level execution tests.
    func prepare(source: String, requiredExports: [String], timeout: Duration = .seconds(10)) async throws {
        guard !closed, cleanup == nil, !processTerminated else { throw SourceWorkerFailure.unavailable }
        guard !prepared, !preparing else { throw SourceWorkerFailure.busy }
        guard webView.window != nil else { throw SourceWorkerFailure.notMounted }
        preparing = true
        defer { preparing = false }
        do {
            _ = try await waits.perform(timeout: timeout) { ticket in
                let started = webView.loadHTMLString("""
                    <!doctype html><meta http-equiv="Content-Security-Policy"
                    content="default-src 'none'; script-src blob:; worker-src blob:; connect-src 'none'">
                    <title>Source execution</title>
                    """, baseURL: nil)
                if let started { navigation = (started, ticket) }
                else { waits.resolve(ticket, with: .failure(SourceWorkerFailure.unavailable)) }
            }
            workerMayExist = true
            let result = try await evaluate(program.parent, arguments: ["source": source, "bootstrap": program.bootstrap,
                "requiredExports": requiredExports, "methods": program.methods], timeout: timeout)
            guard result == "ready" else { throw SourceWorkerFailure.invalidResult }
            prepared = true
        } catch {
            let failure = Self.classify(error)
            try await close()
            throw failure
        }
    }

    /// The caller owns gate.finish and any storage adoption after validating the
    /// returned value. This session never writes active installation data.
    public func invoke(_ ticket: SourceOperationGate.Ticket, gate: SourceOperationGate, policy: SourceHostPolicy,
                       timeout: Duration = .seconds(30), host: @escaping Host) async throws -> YingxueWire.OperationReply {
        guard prepared, !closed, cleanup == nil, !processTerminated else { throw SourceWorkerFailure.unavailable }
        guard current == nil else { throw SourceWorkerFailure.busy }
        try policy.check(ticket.call.context)
        if let scriptIdentity {
            guard ticket.call.context.scriptSHA256 == scriptIdentity.sha256,
                  policy.manifest.sourceID.utf8.elementsEqual(scriptIdentity.sourceID.utf8) else {
                throw SourceHostFailure.wrongContext
            }
        }
        if let installationID, installationID != ticket.call.context.installationID { throw SourceHostFailure.wrongContext }
        try await gate.check(ticket)
        installationID = ticket.call.context.installationID
        current = .init(ticket: ticket, gate: gate, policy: policy, host: host)
        hostFailed = false
        do {
            let json = String(decoding: try YingxueWireCodec.encode(ticket.call), as: UTF8.self)
            let result = try await evaluate("return await globalThis.snowlitSourceWorker.invoke(callJSON);",
                arguments: ["callJSON": json], timeout: timeout)
            guard !hostFailed, hostTasks.isEmpty else { throw SourceWorkerFailure.hostFailed }
            let reply = try await gate.validateReply(Data(result.utf8), for: ticket)
            guard current?.ticket.call.context == ticket.call.context, !closed, cleanup == nil else {
                throw SourceWorkerFailure.unavailable
            }
            current = nil
            return reply
        } catch {
            let failure = Self.classify(error)
            await gate.cancel(ticket)
            try await close()
            throw failure
        }
    }

    /// Calls every required version group and validates the combined result.
    /// Returning these values still does not activate the candidate in Storage.
    public func migrate(_ plan: SourceUpdateMigrationPlan, gate: SourceOperationGate, policy: SourceHostPolicy,
                        host: @escaping Host) async throws -> SourceUpdateMigrationValues {
        var references: [YingxueWire.ReferenceMigrationResult] = []
        var state: YingxueWire.StateMigrationResult?
        for input in plan.referenceInputs {
            let ticket = try await gate.begin(.migrateReferences(.init(kind: .migrateReferences, input: input)))
            do {
                let reply = try await invoke(ticket, gate: gate, policy: policy, host: host)
                guard case .migrateReferences(let value) = reply else { throw SourceWorkerFailure.sourceRejected }
                references.append(value.value)
                try await gate.finish(ticket)
            } catch { await gate.cancel(ticket); throw error }
        }
        if let input = plan.stateInput {
            let ticket = try await gate.begin(.migrateState(.init(kind: .migrateState, input: input)))
            do {
                let reply = try await invoke(ticket, gate: gate, policy: policy, host: host)
                guard case .migrateState(let value) = reply else { throw SourceWorkerFailure.sourceRejected }
                state = value.value
                try await gate.finish(ticket)
            } catch { await gate.cancel(ticket); throw error }
        }
        return try plan.validate(references: references, state: state)
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard !closed, cleanup == nil, message.webView === webView, message.frameInfo.isMainFrame,
              let json = message.body as? String, let invocation = current else { return (nil, "Source operation unavailable") }
        let id = UUID()
        // This bounded host task belongs to this session and is cancelled and
        // awaited by close. Late native work cannot reply to a later invocation.
        let task = Task { @MainActor [self] in
            let ticket = try await invocation.gate.acceptHostCall(Data(json.utf8), for: invocation.ticket, policy: invocation.policy)
            let reply = try await invocation.host(ticket)
            let bytes = try YingxueWireCodec.encode(reply)
            _ = try await invocation.gate.validateHostReply(bytes, for: ticket)
            guard current?.ticket.call.context == invocation.ticket.call.context, cleanup == nil else {
                throw SourceWorkerFailure.unavailable
            }
            try await invocation.gate.finish(ticket)
            return String(decoding: bytes, as: UTF8.self)
        }
        hostTasks[id] = task
        defer { hostTasks.removeValue(forKey: id) }
        do { return (try await task.value, nil) }
        catch { hostFailed = true; return (nil, "Source host operation failed") }
    }

    /// Cleanup uses a finite owned task so caller cancellation cannot cancel the
    /// terminate request. A failed terminate leaves this owner available to retry.
    public func close() async throws {
        if let cleanup { return try await cleanup.value }
        if closed { return }
        let task = Task { @MainActor [self] in
            prepared = false
            if let current { await current.gate.cancel(current.ticket) }
            current = nil
            waits.invalidate(because: .closed)
            let tasks = Array(hostTasks.values)
            tasks.forEach { $0.cancel() }
            if workerMayExist && !processTerminated {
                let stopped = try await evaluate("return globalThis.snowlitSourceWorker?.stop() ?? 'terminated';", timeout: .seconds(2))
                guard stopped == "terminated" else { throw SourceWorkerFailure.cleanupRequired }
            }
            for task in tasks { _ = await task.result }
            closed = true; workerMayExist = false; navigation = nil
            waits.close()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "sourceHost", contentWorld: .page)
            webView.navigationDelegate = nil
            webView.stopLoading(); webView.removeFromSuperview()
        }
        cleanup = task
        defer { cleanup = nil }
        do { try await task.value }
        catch { throw SourceWorkerFailure.cleanupRequired }
    }

    private func evaluate(_ body: String, arguments: [String: Any] = [:], timeout: Duration) async throws -> String {
        try await waits.perform(timeout: timeout) { ticket in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let value):
                    guard let value = value as? String else { waits.resolve(ticket, with: .failure(SourceWorkerFailure.invalidResult)); return }
                    waits.resolve(ticket, with: .success(value))
                case .failure: waits.resolve(ticket, with: .failure(SourceWorkerFailure.invalidResult))
                }
            }
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { settle(navigation, result: .success("loaded")) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        settle(navigation, result: .failure(SourceWorkerFailure.unavailable))
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        settle(navigation, result: .failure(SourceWorkerFailure.unavailable))
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        processTerminated = true
        waits.invalidate(because: .webContentTerminated)
        hostTasks.values.forEach { $0.cancel() }
    }
    private func settle(_ finished: WKNavigation?, result: Result<String, any Error>) {
        guard let (expected, ticket) = navigation, finished === expected else { return }
        navigation = nil; waits.resolve(ticket, with: result)
    }
    private static func classify(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        switch error as? ProbeResultRegistry<String>.Interruption {
        case .cancelled: return CancellationError()
        case .timedOut: return SourceWorkerFailure.timedOut
        case .webContentTerminated: return SourceWorkerFailure.terminated
        case .some: return SourceWorkerFailure.unavailable
        case nil: return error
        }
    }
}
#endif
