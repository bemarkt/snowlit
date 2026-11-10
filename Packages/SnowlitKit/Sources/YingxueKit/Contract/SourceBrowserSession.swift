#if os(iOS)
import Foundation
import WebKit

public enum SourceBrowserFailure: Error, Equatable, Sendable { case closed, unavailable, navigationDenied, invalidResult, notMounted }

/// Native page capabilities for one operation. Website contexts have no source
/// host message handler and share only the owner's explicit website data store.
@MainActor
public final class SourceBrowserSession {
    private let gate: SourceOperationGate
    private let ticket: SourceOperationGate.Ticket
    private let policy: SourceHostPolicy
    private let dataStore: WKWebsiteDataStore
    private let mount: @MainActor (WKWebView) -> Void
    private var pages: [String: SourceBrowserPage] = [:]
    private var pageTickets: [String: SourceOperationGate.PageTicket] = [:]
    private var rules: WKContentRuleList?
    private var ruleID: String?
    private var compilation: Task<WKContentRuleList, any Error>?
    private var closing: Task<Void, any Error>?
    private var closed = false

    public init(gate: SourceOperationGate, ticket: SourceOperationGate.Ticket, policy: SourceHostPolicy,
                dataStore: WKWebsiteDataStore, mount: @escaping @MainActor (WKWebView) -> Void) {
        self.gate = gate; self.ticket = ticket; self.policy = policy
        self.dataStore = dataStore; self.mount = mount
    }

    public func open(_ request: YingxueWire.OpenPage) async throws -> YingxueWire.OpenedPage {
        try checkOpen()
        try await gate.check(ticket)
        let url = try policy.resolve(request.target)
        let rules = try await contentRules()
        try checkOpen()
        let pageTicket = try await gate.createPage(for: ticket, policy: policy)
        do {
            try checkOpen()
            let page = SourceBrowserPage(gate: gate, ticket: ticket, page: pageTicket, policy: policy, dataStore: dataStore, rules: rules)
            pages[pageTicket.id] = page
            pageTickets[pageTicket.id] = pageTicket
            mount(page.webView)
            guard page.webView.window != nil else { throw SourceBrowserFailure.notMounted }
            return try await page.load(url)
        } catch {
            pages.removeValue(forKey: pageTicket.id)?.close()
            pageTickets.removeValue(forKey: pageTicket.id)
            await gate.discardPage(pageTicket)
            throw error
        }
    }

    public func evaluate(_ request: YingxueWire.EvaluatePage) async throws -> YingxueWire.PageEvaluation {
        try checkOpen()
        try await gate.preparePageEvaluation(request, for: ticket)
        guard let page = pages[request.page.id] else { throw SourcePageFailure.missingPage }
        let json = try await page.evaluate(SourcePageProgram.body(for: request), inputJSON: request.inputJSON)
        try checkOpen()
        return try await gate.acceptPageEvaluation(YingxueWireCodec.encode(YingxueWire.PageEvaluation(json: json)),
            page: request.page, for: ticket)
    }

    public func closePage(_ request: YingxueWire.ClosePage) async throws -> YingxueWire.ClosedPage {
        try checkOpen()
        let result = try await gate.closePage(request, for: ticket)
        pages.removeValue(forKey: request.id)?.close()
        pageTickets.removeValue(forKey: request.id)
        return result
    }

    /// Only the trusted native interaction presenter obtains the website view.
    public func webView(for pageID: String) -> WKWebView? { pages[pageID]?.webView }

    public func close() async throws {
        if let closing { return try await closing.value }
        closed = true
        for page in pages.values { page.close() }
        let registrations = Array(pageTickets.values)
        pageTickets.removeAll()
        pages.removeAll(); rules = nil
        // One finite, awaited cleanup survives cancellation of the UI caller.
        // A rule-store failure leaves its exact ID available for a later retry.
        let task = Task { @MainActor in
            for page in registrations { await gate.discardPage(page) }
            if let compilation {
                if case .failure = await compilation.result { ruleID = nil }
                self.compilation = nil
            }
            if let ruleID {
                try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: ruleID)
                self.ruleID = nil
            }
        }
        closing = task
        do { try await task.value; closing = nil }
        catch { closing = nil; throw error }
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw SourceBrowserFailure.closed }
    }

    private func contentRules() async throws -> WKContentRuleList {
        if let rules { return rules }
        if let compilation { return try await compilation.value }
        // The block rule also covers subresources and redirected destinations;
        // a navigation delegate alone only validates the eventual response.
        var values: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        for origin in policy.manifest.origins {
            let port = origin.port ?? (origin.scheme == .https ? 443 : 80)
            let defaultPort = origin.scheme == .https ? 443 : 80
            let portPattern = port == defaultPort ? "(:\(port))?" : ":\(port)"
            let host = NSRegularExpression.escapedPattern(for: origin.host)
            values.append(["trigger": ["url-filter": "^\(origin.scheme.rawValue)://\(host)\(portPattern)/"],
                           "action": ["type": "ignore-previous-rules"]])
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
        let id = "Snowlit.SourcePage.\(UUID().uuidString)"
        ruleID = id
        // One finite compilation is shared by concurrent page opens. close()
        // awaits it before removing its exact rule ID, including on cancellation.
        let task = Task { @MainActor in
            guard let compiled = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) else {
                throw SourceBrowserFailure.unavailable
            }
            return compiled
        }
        compilation = task
        let compiled = try await task.value
        try checkOpen()
        rules = compiled
        return compiled
    }
}

