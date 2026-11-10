import SwiftUI

struct StartupView: View {
    let model: StartupModel
    let sources: SourceLibraryModel
    let management: SourceManagementModel
    let candidateValidator: SourceCandidateValidator
    let runtime: SourceRuntime
    let authentication: SourceAuthenticationModel
    let search: SourceSearchModel
    let shelf: LibraryShelfModel
    let backup: BackupModel
    let makeBook: @MainActor (SourceSearchModel.Item) -> SourceBookModel
    @State private var retry = 0

    var body: some View {
        Group {
            switch model.state {
            case .idle, .preparing:
                ProgressView("正在打开…")
            case .ready:
                LibraryRootView(sources: sources, management: management, candidateValidator: candidateValidator,
                    runtime: runtime, authentication: authentication, search: search, shelf: shelf, backup: backup, makeBook: makeBook)
            case .failed(let operationID):
                VStack(spacing: 16) {
                    Text("暂时无法打开")
                        .font(.title2.bold())
                        .accessibilityIdentifier("startup.failed")
                    Text("无法准备本地存储，请重试。")
                        .multilineTextAlignment(.center)
                    Text("错误编号：\(operationID.uuidString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("重试") {
                        retry += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("startup.retry")
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: retry) {
            await model.start()
        }
    }
}
