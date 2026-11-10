import Foundation
import Observation
import SnowlitCore
import YingxueKit

@MainActor
@Observable
final class SourceSearchModel {
    struct Item: Identifiable {
        let installation: SourceInstallationSnapshot
        let book: YingxueWire.BookSummary
        var id: Data { Data(book.reference.key.utf8) }
    }
    private(set) var items: [Item] = []
    private(set) var isLoading = false
    private(set) var hasSearched = false
    private(set) var wasCancelled = false
    private(set) var problem: SourceBrowsingProblem?
    private(set) var nextCursor: String?
    private var query = ""
    private var installation: SourceInstallationSnapshot?
    private var cursors = Set<Data>()
    @ObservationIgnored private let invoke: SourceInvocation
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var work: Task<YingxueWire.OperationReply, any Error>?

    init(invoke: @escaping SourceInvocation) { self.invoke = invoke }

    func search(_ text: String, using installation: SourceInstallationSnapshot) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { reset(); return }
        let id = UUID(), previous = work
        generation = id; previous?.cancel()
        self.query = query; self.installation = installation
        items = []; nextCursor = nil; cursors = []; problem = nil; hasSearched = true; isLoading = true; wasCancelled = false
        if let previous { _ = await previous.result }
        guard generation == id, !Task.isCancelled else { if generation == id { isLoading = false }; return }
        await page(cursor: nil, generation: id, installation: installation, query: query)
    }

    func loadMore() async {
        guard !isLoading, let nextCursor, let installation else { return }
        let id = UUID(), previous = work, query = query
        generation = id; isLoading = true; problem = nil; wasCancelled = false
        // A cancelled page still owns runtime cleanup. Returning from a detail
        // screen may resume the same cursor only after that work has finished.
        if let previous { _ = await previous.result }
        guard generation == id, !Task.isCancelled else { if generation == id { isLoading = false }; return }
        await page(cursor: nextCursor, generation: id, installation: installation, query: query)
    }

    func cancel() {
        if isLoading { wasCancelled = true }
        generation = nil; work?.cancel(); isLoading = false
    }

    func reset() { cancel(); items = []; hasSearched = false; wasCancelled = false; problem = nil; nextCursor = nil; installation = nil; cursors = [] }

    private func page(cursor: String?, generation id: UUID, installation: SourceInstallationSnapshot, query: String) async {
        let task = Task { @MainActor [invoke] in
            try await invoke(.search(.init(kind: .search, input: .init(query: query, cursor: cursor))), installation)
        }
        work = task
        defer { if generation == id { isLoading = false; work = nil } }
        do {
            let reply = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == id else { return }
            try checkedSourceReply(reply, operation: .search, installation: installation)
            guard case .search(let result) = reply else { throw SourceBrowsingFailure.invalidReply }
            if let next = result.value.nextCursor,
               cursors.contains(Data(next.utf8)) || cursor.map({ Data($0.utf8) == Data(next.utf8) }) == true {
                throw SourceBrowsingFailure.repeatedCursor
            }
            var seen = Set(items.map(\.id))
            let added = result.value.items.filter { seen.insert(Data($0.reference.key.utf8)).inserted }
            items += added.map { .init(installation: installation, book: $0) }
            if let cursor { cursors.insert(Data(cursor.utf8)) }
            nextCursor = result.value.nextCursor
        } catch {
            guard generation == id, !(error is CancellationError), !Task.isCancelled else { return }
            problem = .init(error)
        }
    }
}
