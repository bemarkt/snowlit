import SwiftUI
import SnowlitCore

struct LibraryShelfView: View {
    let model: LibraryShelfModel
    @State private var refresh = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("你的书架").font(.headline).accessibilityIdentifier("startup.ready")
                }
                if let problem = model.problem {
                    Section {
                        Text(problem.message).accessibilityIdentifier("library.failure")
                        Button("重试") { refresh += 1 }.frame(minHeight: 44)
                        Text("错误编号：\(problem.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if model.isLoading { ProgressView("正在读取书架…") }
                if model.books.isEmpty && !model.isLoading && model.problem == nil {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                            Text("把想读的书放在这里").font(.title2.bold())
                            Text("在搜索中选择书源，找到书籍后加入书架。").foregroundStyle(.secondary)
                        }.padding(.vertical, 16)
                    }
                }
                ForEach(model.books, id: \.id) { book in
                    NavigationLink {
                        LibraryCatalogView(book: book, model: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.title).font(.headline)
                            if let author = book.author { Text(author).font(.subheadline).foregroundStyle(.secondary) }
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("library.book")
                }
            }
            .navigationTitle("书架")
            .refreshable { await model.refresh() }
        }
        .task(id: refresh) { await model.refresh() }
    }
}

private struct LibraryCatalogView: View {
    let book: LibraryBook
    let model: LibraryShelfModel
    @State private var catalog: CatalogSnapshot?
    @State private var problem: SourceBrowsingProblem?
    @State private var isLoading = true
    @State private var retry = 0
    @State private var reader: ReaderModel?

    var body: some View {
        List {
            Section {
                Text(book.title).font(.title2.bold()).accessibilityIdentifier("library.book.title")
                if let author = book.author { Text(author).foregroundStyle(.secondary) }
                Button("继续阅读") { reader = model.makeReader?(book, nil) }
                    .frame(minHeight: 44).accessibilityIdentifier("library.resume")
            }
            if isLoading { ProgressView("正在读取目录…") }
            if let problem {
                Section {
                    Text(problem.message)
                    Button("重试") { retry += 1 }.frame(minHeight: 44)
                    Text("错误编号：\(problem.id)").font(.caption).textSelection(.enabled)
                }
            } else if let catalog {
                Section("目录 · \(catalog.entries.count) 章") {
                    ForEach(Array(catalog.entries.enumerated()), id: \.offset) { index, entry in
                        Button(entry.title) { reader = model.makeReader?(book, entry.reference) }
                            .frame(minHeight: 44).accessibilityIdentifier("library.chapter.\(index)")
                    }
                }
            } else if !isLoading {
                Text("本机尚未保存这本书的目录。").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("本地目录")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(get: { reader != nil }, set: { if !$0 { reader = nil } })) {
            if let reader { ReaderView(model: reader) }
        }
        .onChange(of: reader?.id) { _, value in if value == nil { Task { await model.refresh() } } }
        .task(id: retry) {
            isLoading = true; problem = nil
            defer { isLoading = false }
            do {
                let value = try await model.catalog(for: book.id)
                try Task.checkCancellation()
                catalog = value
            } catch {
                if !(error is CancellationError) && !Task.isCancelled {
                    problem = .init(error, fallback: "无法读取本地目录，请重试。")
                }
            }
        }
    }
}
