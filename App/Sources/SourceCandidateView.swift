import SwiftUI
import UIKit
import WebKit

/// Keeps the execution view mounted until its owner completes cleanup, even
/// after the user cancels. A failed cleanup remains visible and retryable.
struct SourceCandidateView: View {
    let validator: SourceCandidateValidator
    let session: SourceCandidateSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var cleanupRequest = 0
    @State private var cleanupFailed = false

    var body: some View {
        let form = session.formSession?.form
        let web = session.webInteraction
        return NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(session.sourceName).font(.title2.bold())
                Text(session.sourceID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if session.phase == .cleanupRequired {
                    Label("验证会话尚未清理完成", systemImage: "exclamationmark.triangle")
                    Text("当前版本和原设置已保留。完成清理后可以重新验证。")
                        .foregroundStyle(.secondary)
                    Button("重试清理") { cleanupRequest += 1 }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .accessibilityIdentifier("sources.validation.retry-cleanup")
                    if cleanupFailed { Text("清理仍未完成，请重试。").accessibilityIdentifier("sources.validation.cleanup-failure") }
                } else {
                    ProgressView("正在验证书源…")
                        .accessibilityIdentifier("sources.validation.running")
                    Text("验证通过且临时会话清理完成后，才会采用此版本。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(uiColor: .systemBackground))
            .background(SourceCandidateContainer(session: session))
            .navigationTitle("验证书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消验证") { validator.cancel() }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(session.phase == .cleanupRequired)
                        .accessibilityIdentifier("sources.validation.cancel")
                }
            }
        }
        .interactiveDismissDisabled()
        .sheet(item: Binding(get: { form }, set: { value in
            if value == nil { form?.invalidate() }
        })) { form in SourceFormView(model: form) }
        .sheet(item: Binding(get: { web }, set: { value in
            if value == nil { web?.cancel() }
        })) { interaction in SourceWebInteractionView(interaction: interaction) }
        .task(id: cleanupRequest) {
            guard cleanupRequest > 0 else { return }
            cleanupFailed = false
            do { try await validator.retryCleanup() }
            catch { cleanupFailed = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { validator.cancel() }
        }
    }
}

private struct SourceCandidateContainer: UIViewRepresentable {
    let session: SourceCandidateSession
    func makeUIView(context: Context) -> SourceMountView {
        let view = SourceMountView()
        view.onMount = { [weak session] view in session?.attach(to: view) }
        return view
    }
    func updateUIView(_ view: SourceMountView, context: Context) { session.attach(to: view) }
}

private final class SourceMountView: UIView {
    var onMount: ((UIView) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMount?(self) }
    }
}

private struct SourceWebInteractionView: View {
    let interaction: SourceWebInteraction
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SourceWebsiteView(webView: interaction.view)
                .safeAreaInset(edge: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(interaction.sourceName).font(.headline)
                        Text("完成网页操作后返回，书源会继续校验网站状态。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.bar)
                }
                .navigationTitle(interaction.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { interaction.cancel() }.frame(minWidth: 44, minHeight: 44)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成网页操作") { interaction.complete() }.frame(minWidth: 44, minHeight: 44)
                    }
                }
        }
        .interactiveDismissDisabled()
        .onChange(of: interaction.finished) { _, finished in if finished { dismiss() } }
    }
}

private struct SourceWebsiteView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
