import Foundation
import WebKit
import YingxueKit

/// Runs only the bundled parser. The author's complete file is an argument,
/// never an evaluated program, and this context has no source host capabilities.
@MainActor
enum SourceFileInspector {
    static func inspect(_ source: String, requirements: [String]) async throws -> Data {
        let operation = try Inspection(source: source, requirements: requirements)
        return try await operation.run()
    }
}

@MainActor
private final class Inspection: NSObject, WKNavigationDelegate {
    private enum Failure: Error { case unavailable, timedOut, invalidResult }
    private let program: SourceInspectionProgram
    private let source: String
    private let requirements: [String]
    private let webView: WKWebView
    private var navigation: WKNavigation?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var deadline: Task<Void, Never>?

    init(source: String, requirements: [String]) throws {
        program = try SourceInspectionProgram()
        self.source = source; self.requirements = requirements
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func run() async throws -> Data {
        let result: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                // One finite deadline owned by this inspection; all completion
                // paths cancel it. A timeout is a failed wait, not proof of JS termination.
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    self?.finish(.failure(Failure.timedOut))
                }
                navigation = webView.loadHTMLString("""
                    <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'"><title>Source inspection</title>
                    """, baseURL: nil)
                if navigation == nil { finish(.failure(Failure.unavailable)) }
            }
        } onCancel: {
            // A bounded actor hop settles this operation, with no background worker.
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        return result
    }

    func webView(_ webView: WKWebView, didFinish completed: WKNavigation!) {
        guard completed === navigation, continuation != nil else { return }
        navigation = nil
        webView.callAsyncJavaScript(program.bootstrap + "\n" + program.evaluationBody,
            arguments: ["source": source, "requirements": requirements], in: nil,
            in: .world(name: "Snowlit.SourceInspection")) { [weak self] result in
                switch result {
                case .success(let value):
                    guard let value = value as? String else { self?.finish(.failure(Failure.invalidResult)); return }
                    self?.finish(.success(Data(value.utf8)))
                case .failure(let error): self?.finish(.failure(error))
                }
            }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(Failure.unavailable)) }

    private func finish(_ result: Result<Data, any Error>) {
        guard let waiting = continuation else { return }
        continuation = nil
        deadline?.cancel(); deadline = nil
        navigation = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        waiting.resume(with: result)
    }
}
