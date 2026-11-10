import Foundation
import SnowlitCore
import SnowlitStorage
import Testing
@testable import Snowlit

@MainActor
struct ReaderModelTests {
    @Test func displayedPositionAndPreferencesPersistAndResumeWithoutWebsiteCalls() async throws {
        try await withFixture { fixture in
            let reader = fixture.reader(chapter: fixture.chapters[0])
            await reader.open()
            #expect(reader.problem == nil && reader.chapters.count == 1 && fixture.fetches == 1)
            let anchor = try ChapterTextProjection(document: reader.chapters[0].document).position(atUTF16Offset: 6)
            reader.didDisplay(anchor, userScrolled: false)
            reader.updatePreferences(fontSize: 26, theme: .dark)
            #expect(await reader.close())
            #expect(try await fixture.library.checkpoint(for: fixture.book.id)?.position == anchor)
            let resumed = fixture.reader(chapter: nil)
            await resumed.open()
            #expect(resumed.position == anchor && resumed.problem == nil)
            #expect(resumed.preferences.fontSize == 26 && resumed.preferences.theme == .dark && fixture.fetches == 1)
            #expect(await resumed.close())
        }
    }

    @Test func missingResumeRevisionRetainsProgressUntilExplicitChapterChoice() async throws {
        try await withFixture { fixture in
            let reader = fixture.reader(chapter: fixture.chapters[0]); await reader.open()
            let anchor = try #require(reader.position)
            reader.didDisplay(anchor, userScrolled: false)
            #expect(await reader.close())
            _ = try await fixture.library.trimChapterCache(toByteLimit: 0)
            let resumed = fixture.reader(chapter: nil); await resumed.open()
            #expect(resumed.needsResumeChoice && resumed.chapters.isEmpty && fixture.fetches == 1)
            #expect(try await fixture.library.checkpoint(for: fixture.book.id)?.position == anchor)
            resumed.navigate(to: fixture.chapters[1]); await resumed.waitForLoading()
            #expect(!resumed.needsResumeChoice && resumed.position?.chapter == fixture.chapters[1])
            #expect(await resumed.close())
        }
    }

    @Test func scrollingAdvancesABoundedWindowAndOfflineNavigationNeverInvokesSource() async throws {
        try await withFixture { fixture in
            let reader = fixture.reader(chapter: fixture.chapters[1]); await reader.open()
            reader.requestAdjacent(); await reader.waitForLoading()
            #expect(reader.chapters.count == 3 && fixture.fetches == 3)
            let third = try #require(reader.chapters.last?.document)
            reader.didDisplay(try ChapterTextProjection(document: third).position(atUTF16Offset: 0), userScrolled: true)
            await reader.waitForLoading()
            #expect(reader.chapters.count == 3 && reader.currentIndex == 2 && fixture.fetches == 4)
            #expect(reader.chapters.first?.document.content.chapter == fixture.chapters[1])
            reader.setOfflineOnly(true)
            reader.navigate(to: fixture.chapters[4]); await reader.waitForLoading()
            #expect(reader.problem != nil && fixture.fetches == 4)
            #expect(reader.position?.chapter == fixture.chapters[2])
            #expect(await reader.close())
        }
    }

