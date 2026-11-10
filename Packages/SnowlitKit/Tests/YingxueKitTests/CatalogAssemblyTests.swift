import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct CatalogAssemblyTests {
    @Test func onlyExplicitEndProducesACompleteCatalog() throws {
        let book = try reference()
        var operation = CatalogAssembly(book: book)
        #expect(try operation.append(requestedCursor: nil, revision: "r1",
            entries: [entry(book, "a")], nextCursor: "next") == nil)
        let completed = try operation.append(requestedCursor: "next", revision: "r1",
            entries: [entry(book, "b")], nextCursor: nil)
        let result = try #require(completed)
        #expect(result.entries.map(\.reference.key) == ["a", "b"])
        #expect(throws: CatalogAssembly.Failure.alreadyFinished) {
            try operation.append(requestedCursor: nil, revision: "r1", entries: [], nextCursor: nil)
        }
    }

    @Test func cyclesAndChangedRevisionsInvalidateTheWholeOperation() throws {
        let book = try reference()
        var cycle = CatalogAssembly(book: book)
        _ = try cycle.append(requestedCursor: nil, revision: "r1", entries: [entry(book, "a")], nextCursor: "x")
        _ = try cycle.append(requestedCursor: "x", revision: "r1", entries: [], nextCursor: "y")
        #expect(throws: CatalogAssembly.Failure.repeatedCursor) {
            try cycle.append(requestedCursor: "y", revision: "r1", entries: [], nextCursor: "x")
        }
        #expect(throws: CatalogAssembly.Failure.invalidated) {
            try cycle.append(requestedCursor: "y", revision: "r1", entries: [], nextCursor: nil)
        }
        var changed = CatalogAssembly(book: book)
        _ = try changed.append(requestedCursor: nil, revision: "r1", entries: [entry(book, "a")], nextCursor: "next")
        #expect(throws: CatalogAssembly.Failure.changedRevision) {
            try changed.append(requestedCursor: "next", revision: "r2", entries: [entry(book, "b")], nextCursor: nil)
        }
    }

    @Test func duplicateChaptersAndOutOfOrderPagesCannotBecomeSuccess() throws {
        let book = try reference()
        var duplicate = CatalogAssembly(book: book)
        _ = try duplicate.append(requestedCursor: nil, revision: "r1", entries: [entry(book, "a")], nextCursor: "next")
        #expect(throws: LibraryModelError.duplicateChapter) {
            try duplicate.append(requestedCursor: "next", revision: "r1", entries: [entry(book, "a")], nextCursor: nil)
        }
        var wrong = CatalogAssembly(book: book)
        #expect(throws: CatalogAssembly.Failure.unexpectedCursor) {
            try wrong.append(requestedCursor: "not-first", revision: "r1", entries: [], nextCursor: nil)
        }
    }

    @Test func opaqueCursorsDoNotNormalizeDistinctUnicodeSpellings() throws {
        let book = try reference()
        var operation = CatalogAssembly(book: book)
        _ = try operation.append(requestedCursor: nil, revision: "r1", entries: [entry(book, "a")], nextCursor: "é")
        _ = try operation.append(requestedCursor: "é", revision: "r1", entries: [], nextCursor: "e\u{301}")
        let result = try operation.append(requestedCursor: "e\u{301}", revision: "r1", entries: [], nextCursor: nil)
        #expect(result?.entries.count == 1)
    }

    private func reference() throws -> SourceBookReference {
        try SourceBookReference(installationID: SourceInstallationID(), referenceVersion: 1, key: "book")
    }
    private func entry(_ book: SourceBookReference, _ key: String) throws -> CatalogEntry {
        try CatalogEntry(reference: ChapterReference(book: book, key: key), title: "同名")
    }
}
