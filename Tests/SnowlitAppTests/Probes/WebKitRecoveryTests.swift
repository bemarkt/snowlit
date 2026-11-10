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
            weak var abandonedView: WKWebView? = probe?.webView
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
            do {
                let body = fault == "spin" ? "while (true) {}" : "return await new Promise(() => {});"
                observe("execution-started", fault: fault, repetition: repetition)
                await #expect(throws: ProbeResultRegistry<String>.Interruption.timedOut) {
                    try await probe!.evaluate(body, timeout: .milliseconds(300))
                }
                let waitDuration = started.duration(to: clock.now)
                #expect(heartbeat.ticks > 0)
                #expect(probe!.results.pendingCount == 0)
                probe!.close()
                probe = nil
                observe("closed", fault: fault, repetition: repetition)
                let releaseDeadline = clock.now.advanced(by: .seconds(3))
                while abandonedView != nil && clock.now < releaseDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(abandonedView == nil)
                let replacement = WebKitRuntimeProbe(dataStore: .nonPersistent())
                defer { replacement.close() }
                let recoveryStarted = clock.now
                try await replacement.load(page, timeout: .seconds(5))
                #expect(try await replacement.evaluate("return 'fresh operation';", timeout: .seconds(5)) == "fresh operation")
                print("RecoveryObservation fault=\(fault) repetition=\(repetition) waiter=\(waitDuration) heartbeats=\(heartbeat.ticks) newOperation=\(recoveryStarted.duration(to: clock.now)) wrapperReleased=\(abandonedView == nil)")
                observe("replacement-ready", fault: fault, repetition: repetition)
                // Keep the test process alive so host sampling can observe post-close CPU/RSS.
                try await Task.sleep(for: .seconds(2))
                observe("observation-ended", fault: fault, repetition: repetition)
            } catch {
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
}
#endif
