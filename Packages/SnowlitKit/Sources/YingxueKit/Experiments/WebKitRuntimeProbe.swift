#if os(iOS)
import Foundation
import WebKit

/// Isolated feasibility probe. No production caller, database access, or frozen source API.
@MainActor
final class WebKitRuntimeProbe: NSObject, WKNavigationDelegate {
    enum Failure: Error {
        case navigationNotStarted
        case nonStringResult
        case closed
    }

    let webView: WKWebView
    let results = ProbeResultRegistry<String>()
    private let navigations = ProbeResultRegistry<String>()
    private var navigation: (WKNavigation, ProbeResultRegistry<String>.Ticket)?
    private(set) var terminationCount = 0
    private var isClosed = false
    private let observationID = UUID()
    private var evaluationCount = 0

    init(dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL, timeout: Duration = .seconds(10)) async throws {
        guard !isClosed else { throw Failure.closed }
        navigations.invalidate(because: .contextRebuilt)
        results.invalidate(because: .contextRebuilt)
        navigation = nil
        webView.stopLoading()
        do {
            _ = try await navigations.perform(timeout: timeout) { ticket in
                if let started = webView.load(URLRequest(url: url)) {
                    navigation = (started, ticket)
                } else {
                    navigations.resolve(ticket, with: .failure(Failure.navigationNotStarted))
                }
            }
        } catch {
            observeFailure(operation: "load", sequence: 0)
            throw error
        }
    }

    /// The experiment uses JSON strings to avoid passing WebKit's Any values across actors.
    /// A cancelled/timed-out wait does NOT stop the JavaScript body or its network requests.
    func evaluate(
        _ body: String,
        arguments: [String: Any] = [:],
        contentWorld: WKContentWorld = .page,
        timeout: Duration = .seconds(10)
    ) async throws -> String {
        guard !isClosed else { throw Failure.closed }
        evaluationCount += 1
        let sequence = evaluationCount
        do {
            return try await results.perform(timeout: timeout) { ticket in
                webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: contentWorld) {
                    [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let value):
                        guard let string = value as? String else {
                            results.resolve(ticket, with: .failure(Failure.nonStringResult))
                            return
                        }
                        results.resolve(ticket, with: .success(string))
                    case .failure(let error):
                        results.resolve(ticket, with: .failure(error))
                    }
                }
            }
        } catch {
            observeFailure(operation: "evaluate", sequence: sequence)
            throw error
        }
    }

    func invalidateSource() { results.invalidate(because: .sourceChanged) }
    func invalidateSession() { results.invalidate(because: .sessionChanged) }

    func close() {
        isClosed = true
        navigation = nil
        results.close()
        navigations.close()
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        // Public cleanup calls alone do not establish that WebContent execution ended.
    }

    func webView(_ webView: WKWebView, didFinish completed: WKNavigation!) {
        settleNavigation(completed, with: .success(webView.url?.absoluteString ?? ""))
    }

    func webView(_ webView: WKWebView, didFail failed: WKNavigation!, withError error: any Error) {
        settleNavigation(failed, with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation failed: WKNavigation!,
                 withError error: any Error) {
        settleNavigation(failed, with: .failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        terminationCount += 1
        navigation = nil
        navigations.invalidate(because: .webContentTerminated)
        results.invalidate(because: .webContentTerminated)
    }

    private func observeFailure(operation: String, sequence: Int) {
        // Probe metadata only: no scripts, arguments, URLs, cookies or website content.
        print("WebKitProbeObservation id=\(observationID) operation=\(operation) sequence=\(sequence) loading=\(webView.isLoading) terminations=\(terminationCount) pending=\(results.pendingCount) epochSeconds=\(Date().timeIntervalSince1970)")
    }

    private func settleNavigation(_ completed: WKNavigation?, with result: Result<String, any Error>) {
        guard let (expected, ticket) = navigation, completed === expected else { return }
        navigation = nil
        navigations.resolve(ticket, with: result)
    }
}
#endif
