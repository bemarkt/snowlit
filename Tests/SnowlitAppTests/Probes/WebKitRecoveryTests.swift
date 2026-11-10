#if os(iOS)
import Foundation
import Testing
import WebKit
@testable import YingxueKit

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct WebKitRecoveryTests {
    /// Only run with scripts/probe_ios.sh phone recovery. It owns a dedicated simulator
    /// and a process deadline. A new WKWebView is not assumed to own a new WebContent process.
    @Test(arguments: ["spin", "never"])
    func observeRecoveryAfterAbandoningUncooperativeJavaScript(fault: String) async throws {
        try #require(Bundle.main.bundleIdentifier == "io.github.bemarkt.snowlit")
        let clock = ContinuousClock()
        let page = URL(string: "http://127.0.0.1:18731/health")!
        for repetition in 1...3 {
            var probe: WebKitRuntimeProbe? = WebKitRuntimeProbe(dataStore: .nonPersistent())
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
                let recoveryStarted = clock.now
                try await replacement.load(page, timeout: .seconds(5))
                #expect(try await replacement.evaluate("return 'fresh operation';", timeout: .seconds(5)) == "fresh operation")
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
        print("RecoveryEvent epochSeconds=\(Date().timeIntervalSince1970) stage=\(stage) fault=\(fault) repetition=\(repetition)")
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
            print("RecoveryEvent epochSeconds=\(Date().timeIntervalSince1970) stage=fault-entered fault=\(fault) repetition=\(repetition)")
        }
    }
}
#endif
