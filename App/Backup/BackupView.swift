import SwiftUI
import SnowlitStorage
import UniformTypeIdentifiers

struct BackupView: View {
    let model: BackupModel
    @State private var includeCache = false
    @State private var showImporter = false
    @State private var request: BackupModel.Request?

    var body: some View {
        Form {
            Section {
                Text("保存你的书架与阅读位置").font(.headline)
                Text("备份包含书源脚本、书架、目录、阅读进度、设置与书源公有状态。网站登录信息不会导出，恢复后需要重新登录。")
                    .foregroundStyle(.secondary)
            }
            Section("导出备份") {
                Toggle("包含已读章节缓存", isOn: $includeCache).frame(minHeight: 44).disabled(model.isBusy)
                Text("包含缓存后，可在恢复后离线阅读这些章节；备份文件也会更大。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("生成备份") { request = .init(action: .export(includeCache: includeCache)) }
                    .frame(minHeight: 44).disabled(model.isBusy).accessibilityIdentifier("backup.export")
                if let exported = model.exported {
                    summary(exported.summary)
                    ShareLink(item: exported.file) { Label("保存备份文件", systemImage: "square.and.arrow.up") }
                        .frame(minHeight: 44).accessibilityIdentifier("backup.share")
                }
            }
            Section("检查备份") {
                Button("选择备份文件") { showImporter = true }
                    .frame(minHeight: 44).disabled(model.isBusy).accessibilityIdentifier("backup.choose")
                if let preview = model.preview {
                    Text("备份检查通过").font(.headline).accessibilityIdentifier("backup.preview.ready")
                    summary(preview)
                    Text("本机数据尚未替换。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if model.isBusy {
                Section {
                    ProgressView("正在处理备份…")
                    Button("取消") { request = nil }.frame(minHeight: 44)
                }
            }
            if let problem = model.problem {
                Section {
                    Text(problem.message).accessibilityIdentifier("backup.failure")
                    Text("错误编号：\(problem.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("备份")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let file): request = .init(action: .preview(file))
            case .failure(let error): model.report(error)
            }
        }
        .task(id: request?.id) { if let request { await model.run(request.action) } }
        .onDisappear { request = nil }
    }

    private func summary(_ value: LibraryBackupSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value.createdAt, format: .dateTime.year().month().day().hour().minute())
            Text("\(value.books) 本书 · \(value.sources) 个书源")
            Text(value.includesCache ? "包含 \(value.cachedChapters) 份已读章节" : "不包含章节缓存")
        }.font(.subheadline)
    }
}
