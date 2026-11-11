#if os(iOS)
import Foundation
import Testing
import UIKit
import WebKit
@testable import YingxueKit

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct WebKitRecoveryTests {
    /// A controlled preparation comparison, separate from the required fault
    /// tests below. A visible window is the only variable; deadlines stay fixed.
    @Test(arguments: [false, true])
    func comparePreparationWithWindowAttachment(attached: Bool) async throws {
        let clock = ContinuousClock()
        let candidateWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = try #require(candidateWindow)
        for repetition in 1...3 {
            let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe.close() }
            // Keep geometry equal in both cases so only attachment changes.
            probe.webView.frame = window.bounds
            if attached {
                window.addSubview(probe.webView)
            }
            #expect((probe.webView.window != nil) == attached)
            let start = clock.now
            print("PreparationStarted attached=\(attached) repetition=\(repetition)")
            do {
                try await probe.loadHTML("<!doctype html><html><head><title>Preparation comparison</title></head><body></body></html>")
                #expect(try await probe.evaluate("return document.readyState;") == "complete")
                print("PreparationObservation attached=\(attached) repetition=\(repetition) result=ready elapsed=\(start.duration(to: clock.now))")
            } catch {
                // Keep the failure and sample the remaining repetitions. This
                // distinguishes a first-load failure from every offscreen load.
                Issue.record(error, "Preparation failed: attached=\(attached), repetition=\(repetition)")
                print("PreparationObservation attached=\(attached) repetition=\(repetition) result=failed elapsed=\(start.duration(to: clock.now))")
            }
        }
    }

    /// The supervising script injects the OS process fault only after proving
    /// one WebContent child belongs to this test host's dedicated launchd_sim.
    /// Bounded touched allocations exercise retained page memory before the
    /// fault; 64 MiB is fixture data, not a product budget or an OOM guarantee.
    @Test func nativeTerminationInvalidatesPendingWorkAndRebuildsAfterMemoryGrowth() async throws {
        let page = URL(string: "http://127.0.0.1:18731/health")!
        for _ in 1...3 {
            var probe: WebKitRuntimeProbe? = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe?.close() }
            try await probe!.load(page)
            #expect(try await probe!.evaluate("""
                globalThis.retainedProbeBuffers = [];
                for (let i = 0; i < 16; i++) {
                  const bytes = new Uint8Array(4 * 1024 * 1024); bytes.fill(i + 1);
                  globalThis.retainedProbeBuffers.push(bytes);
                }
                return String(globalThis.retainedProbeBuffers.reduce((sum, bytes) => sum + bytes.byteLength, 0));
                """) == "67108864")
            let active = probe!
            // Keep the awaited promise reachable. Otherwise WebKit can collect
            // its completion handlers before the supervisor injects the fault.
            let pending = Task { try await active.evaluate("""
                globalThis.pendingTerminationProbe = new Promise(resolve => {
                  globalThis.resolveTerminationProbe = resolve;
                });
                return await globalThis.pendingTerminationProbe;
                """, timeout: .seconds(5)) }
            defer { pending.cancel() }
            try await FixtureScenario.eventually { active.results.pendingCount == 1 }
            try await FixtureScenario.eventually {
                try await active.evaluate("return String(typeof globalThis.resolveTerminationProbe === 'function');") == "true"
            }
            let token = UUID().uuidString.lowercased()
            let request = "TerminationRequest token=\(token) hostPID=\(ProcessInfo.processInfo.processIdentifier)\n"
            FileHandle.standardOutput.write(Data(request.utf8))
            // Await the actual delegate signal independently of the evaluation
            // callback, so a callback failure cannot immediately advance the
            // suite while the already requested process fault is still pending.
            try await FixtureScenario.eventually { active.terminationCount == 1 }
            await #expect(throws: ProbeResultRegistry<String>.Interruption.webContentTerminated) { try await pending.value }
            try #require(active.terminationCount == 1)
            #expect(active.results.pendingCount == 0)
            active.close()
            probe = nil
            let replacement = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { replacement.close() }
            try await replacement.load(page, timeout: .seconds(5))
            #expect(try await replacement.evaluate("return 'restored after native termination';", timeout: .seconds(5)) == "restored after native termination")
            FileHandle.standardOutput.write(Data("TerminationCompleted token=\(token) hostPID=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        }
    }

    /// Only run with scripts/probe_ios.sh phone recovery. It owns a dedicated simulator
    /// and a process deadline. A new WKWebView is not assumed to own a new WebContent process.
    @Test func observeRecoveryAfterAbandoningUncooperativeJavaScript() async throws {
        // The prior run completed spin but never reached the following never
        // baseline. Run never before spin in this same host, then measure a new
        // load after spin. All six fault repetitions and deadlines remain.
        print("RecoveryOrder never-then-spin-then-load hostPID=\(ProcessInfo.processInfo.processIdentifier)")
        for fault in ["never", "spin"] {
            do { try await observeRecovery(fault: fault) }
            catch { Issue.record(error, "Recovery comparison failed for \(fault)") }
        }
        let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
        defer { probe.close() }
        let candidateWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = try #require(candidateWindow)
        probe.webView.frame = window.bounds; window.addSubview(probe.webView)
        print("PostSpinPreparation started hostPID=\(ProcessInfo.processInfo.processIdentifier)")
        try await probe.load(URL(string: "http://127.0.0.1:18731/health")!)
        #expect(try await probe.evaluate("return document.readyState;") == "complete")
        print("PostSpinPreparation ready hostPID=\(ProcessInfo.processInfo.processIdentifier)")
    }

    private func observeRecovery(fault: String) async throws {
        try #require(Bundle.main.bundleIdentifier == "io.github.bemarkt.snowlit")
        let candidateWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = try #require(candidateWindow)
        let clock = ContinuousClock()
        let page = URL(string: "http://127.0.0.1:18731/health")!
        for repetition in 1...3 {
            var probe: WebKitRuntimeProbe? = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe?.close() }
            probe!.webView.frame = window.bounds
            window.addSubview(probe!.webView)
            #expect(probe!.webView.window === window)
            let lifetime = ViewLifetimeObservation(probe!.webView)
            try await probe!.load(page)
            observe("baseline", fault: fault, repetition: repetition)
            try await Task.sleep(for: .seconds(1))
            let heartbeat = MainActorHeartbeat()
            // Test-owned task is cancelled and awaited below on success or failure.
            let ticker = Task { @MainActor in
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(20))
                        heartbeat.ticks += 1
                    }
                } catch { /* Sleep ends when the test cancels its ticker. */ }
            }
            let started = clock.now
            let entry = FaultEntryObservation(fault: fault, repetition: repetition)
            probe!.webView.configuration.userContentController.add(entry, name: "recoveryStarted")
            do {
                let faultBody = fault == "spin" ? "while (true) {}" : "return await new Promise(() => {});"
                let body = "window.webkit.messageHandlers.recoveryStarted.postMessage(startToken);\n" + faultBody
                observe("execution-requested", fault: fault, repetition: repetition)
                await #expect(throws: ProbeResultRegistry<String>.Interruption.timedOut) {
                    try await probe!.evaluate(body, arguments: ["startToken": entry.token], timeout: .milliseconds(300))
                }
                try #require(entry.received, "The script must actually enter the fault before recovery is assessed")
                let waitDuration = started.duration(to: clock.now)
                #expect(heartbeat.ticks > 0)
                #expect(probe!.results.pendingCount == 0)
                observe("waiter-ended", fault: fault, repetition: repetition)
                // A separate observation window after waiter timeout lets the host
                // sample the still-uncooperative work before close is requested.
                try await Task.sleep(for: .seconds(1))
                probe!.webView.configuration.userContentController.removeScriptMessageHandler(forName: "recoveryStarted")
                probe!.close()
                probe = nil
                observe("closed", fault: fault, repetition: repetition)
                let releaseDeadline = clock.now.advanced(by: .seconds(3))
                while lifetime.view != nil && clock.now < releaseDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(lifetime.view == nil)
                let replacement = WebKitRuntimeProbe(dataStore: .nonPersistent())
                defer { replacement.close() }
                replacement.webView.frame = window.bounds
                window.addSubview(replacement.webView)
                #expect(replacement.webView.window === window)
                let recoveryStarted = clock.now
                try await replacement.load(page, timeout: .seconds(10))
                #expect(try await replacement.evaluate("return 'fresh operation';", timeout: .seconds(10)) == "fresh operation")
                print("RecoveryObservation fault=\(fault) repetition=\(repetition) waiter=\(waitDuration) heartbeats=\(heartbeat.ticks) newOperation=\(recoveryStarted.duration(to: clock.now)) wrapperReleased=\(lifetime.view == nil)")
                observe("replacement-ready", fault: fault, repetition: repetition)
                // Keep the test process alive so host sampling can observe post-close CPU/RSS.
                try await Task.sleep(for: .seconds(2))
                observe("observation-ended", fault: fault, repetition: repetition)
            } catch {
                probe?.webView.configuration.userContentController.removeScriptMessageHandler(forName: "recoveryStarted")
                probe?.close()
                ticker.cancel()
                await ticker.value
                throw error
            }
            ticker.cancel()
            await ticker.value
        }
        // Even if every assertion passes, CPU/RSS/process sampling is still required.
        // Waiter completion and released Swift wrappers do not prove JS/resource termination.
    }

    private func observe(_ stage: String, fault: String, repetition: Int) {
        print("RecoveryEvent epochSeconds=\(Date().timeIntervalSince1970) stage=\(stage) fault=\(fault) repetition=\(repetition) hostPID=\(ProcessInfo.processInfo.processIdentifier)")
    }

    @MainActor
    private final class MainActorHeartbeat { var ticks = 0 }

    @MainActor
    private final class ViewLifetimeObservation {
        weak var view: WKWebView?
        init(_ view: WKWebView) { self.view = view }
    }

    @MainActor
    private final class FaultEntryObservation: NSObject, WKScriptMessageHandler {
        let token = UUID().uuidString
        private(set) var received = false
        private let fault: String
        private let repetition: Int

        init(fault: String, repetition: Int) {
            self.fault = fault
            self.repetition = repetition
            super.init()
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "recoveryStarted", message.frameInfo.isMainFrame,
                  message.body as? String == token, !received else { return }
            received = true
            print("RecoveryEvent epochSeconds=\(Date().timeIntervalSince1970) stage=fault-entered fault=\(fault) repetition=\(repetition) hostPID=\(ProcessInfo.processInfo.processIdentifier)")
        }
    }
}
#endif
