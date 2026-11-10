import SwiftUI
import SnowlitCore

struct SourceBookView: View {
    let model: SourceBookModel
    @State private var reload = 0
    @State private var add = 0

    var body: some View {
        List {
            Section {
                Text(model.details?.title ?? model.item.book.title).font(.title2.bold())
                    .accessibilityIdentifier("book.title")
                if let author = model.details?.author ?? model.item.book.author { Text(author).foregroundStyle(.secondary) }
                Text(model.item.installation.metadata.name).font(.caption).foregroundStyle(.secondary)
                if let summary = model.details?.summary { Text(summary).textSelection(.enabled) }
            }
            if let problem = model.problem {
                Section {
                    Text(problem.message).accessibilityIdentifier("book.failure")
                    Button("重新获取详情与目录") { reload += 1 }.frame(minHeight: 44)
                    Text("错误编号：\(problem.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if model.isLoading {
                Section {
                    ProgressView("正在获取完整目录…")
                    if model.loadedPages > 0 { Text("已获取 \(model.loadedPages) 页目录").foregroundStyle(.secondary) }
                    Button("取消获取") { model.cancel() }.frame(minHeight: 44)
                }
            } else if model.catalog == nil && model.problem == nil {
                Section { Button("获取详情与目录") { reload += 1 }.frame(minHeight: 44) }
            }
            if let catalog = model.catalog {
                Section("目录 · \(catalog.entries.count) 章") {
                    ForEach(Array(catalog.entries.enumerated()), id: \.offset) { index, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            Text(entry.title).accessibilityIdentifier("book.chapter.\(index)")
                        }.frame(minHeight: 44)
                    }
                }
            }
        }
        .navigationTitle("书籍详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button { add += 1 } label: {
                HStack {
                    if model.isAdding { ProgressView() }
                    Text(model.saved == nil ? "加入书架" : "已在书架")
                }.frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.saved != nil || model.catalog == nil || model.isAdding || model.isLoading)
            .accessibilityIdentifier("book.add")
            .padding().background(.bar)
        }
        .task(id: reload) { await model.load() }
        .task(id: add) { if add > 0 { await model.addToLibrary() } }
        .onDisappear { model.cancel() }
    }
}
