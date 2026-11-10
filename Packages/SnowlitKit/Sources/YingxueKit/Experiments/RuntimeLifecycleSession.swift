#if os(iOS) && DEBUG
import Foundation
import UIKit
import WebKit

/// Debug-only worker for the App's real background/foreground UI fixture.
@_spi(Experiments) @MainActor
public final class RuntimeLifecycleSession: NSObject, WKScriptMessageHandler {
    private let probe: WebKitRuntimeProbe
    private var entered: (@MainActor @Sendable () -> Void)?
    public var view: UIView { probe.webView }
    public private(set) var preparationStage = "document"

    public init(dataStore: WKWebsiteDataStore) {
        probe = WebKitRuntimeProbe(dataStore: dataStore)
        super.init()
    }

    public func prepare() async throws {
        preparationStage = "document"
        try await probe.loadHTML("<!doctype html><html><head><title>Lifecycle probe</title></head><body></body></html>")
        preparationStage = "javascript"
        guard try await probe.evaluate("return 'ready';") == "ready" else { throw Failure.invalidResult }
        preparationStage = "ready"
    }

    public func waitForInterruption(onEntered: @escaping @MainActor @Sendable () -> Void) async throws {
        entered = onEntered
        probe.webView.configuration.userContentController.add(self, name: "lifecycleEntered")
        _ = try await probe.evaluate("window.webkit.messageHandlers.lifecycleEntered.postMessage('entered'); return await new Promise(() => {});",
            timeout: .seconds(30))
    }

    public func close() {
        entered = nil
        probe.webView.configuration.userContentController.removeScriptMessageHandler(forName: "lifecycleEntered")
        probe.close()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === probe.webView, message.frameInfo.isMainFrame, message.body as? String == "entered" else { return }
        entered?()
        entered = nil
    }
    private enum Failure: Error { case invalidResult }
}
#endif
