import Foundation
import Observation
import SnowlitCore
import YingxueKit

@MainActor
@Observable
final class SourceBookModel {
    let item: SourceSearchModel.Item
    private(set) var details: YingxueWire.BookDetails?
    private(set) var catalog: CatalogSnapshot?
    private(set) var saved: LibraryBook?
    private(set) var isLoading = false
    private(set) var isAdding = false
    private(set) var loadedPages = 0
    private(set) var problem: SourceBrowsingProblem?
    @ObservationIgnored private let invoke: SourceInvocation
    @ObservationIgnored private let save: @MainActor (SourceInstallationSnapshot, YingxueWire.BookDetails, CatalogSnapshot) async throws -> LibraryBook
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var work: Task<(YingxueWire.BookDetails, CatalogSnapshot), any Error>?

    init(item: SourceSearchModel.Item, invoke: @escaping SourceInvocation,
         save: @escaping @MainActor (SourceInstallationSnapshot, YingxueWire.BookDetails, CatalogSnapshot) async throws -> LibraryBook) {
        self.item = item; self.invoke = invoke; self.save = save
    }

    func load() async {
        guard !isAdding else { return }
        let id = UUID(), previous = work
        generation = id; previous?.cancel(); isLoading = true; problem = nil; loadedPages = 0
        if let previous { _ = await previous.result }
        guard generation == id, !Task.isCancelled else { if generation == id { isLoading = false }; return }
        let task = Task { @MainActor [self] in
            let installation = item.installation
            let reference = try SourceBookReference(installationID: installation.id,
                referenceVersion: installation.metadata.referenceVersion, key: item.book.reference.key)
            let reply = try await invoke(.book(.init(kind: .book, input: .init(reference: item.book.reference))), installation)
            try checkedSourceReply(reply, operation: .book, installation: installation)
            guard case .book(let detail) = reply, detail.value.reference.key.utf8.elementsEqual(reference.key.utf8) else {
                throw SourceBrowsingFailure.invalidReply
            }
            var assembly = CatalogAssembly(book: reference)
            var cursor: String?
            while true {
                try Task.checkCancellation()
                let reply = try await invoke(.chapters(.init(kind: .chapters, input: .init(book: item.book.reference, cursor: cursor))), installation)
                try checkedSourceReply(reply, operation: .chapters, installation: installation)
                guard case .chapters(let page) = reply, page.value.book.key.utf8.elementsEqual(reference.key.utf8) else {
                    throw SourceBrowsingFailure.invalidReply
                }
                let entries = try page.value.items.map { try CatalogEntry(reference: .init(book: reference, key: $0.key), title: $0.title) }
                let complete = try assembly.append(requestedCursor: cursor, revision: page.value.revision,
                    entries: entries, nextCursor: page.value.nextCursor)
                if generation == id { loadedPages += 1 }
                if let complete { return (detail.value, complete) }
                cursor = page.value.nextCursor
            }
        }
        work = task
        defer { if generation == id { isLoading = false; work = nil } }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == id else { return }
            details = value.0; catalog = value.1
        } catch {
            guard generation == id, !(error is CancellationError), !Task.isCancelled else { return }
            problem = .init(error)
        }
    }

    func addToLibrary() async {
        guard !isLoading, !isAdding, let details, let catalog else { return }
        isAdding = true; problem = nil
        defer { isAdding = false }
        do { saved = try await save(item.installation, details, catalog) }
        catch { if !(error is CancellationError), !Task.isCancelled { problem = .init(error) } }
    }

    func cancel() { generation = nil; work?.cancel(); isLoading = false }
}
