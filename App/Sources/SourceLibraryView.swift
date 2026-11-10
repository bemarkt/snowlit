import SwiftUI
import UniformTypeIdentifiers
import SnowlitCore
import YingxueKit

struct SourceLibraryView: View {
    let model: SourceLibraryModel
    @State private var showImporter = false
    @State private var showPreview = false
    @State private var selection: Selection?

    private struct Selection: Identifiable { let id = UUID(); let url: URL }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Snowlit")
                            .font(.headline)
                            .accessibilityIdentifier("startup.ready")
                        Text("书源连接网站，书架与阅读进度保存在本机。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                if let problem = model.problem, !showPreview {
                    Section {
                        Text(problem.message).foregroundStyle(.primary)
                        Button("重试") { refreshRequest += 1 }
                            .frame(minHeight: 44)
                        Text("错误编号：\(problem.id.uuidString)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if model.imports.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            Image(systemName: "books.vertical")
                                .font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                            Text("从一个书源开始").font(.title2.bold())
                            Text("选择映雪书源文件，先查看内容与所需权限。")
                                .foregroundStyle(.secondary)
                            Button("导入书源文件", systemImage: "doc.badge.plus") { showImporter = true }
                                .buttonStyle(.borderedProminent).frame(minHeight: 44)
                                .accessibilityIdentifier("sources.import")
                        }
                        .padding(.vertical, 16)
                    }
                } else {
                    Section("已导入") {
                        ForEach(model.imports) { item in
                            NavigationLink(value: item.id) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.script.metadata.name).font(.headline)
                                    Text("版本 \(item.script.metadata.scriptVersion) · \(status(item))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Text(item.receipt.fileName).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                            .accessibilityIdentifier("sources.saved.\(item.id.uuidString)")
                        }
                    }
                }
                if let name = model.savedName {
                    Section { Label("已保存“\(name)”", systemImage: "checkmark.circle").font(.subheadline) }
                }
            }
            .overlay { if model.isLoading && model.imports.isEmpty { ProgressView("正在读取书源…") } }
            .navigationTitle("书源")
            .toolbar {
                if !model.imports.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("导入", systemImage: "plus") { showImporter = true }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("sources.import")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let item = model.imports.first(where: { $0.id == id }) {
                    SourceScriptDetailView(script: item.script, receipt: item.receipt)
                }
            }
            .refreshable { model.clearProblem(); await model.refresh() }
        }
        .task(id: refreshRequest) { await model.refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.javaScript, .plainText, .data]) { result in
            switch result {
            case .success(let url):
                selection = .init(url: url)
                showPreview = true
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.fileSelectionFailed() }
            }
        }
        .task(id: selection?.id) {
            if let selection { await model.previewFile(selection.url) }
        }
        .sheet(isPresented: $showPreview, onDismiss: {
            model.cancelPreview(); selection = nil
        }) {
            SourceImportReviewView(model: model) { showPreview = false; selection = nil }
        }
    }

    @State private var refreshRequest = 0

    private func status(_ item: SourceLibraryModel.SavedImport) -> String {
        guard let installed = model.installations.first(where: { $0.importID == item.id }) else { return "待验证" }
        switch installed.state {
        case .enabled: return "已启用"
        case .disabled: return "已停用"
        case .removed: return "已移除，保留阅读数据"
        }
    }
}

private struct SourceImportReviewView: View {
    let model: SourceLibraryModel
    let dismiss: () -> Void
    @State private var saveRequest = 0

    var body: some View {
        NavigationStack {
            Form {
                if model.isInspecting {
                    Section { ProgressView("正在检查书源文件…").accessibilityIdentifier("sources.inspecting") }
                }
                if let problem = model.problem {
                    Section {
                        Text(problem.message).accessibilityIdentifier("sources.import.failure")
                        Text("错误编号：\(problem.id.uuidString)").font(.caption).textSelection(.enabled)
                    }
                }
                if let review = model.review {
                    Section("书源信息") {
                        Text(review.manifest.name).font(.title2.bold())
                        LabeledContent("版本", value: review.manifest.scriptVersion)
                        LabeledContent("标识", value: review.manifest.sourceID)
                            .textSelection(.enabled)
                        LabeledContent("文件", value: review.receipt.fileName)
                    }
                    Section("访问范围") {
                        if review.manifest.origins.isEmpty { Text("未声明网站访问") }
                        ForEach(Array(review.manifest.origins.enumerated()), id: \.offset) { _, origin in
                            Text("\(origin.scheme.rawValue)://\(origin.host)\(origin.port.map { ":\($0)" } ?? "")")
                                .textSelection(.enabled)
                        }
                        if review.manifest.capabilities.contains(.credentialsRead) {
                            Label("请求读取明文凭据", systemImage: "key")
                            Text("保存文件不会授予此权限，启用时需要单独确认。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let existing = review.existing {
                        Section(existing.state == .removed ? "恢复关联" : "已有书源") {
                            Text("本机保留 \(review.retainedBooks) 本关联书籍。")
                            if existing.state == .removed {
                                Text("恢复原关联需要在启用时明确确认。")
                            } else {
                                Text("当前版本：\(existing.metadata.scriptVersion)")
                            }
                            if review.upgrade?.referenceMigrationRequired == true || review.upgrade?.publicStateMigrationRequired == true {
                                Text("新版需要迁移已有引用或书源状态，验证通过后才能替换当前版本。")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        NavigationLink("查看完整脚本") {
                            SourceScriptDetailView(script: review.script, receipt: review.receipt)
                        }
                        Text("保存后可随时查看。书源通过运行验证后才能启用。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Section {
                        Button { saveRequest += 1 } label: {
                            HStack {
                                if model.isSaving { ProgressView() }
                                Text(model.isSaving ? "正在保存…" : "保存书源文件")
                            }.frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("sources.save")
                    }
                }
            }
            .navigationTitle("导入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.cancelPreview(); dismiss() }
                        .frame(minWidth: 44, minHeight: 44).disabled(model.isSaving)
                        .accessibilityIdentifier("sources.cancel")
                }
            }
        }
        .interactiveDismissDisabled(model.isSaving)
        .task(id: saveRequest) {
            guard saveRequest > 0 else { return }
            await model.saveReviewedImport()
            if model.review == nil && model.savedName != nil { dismiss() }
        }
    }
}

private struct SourceScriptDetailView: View {
    let script: SourceScriptSnapshot
    let receipt: SourceImportRecord

    var body: some View {
        List {
            Section("来源") {
                LabeledContent("文件", value: receipt.fileName)
                LabeledContent("导入时间") { Text(receipt.importedAt, style: .date) }
                LabeledContent("标识", value: script.metadata.sourceID).textSelection(.enabled)
                LabeledContent("版本", value: script.metadata.scriptVersion)
                DisclosureGroup("SHA-256 摘要") {
                    Text(script.sha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            Section("完整脚本 · 只读") {
                Text(String(decoding: script.bytes, as: UTF8.self))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("sources.script")
            }
        }
        .navigationTitle(script.metadata.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
