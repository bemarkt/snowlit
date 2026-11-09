import SwiftUI

struct StartupView: View {
    let model: StartupModel
    @State private var retry = 0

    var body: some View {
        Group {
            switch model.state {
            case .idle, .preparing:
                ProgressView("正在打开…")
            case .ready:
                VStack(spacing: 16) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Snowlit")
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("startup.ready")
                    Text("从一本好书开始")
                        .foregroundStyle(.secondary)
                }
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
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: retry) {
            await model.start()
        }
    }
}