@MainActor
private final class SourceBrowserPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let gate: SourceOperationGate
    private let ticket: SourceOperationGate.Ticket
    private let page: SourceOperationGate.PageTicket
    private let policy: SourceHostPolicy
    private let waits = ProbeResultRegistry<String>()
    private var loading: ProbeResultRegistry<String>.Ticket?
    private var current: SourceOperationGate.PageNavigation?
    private var navigation: WKNavigation?
    private var closed = false
    private var finished: YingxueWire.OpenedPage?
    private let world = WKContentWorld.world(name: "Snowlit.WebsiteExtraction")

    init(gate: SourceOperationGate, ticket: SourceOperationGate.Ticket, page: SourceOperationGate.PageTicket,
         policy: SourceHostPolicy, dataStore: WKWebsiteDataStore, rules: WKContentRuleList) {
        self.gate = gate; self.ticket = ticket; self.page = page; self.policy = policy
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.add(rules)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async throws -> YingxueWire.OpenedPage {
        _ = try await waits.perform(timeout: .seconds(15)) { waiting in
            loading = waiting
            navigation = webView.load(URLRequest(url: url))
            if navigation == nil { settle(.failure(SourceBrowserFailure.unavailable)) }
        }
        guard let finished else { throw SourceBrowserFailure.invalidResult }
        try await gate.checkPage(finished.page, for: ticket)
        return finished
    }

    func evaluate(_ body: String, inputJSON: String) async throws -> String {
        guard !closed else { throw SourceBrowserFailure.closed }
        return try await waits.perform(timeout: .seconds(10)) { waiting in
            webView.callAsyncJavaScript(body, arguments: ["inputJSON": inputJSON], in: nil, in: world) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let value):
                    guard let value = value as? String else { waits.resolve(waiting, with: .failure(SourceBrowserFailure.invalidResult)); return }
                    waits.resolve(waiting, with: .success(value))
                case .failure: waits.resolve(waiting, with: .failure(SourceBrowserFailure.invalidResult))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !closed, let url = navigationAction.request.url, navigationAction.targetFrame != nil else { return .cancel }
        do {
            _ = try policy.resolve(.init(url: url.absoluteString))
            try await gate.check(ticket)
            if navigationAction.targetFrame?.isMainFrame == true {
                current = try await gate.beginNavigation(.init(url: url.absoluteString), page: page)
                finished = nil
            }
            guard !closed else { return .cancel }
            return .allow
        } catch {
            if navigationAction.targetFrame?.isMainFrame == true { settle(.failure(SourceBrowserFailure.navigationDenied)) }
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard !closed, let url = navigationResponse.response.url else { return .cancel }
        do {
            _ = try policy.resolve(.init(url: url.absoluteString))
            try await gate.check(ticket)
            if navigationResponse.isForMainFrame, current?.url != url {
                current = try await gate.beginNavigation(.init(url: url.absoluteString), page: page)
            }
            return closed ? .cancel : .allow
        } catch {
            if navigationResponse.isForMainFrame { settle(.failure(SourceBrowserFailure.navigationDenied)) }
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Finite delegate completion retains only this page; close invalidates
        // its gate/page registration before any result is delivered downstream.
        guard !closed, navigation === self.navigation, let current, let url = webView.url else { return }
        Task { @MainActor [weak self] in
            guard let self, !closed, navigation === self.navigation else { return }
            do {
                let value = try await gate.finishNavigation(current, finalURL: url)
                guard !closed, self.current?.id == current.id else { return }
                finished = value
                settle(.success("ready"))
            } catch { settle(.failure(SourceBrowserFailure.navigationDenied)) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard navigation === self.navigation else { return }
        settle(.failure(SourceBrowserFailure.unavailable))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard navigation === self.navigation else { return }
        settle(.failure(SourceBrowserFailure.unavailable))
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { self.navigation = navigation }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        waits.invalidate(because: .webContentTerminated)
        close()
    }
    func close() {
        closed = true; waits.close(); loading = nil; current = nil; finished = nil; navigation = nil
        webView.navigationDelegate = nil; webView.stopLoading(); webView.removeFromSuperview()
    }
    private func settle(_ result: Result<String, any Error>) {
        guard let loading else { return }
        self.loading = nil; waits.resolve(loading, with: result)
    }
}
#endif
