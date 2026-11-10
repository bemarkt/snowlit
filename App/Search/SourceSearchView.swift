import SwiftUI
import SnowlitCore

struct SourceSearchView: View {
    let model: SourceSearchModel
    let sources: SourceLibraryModel
    let makeBook: @MainActor (SourceSearchModel.Item) -> SourceBookModel
    @State private var query = ""
    @State private var selection: SourceInstallationSnapshot?
    @State private var searchRequest = 0
    @State private var moreRequest = 0
    @State private var detail: SourceBookModel?
    @State private var showDetail = false

    private var enabled: [SourceInstallationSnapshot] { sources.installations.filter(\.canExecute) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if enabled.isEmpty {
                        Text("请先在书源中导入并启用一个映雪书源。").foregroundStyle(.secondary)
                    } else {
                        Picker("搜索书源", selection: Binding(get: { selection?.id.rawValue }, set: { id in
                            model.reset(); selection = enabled.first { $0.id.rawValue == id }
                        })) {
                            ForEach(enabled, id: \.id) { source in Text(source.metadata.name).tag(Optional(source.id.rawValue)) }
                        }.accessibilityIdentifier("search.source")
                    }
                }
                if let problem = model.problem {
                    Section {
                        Text(problem.message).accessibilityIdentifier("search.failure")
                        Button("重新搜索") { searchRequest += 1 }.frame(minHeight: 44)
                        Text("错误编号：\(problem.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if model.wasCancelled {
                    Section {
                        Text("搜索已取消。已获取的结果保留。")
                        Button("重新搜索") { searchRequest += 1 }.frame(minHeight: 44)
                    }
                } else if model.hasSearched && !model.isLoading && model.items.isEmpty && model.problem == nil {
                    Section { Text("没有找到相关书籍，试试其他关键词。").foregroundStyle(.secondary) }
                }
                ForEach(model.items) { item in
                    Button {
                        model.cancel(); detail = makeBook(item); showDetail = true
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.book.title).font(.headline).foregroundStyle(.primary)
                            if let author = item.book.author { Text(author).font(.subheadline).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("search.result")
                }
                if model.isLoading {
                    Section {
                        ProgressView("正在搜索…")
                        Button("取消搜索") { model.cancel() }.frame(minHeight: 44)
                    }
                } else if model.nextCursor != nil {
                    Section { Button("加载更多") { moreRequest += 1 }.frame(minHeight: 44).accessibilityIdentifier("search.more") }
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "书名或作者")
            .onSubmit(of: .search) { if selection != nil { searchRequest += 1 } }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("搜索") { searchRequest += 1 }.frame(minWidth: 44, minHeight: 44)
                        .disabled(selection == nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("search.submit")
                }
            }
            .navigationDestination(isPresented: $showDetail) { if let detail { SourceBookView(model: detail) } }
        }
        .task { await sources.refresh(); synchronizeSelection() }
        .task(id: searchRequest) { if searchRequest > 0, let selection { await model.search(query, using: selection) } }
        .task(id: moreRequest) { if moreRequest > 0 { await model.loadMore() } }
        .onChange(of: sources.installations) { _, _ in synchronizeSelection() }
        .onDisappear { model.cancel() }
    }

    private func synchronizeSelection() {
        let current = enabled.first { $0.id == selection?.id } ?? enabled.first
        if current != selection { model.reset(); selection = current }
    }
}
