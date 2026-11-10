import SwiftUI
import SnowlitCore
import SnowlitReader

struct ReaderView: View {
    let model: ReaderModel
    @State private var viewport = ReadingViewportController()
    @State private var showsCatalog = false
    @State private var showsSettings = false
    @State private var confirmsCacheClear = false
    @State private var closing = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                problemView(problem)
            }
            if let problem = model.persistenceProblem {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.ownershipLost ? "这本书的进度已被另一阅读会话更新。可以保留较新的进度并返回。" : problem.message)
                    Button("重试保存") { model.retrySave() }.frame(minHeight: 44)
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
            if model.chapters.isEmpty {
                Spacer()
                if model.isLoading { ProgressView("正在读取章节…") }
                Spacer()
            } else if let position = model.position {
                ReaderViewport(controller: viewport, model: model, position: position)
                    .accessibilityIdentifier("reader.viewport")
            }
            if let problem = model.adjacentProblem {
                HStack(spacing: 12) {
                    Text(problem.message).font(.caption)
                    Button("重试") { model.requestAdjacent() }.frame(minWidth: 44, minHeight: 44)
                }.padding(.horizontal).background(.bar)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(model.currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.currentTitle).font(.headline).lineLimit(1).accessibilityIdentifier("reader.current-chapter")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(model.ownershipLost ? "保留新进度并返回" : "返回") {
                    capturePosition()
                    closing = true
                    Task { if await model.close(acknowledgingNewerProgress: model.ownershipLost) { dismiss() }; closing = false }
                }.frame(minWidth: 44, minHeight: 44).disabled(closing).accessibilityIdentifier("reader.close")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showsSettings = true } label: { Image(systemName: "textformat.size") }
                    .frame(minWidth: 44, minHeight: 44).accessibilityLabel("阅读设置").accessibilityIdentifier("reader.settings")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 16) {
                Button { capturePosition(); model.move(by: -1) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("上一章").accessibilityIdentifier("reader.previous")
                    .frame(minWidth: 44, minHeight: 44).disabled((model.currentIndex ?? 0) == 0)
                Spacer()
                Button("目录") { capturePosition(); showsCatalog = true }.frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("reader.catalog")
                if model.isLoading { ProgressView().accessibilityLabel("正在读取章节") }
                Spacer()
                Button { capturePosition(); model.move(by: 1) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("下一章").accessibilityIdentifier("reader.next")
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(model.currentIndex == nil || model.currentIndex == model.entries.count - 1)
            }.padding(.horizontal, 20).padding(.vertical, 4).background(.bar)
        }
        .preferredColorScheme(model.preferences.theme == .system ? nil : (model.preferences.theme == .dark ? .dark : .light))
        .sheet(isPresented: $showsCatalog) {
            NavigationStack {
                List(Array(model.entries.enumerated()), id: \.offset) { index, entry in
                    Button { model.navigate(to: entry.reference); showsCatalog = false } label: {
                        HStack {
                            Text(entry.title)
                            Spacer()
                            if model.currentIndex == index { Image(systemName: "checkmark").accessibilityLabel("当前章节") }
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("reader.chapter.\(index)")
                }
                .navigationTitle("目录")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsCatalog = false }.frame(minWidth: 44, minHeight: 44) } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsSettings) { settings }
        .task { await model.open() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { capturePosition(); Task { await model.suspend() } }
        }
        .onDisappear { Task { _ = await model.close() } }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("文字") {
                    HStack(spacing: 16) {
                        Text("字号 · \(Int(model.preferences.fontSize))").accessibilityIdentifier("reader.font-size")
                        Spacer()
                        Button { model.updatePreferences(fontSize: model.preferences.fontSize - 2) } label: { Image(systemName: "minus") }
                            .frame(minWidth: 44, minHeight: 44).accessibilityLabel("减小字号")
                            .disabled(model.preferences.fontSize <= 14)
                        Button { model.updatePreferences(fontSize: model.preferences.fontSize + 2) } label: { Image(systemName: "plus") }
                            .frame(minWidth: 44, minHeight: 44).accessibilityLabel("增大字号")
                            .accessibilityIdentifier("reader.font.increase").disabled(model.preferences.fontSize >= 36)
                    }.buttonStyle(.borderless)
                    Picker("主题", selection: Binding(get: { model.preferences.theme }, set: { model.updatePreferences(theme: $0) })) {
                        Text("跟随系统").tag(ReaderPreferences.Theme.system)
                        Text("明亮").tag(ReaderPreferences.Theme.light)
                        Text("深色").tag(ReaderPreferences.Theme.dark)
                    }.accessibilityIdentifier("reader.theme")
                    if model.hasHiddenElements { Text("本章包含图片或段评描述；当前仅显示文字。描述随文档保留。").font(.caption).foregroundStyle(.secondary) }
                }
                Section("已读缓存") {
                    Toggle("仅使用本地缓存", isOn: Binding(get: { model.offlineOnly }, set: { model.setOfflineOnly($0) }))
                        .accessibilityIdentifier("reader.offline")
                    Text("文字缓存上限为 256 MiB。超出后优先清理最久未读的内容；缓存可以被清理，并非永久下载。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let usage = model.cacheUsage { Text("当前 \(usage.documents) 份文档 · \(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))") }
                    Button("清理文字缓存", role: .destructive) { confirmsCacheClear = true }.frame(minHeight: 44)
                    Text("清理保留书架、目录与进度，但被清理的文字需要重新获取。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("阅读设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsSettings = false }.frame(minWidth: 44, minHeight: 44) } }
            .confirmationDialog("清理所有已读文字缓存？", isPresented: $confirmsCacheClear, titleVisibility: .visible) {
                Button("清理缓存", role: .destructive) { Task { await model.clearCache() } }
                Button("取消", role: .cancel) {}
            }
        }.presentationDetents([.medium, .large])
    }

    private func problemView(_ problem: SourceBrowsingProblem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.needsResumeChoice ? "上次阅读的准确版本在缓存中不可用。旧进度已保留，请从目录选择章节重新开始。" : problem.message)
            HStack(spacing: 16) {
                Button("选择章节") { showsCatalog = true }.frame(minHeight: 44)
                if let index = model.currentIndex, !model.needsResumeChoice {
                    Button("重新获取") { model.navigate(to: model.entries[index].reference, reload: true) }.frame(minHeight: 44)
                }
            }
            Text("错误编号：\(problem.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.bar).accessibilityIdentifier("reader.failure")
    }

    private func capturePosition() {
        guard !model.chapters.isEmpty else { return }
        do { model.didDisplay(try viewport.capture().anchor, userScrolled: false) }
        catch { model.reportViewportFailure(error) }
    }
}

private struct ReaderViewport: UIViewControllerRepresentable {
    let controller: ReadingViewportController
    let model: ReaderModel
    let position: ReadingPosition
    func makeUIViewController(context: Context) -> ReadingViewportController {
        controller.onPosition = { [weak model] position, scrolled in
            // Deliver outside SwiftUI's update pass. The model rejects anchors
            // belonging to a window replaced before this finite hop runs.
            Task { @MainActor in model?.didDisplay(position, userScrolled: scrolled) }
        }
        controller.onFailure = { [weak model] error in Task { @MainActor in model?.reportViewportFailure(error) } }
        return controller
    }
    func updateUIViewController(_ controller: ReadingViewportController, context: Context) {
        do { try controller.update(window: .init(chapters: model.chapters), preferences: model.preferences,
            position: position, navigationID: model.navigationID) }
        catch { Task { @MainActor in model.reportViewportFailure(error) } }
    }
}
