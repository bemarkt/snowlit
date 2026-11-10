import Foundation
import SnowlitCore
import SnowlitStorage
import Testing
import YingxueKit
@testable import Snowlit

@MainActor
struct SourceBrowsingModelTests {
    @Test func pagesDeduplicateExactReferencesAndResumeAfterLeavingSearch() async throws {
        let installed = try installation()
        var cursors: [String?] = []
        let model = SourceSearchModel { input, expected in
            #expect(expected == installed)
            guard case .search(let request) = input else { throw TestFailure.unexpected }
            #expect(request.input.query == "Novel")
            cursors.append(request.input.cursor)
            return searchReply(installed, keys: request.input.cursor == nil ? ["a", "a", "é", "e\u{301}"] : ["a", "b"],
                next: request.input.cursor == nil ? "second" : nil)
        }
        await model.search("  Novel  ", using: installed)
        #expect(model.items.count == 3 && model.nextCursor == "second")
        model.cancel()
        await model.loadMore()
        #expect(model.items.map(\.id) == ["a", "é", "e\u{301}", "b"].map { Data($0.utf8) })
        #expect(cursors.count == 2 && cursors[0] == nil && cursors[1] == "second")
        #expect(model.problem == nil && model.nextCursor == nil && !model.isLoading)
    }

    @Test func cancelledPageCannotPublishLateItemsAndTheSameCursorCanBeRetried() async throws {
        let installed = try installation(), pending = PendingReply()
        var calls = 0
        let model = SourceSearchModel { _, _ in
            calls += 1
            if calls == 1 { return searchReply(installed, keys: ["first"], next: "second") }
            if calls == 2 { return await pending.run() }
            return searchReply(installed, keys: ["retry"], next: nil)
        }
        await model.search("Novel", using: installed)
        let oldPage = Task { await model.loadMore() }
        await pending.waitUntilStarted()
        model.cancel()
        pending.finish(searchReply(installed, keys: ["late"], next: nil))
        await oldPage.value
        #expect(model.items.map(\.book.reference.key) == ["first"] && model.nextCursor == "second")
        #expect(model.wasCancelled && model.problem == nil)
        await model.loadMore()
        #expect(model.items.map(\.book.reference.key) == ["first", "retry"])
        #expect(!model.wasCancelled && model.nextCursor == nil)
    }

    @Test func aNewQueryWaitsForCancelledWorkAndOnlyItsResultsSurvive() async throws {
        let installed = try installation(), pending = PendingReply(), started = Signal()
        var queries: [String] = []
        let model = SourceSearchModel { input, _ in
            guard case .search(let request) = input else { throw TestFailure.unexpected }
            queries.append(request.input.query)
            if request.input.query == "old" { return await pending.run() }
            return searchReply(installed, keys: ["new"], next: nil)
        }
        let old = Task { await model.search("old", using: installed) }
        await pending.waitUntilStarted()
        let new = Task { started.send(); await model.search("new", using: installed) }
        await started.wait()
        #expect(queries == ["old"] && model.items.isEmpty)
        pending.finish(searchReply(installed, keys: ["late-old"], next: "old-page"))
        await old.value; await new.value
        #expect(queries == ["old", "new"] && model.items.map(\.book.reference.key) == ["new"])
        #expect(model.nextCursor == nil && model.problem == nil && !model.isLoading)
    }

    @Test func repeatedCursorRejectsTheWholePageAndEmptyQueryResetsPagination() async throws {
        let installed = try installation()
        var calls = 0
        let model = SourceSearchModel { _, _ in
            calls += 1
            return searchReply(installed, keys: [calls == 1 ? "first" : "rejected"], next: "same")
        }
        await model.search("Novel", using: installed)
        await model.loadMore()
        #expect(model.items.map(\.book.reference.key) == ["first"] && model.problem != nil)
        await model.search(" \n", using: installed)
        await model.loadMore()
        #expect(calls == 2 && model.items.isEmpty && !model.hasSearched && model.nextCursor == nil)
    }

    @Test func authenticationAndWrongInstallationAreVisibleFailures() async throws {
        let installed = try installation(), other = try installation()
        let auth = SourceSearchModel { _, _ in
            .failure(.init(kind: .failure, context: context(installed), operation: .search,
                error: .init(code: .needsAuthentication, stage: .execute, retryable: true)))
        }
        await auth.search("Novel", using: installed)
        #expect(auth.problem?.needsAuthentication == true && auth.items.isEmpty)
        let wrong = SourceSearchModel { _, _ in searchReply(other, keys: ["wrong"], next: nil) }
        await wrong.search("Novel", using: installed)
        #expect(wrong.problem != nil && wrong.items.isEmpty)
    }

    @Test func completeCatalogIsPublishedOnceAndPassedToAtomicAdoption() async throws {
        let installed = try installation(), pending = PendingReply()
        var saves = 0
        let model = bookModel(installed, invoke: { input, _ in
            switch input {
            case .book: return bookReply(installed)
            case .chapters(let request):
                if request.input.cursor == nil { return chaptersReply(installed, keys: ["c1"], next: "second") }
                #expect(request.input.cursor == "second")
                return await pending.run()
            default: throw TestFailure.unexpected
            }
        }, save: { expected, details, catalog in
            saves += 1
            #expect(expected == installed && details.title == "Novel")
            #expect(catalog.entries.map(\.reference.key) == ["c1", "c2"])
            return .init(id: .init(), reference: catalog.book, title: details.title, author: details.author)
        })
        let loading = Task { await model.load() }
        await pending.waitUntilStarted()
        #expect(model.catalog == nil && model.details == nil && model.loadedPages == 1)
        await model.addToLibrary()
        #expect(saves == 0)
        pending.finish(chaptersReply(installed, keys: ["c2"], next: nil))
        await loading.value
        #expect(model.loadedPages == 2 && model.catalog?.entries.count == 2)
        await model.addToLibrary()
        #expect(saves == 1 && model.saved != nil && model.problem == nil)
    }