    @Test func obsoleteReadingOwnerCannotSilentlyOverwriteOrHideAProgressFailure() async throws {
        try await withFixture { fixture in
            let old = fixture.reader(chapter: fixture.chapters[0]); await old.open()
            let fresh = fixture.reader(chapter: fixture.chapters[1]); await fresh.open()
            let freshPosition = try #require(fresh.position)
            fresh.didDisplay(freshPosition, userScrolled: false)
            #expect(await fresh.close())
            old.didDisplay(try #require(old.position), userScrolled: false)
            old.updatePreferences(fontSize: 22)
            #expect(!(await old.close()))
            #expect(old.persistenceProblem != nil)
            #expect(old.ownershipLost)
            #expect(try await fixture.library.checkpoint(for: fixture.book.id)?.position == freshPosition)
            #expect(await old.close(acknowledgingNewerProgress: true))
        }
    }

    @Test func changingChapterDuringAnUncooperativeFetchCannotPublishOldContent() async throws {
        try await withFixture { fixture in
            fixture.delayed = true
            let reader = fixture.reader(chapter: fixture.chapters[0])
            let opening = Task { await reader.open() }
            await fixture.started.wait()
            reader.navigate(to: fixture.chapters[1])
            fixture.delayed = false; fixture.release()
            await opening.value; await reader.waitForLoading()
            #expect(reader.position?.chapter == fixture.chapters[1])
            #expect(reader.chapters.count == 1)
            let discarded = try await fixture.library.cachedChapter(bookID: fixture.book.id, chapter: fixture.chapters[0], digest: Fixture.digest)
            #expect(discarded == nil)
            #expect(await reader.close())
        }
    }

    @Test func clearingCacheCancelsInFlightReadingBeforeRemovingSavedDocuments() async throws {
        try await withFixture { (fixture: Fixture) async throws -> Void in
            let reader = fixture.reader(chapter: fixture.chapters[0]); await reader.open()
            fixture.delayed = true
            reader.navigate(to: fixture.chapters[1])
            await fixture.started.wait()
            await reader.clearCache()
            #expect(try await fixture.library.chapterCacheUsage().documents == 0)
            fixture.release()
            #expect(await reader.close())
            #expect(try await fixture.library.chapterCacheUsage().documents == 0)
            #expect(try await fixture.library.books() == [fixture.book])
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitReader-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = try LibraryDatabase.create(at: directory.appendingPathComponent("library.sqlite"))
        do {
            let fixture = try await Fixture(library: library)
            try await body(fixture)
            try await library.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            do { try await library.close(); try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error, "Reader fixture cleanup failed") }
            throw error
        }
    }

    @MainActor
    private final class Fixture {
        let library: LibraryDatabase
        let book: LibraryBook
        let chapters: [ChapterReference]
        var fetches = 0, delayed = false
        let started = Signal()
        var waiter: CheckedContinuation<Void, Never>?
        init(library: LibraryDatabase) async throws {
            self.library = library
            let script = try SourceScriptSnapshot(bytes: Data("fixture".utf8), metadata: .init(sourceID: "org.example.reader",
                name: "Fixture", scriptVersion: "1", protocolVersion: 1, referenceVersion: 1, stateVersion: 1), digest: Self.digest)
            let receipt = try SourceImportRecord(scriptSHA256: script.sha256, inspectionContractSHA256: String(repeating: "f", count: 64), fileName: "fixture.js", importedAt: Date())
            try await library.stageSourceScript(script, receipt: receipt)
            let installed = try await library.installSource(importID: receipt.id, id: .init(), configuration: [], consent: .managedOnly)
            let savedBook = try await library.addBook(reference: .init(installationID: installed.id, referenceVersion: 1, key: "book"), title: "Book", author: nil)
            book = savedBook
            chapters = try (0..<5).map { try .init(book: savedBook.reference, key: "c\($0)") }
            let token = try await library.beginCatalogUpdate(for: book.id)
            try await library.publishCatalog(.init(book: book.reference, revision: "r1", entries: chapters.enumerated().map {
                .init(reference: $0.element, title: "Chapter \($0.offset)") }), using: token)
        }
        func reader(chapter: ChapterReference?) -> ReaderModel {
            .init(book: book, chapter: chapter, openLibrary: { self.library }, makeService: { library in
                ChapterAccessService(load: { try await library.cachedChapter(bookID: $0.book, chapter: $0.chapter, revision: $1, digest: Self.digest) },
                    begin: { try await library.beginChapterUpdate(bookID: $0.book, chapter: $0.chapter) },
                    revoke: { try await library.revokeChapterUpdate($0) }, fetch: { token in
                        self.fetches += 1
                        if self.delayed { await withCheckedContinuation { self.waiter = $0; self.started.send() } }
                        let content = try ChapterContent(chapter: token.resolved, sourceRevision: "r1", blocks: [
                            .paragraph(.init(id: "p", runs: [.text("hello 👩🏽‍💻 chapter \(token.resolved.key)", .init())]))])
                        return try .init(document: .init(content: content, digest: Self.digest), fromCache: false, diagnostics: [])
                    }, publish: { try await library.publishChapter($0, using: $1, digest: Self.digest) })
            })
        }
        func release() { waiter?.resume(); waiter = nil }
        nonisolated static let digest: LibraryDatabase.ChapterDigest = { bytes in
            var lanes = [UInt8](repeating: 0, count: 32)
            for (i, byte) in bytes.enumerated() { lanes[i % 32] = lanes[i % 32] &* 31 &+ byte }
            return lanes.map { String(format: "%02x", $0) }.joined()
        }
    }
    @MainActor
    private final class Signal {
        var sent = false
        var waiter: CheckedContinuation<Void, Never>?
        func send() { sent = true; waiter?.resume(); waiter = nil }
        func wait() async { if !sent { await withCheckedContinuation { waiter = $0 } } }
    }
}