    @Test(arguments: ["revision", "cursor", "duplicate", "book"])
    func invalidLaterPageKeepsThePreviousCompleteCatalog(_ fault: String) async throws {
        let installed = try installation()
        let state = ScenarioState()
        let model = bookModel(installed, invoke: { input, _ in
            switch input {
            case .book: return bookReply(installed)
            case .chapters(let request):
                if !state.refresh { return chaptersReply(installed, keys: ["original"], next: nil) }
                if request.input.cursor == nil { return chaptersReply(installed, keys: ["c1"], next: "next") }
                return chaptersReply(installed, keys: fault == "duplicate" ? ["c1"] : ["c2"],
                    next: fault == "cursor" ? "next" : nil,
                    revision: fault == "revision" ? "changed" : "r1", key: fault == "book" ? "other" : "book")
            default: throw TestFailure.unexpected
            }
        })
        await model.load()
        let original = try #require(model.catalog)
        state.refresh = true
        await model.load()
        #expect(model.catalog == original && model.problem != nil && !model.isLoading)
    }

    @Test func cancelledCatalogCannotPublishAndFailedSaveCanBeRetried() async throws {
        let installed = try installation(), pending = PendingReply()
        let state = ScenarioState()
        let model = bookModel(installed, invoke: { input, _ in
            if case .book = input { return bookReply(installed) }
            if state.delay { return await pending.run() }
            return chaptersReply(installed, keys: ["valid"], next: nil)
        }, save: { _, details, catalog in
            if state.failSave { throw TestFailure.unexpected }
            return .init(id: .init(), reference: catalog.book, title: details.title, author: nil)
        })
        let loading = Task { await model.load() }
        await pending.waitUntilStarted()
        model.cancel()
        pending.finish(chaptersReply(installed, keys: ["late"], next: nil))
        await loading.value
        #expect(model.catalog == nil && model.problem == nil && !model.isLoading)
        state.delay = false
        await model.load(); await model.addToLibrary()
        #expect(model.saved == nil && model.catalog?.entries.first?.reference.key == "valid" && model.problem != nil)
        state.failSave = false
        await model.addToLibrary()
        #expect(model.saved != nil && model.problem == nil && !model.isAdding)
    }

    private func bookModel(_ installed: SourceInstallationSnapshot, invoke: @escaping SourceInvocation,
        save: @escaping @MainActor (SourceInstallationSnapshot, YingxueWire.BookDetails, CatalogSnapshot) async throws -> LibraryBook = { _, _, _ in throw TestFailure.unexpected }) -> SourceBookModel {
        .init(item: .init(installation: installed, book: .init(reference: .init(key: "book"), title: "Search title")), invoke: invoke, save: save)
    }

    private func installation() throws -> SourceInstallationSnapshot {
        try .init(id: .init(), importID: UUID(), scriptSHA256: String(repeating: "a", count: 64),
            metadata: .init(sourceID: "org.example.browsing", name: "Fixture", scriptVersion: "1",
                protocolVersion: 1, referenceVersion: 1, stateVersion: 1), revision: 1, state: .enabled,
            configuration: [], allowsCredentialRead: false, websiteSessionID: UUID(), pendingCleanup: nil)
    }
    private func context(_ installed: SourceInstallationSnapshot) -> YingxueWire.OperationContext {
        .init(requestID: UUID().uuidString.lowercased(), installationID: installed.id.rawValue.uuidString.lowercased(),
            scriptSHA256: installed.scriptSHA256, configurationRevision: installed.revision,
            sessionRevision: installed.revision, generation: UUID().uuidString.lowercased())
    }
    private func searchReply(_ installed: SourceInstallationSnapshot, keys: [String], next: String?) -> YingxueWire.OperationReply {
        .search(.init(kind: .search, context: context(installed), value: .init(items: keys.map {
            .init(reference: .init(key: $0), title: "Same title")
        }, nextCursor: next)))
    }
    private func bookReply(_ installed: SourceInstallationSnapshot) -> YingxueWire.OperationReply {
        .book(.init(kind: .book, context: context(installed), value: .init(reference: .init(key: "book"), title: "Novel")))
    }
    private func chaptersReply(_ installed: SourceInstallationSnapshot, keys: [String], next: String?, revision: String = "r1", key: String = "book") -> YingxueWire.OperationReply {
        .chapters(.init(kind: .chapters, context: context(installed), value: .init(book: .init(key: key), revision: revision,
            items: keys.map { .init(key: $0, title: $0) }, nextCursor: next)))
    }
    private enum TestFailure: Error { case unexpected }

    @MainActor
    private final class ScenarioState {
        var refresh = false
        var delay = true
        var failSave = true
    }

    @MainActor
    private final class Signal {
        private var sent = false
        private var waiter: CheckedContinuation<Void, Never>?
        func send() { sent = true; waiter?.resume(); waiter = nil }
        func wait() async { if !sent { await withCheckedContinuation { waiter = $0 } } }
    }

    @MainActor
    private final class PendingReply {
        private let started = Signal()
        private var continuation: CheckedContinuation<YingxueWire.OperationReply, Never>?
        func run() async -> YingxueWire.OperationReply {
            await withCheckedContinuation { continuation = $0; started.send() }
        }
        func waitUntilStarted() async { await started.wait() }
        func finish(_ value: YingxueWire.OperationReply) { continuation?.resume(returning: value); continuation = nil }
    }
}
