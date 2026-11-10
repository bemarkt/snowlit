import Foundation
import Testing
@testable import SnowlitCore

struct ReadingWindowTests {
    @Test func identicalParagraphsStayBoundToTheirChapterAndRevision() throws {
        let values = try chapters()
        let window = try ReadingWindow(chapters: values)
        for segment in window.segments {
            let anchor = try segment.projection.position(atUTF16Offset: 0)
            #expect(try window.offset(of: anchor) == segment.textRange.location)
            #expect(try window.position(near: segment.titleRange.location) == anchor)
        }
        let original = try window.segments[1].projection.position(atUTF16Offset: 0)
        let changed = try ReadingPosition(chapter: original.chapter, documentRevision: "changed", normalizationVersion: 1, elementID: original.elementID, utf16Offset: 0)
        #expect(throws: ChapterContentError.differentDocument) { try window.offset(of: changed) }
        let shifted = try ReadingWindow(chapters: Array(values.dropFirst()))
        #expect(try shifted.offset(of: original) == shifted.segments[0].textRange.location)
        let removed = try window.segments[0].projection.position(atUTF16Offset: 0)
        #expect(throws: ReadingWindow.Failure.unavailablePosition) { try shifted.offset(of: removed) }
    }

    @Test func viewportHitTestingDoesNotSplitEmojiOrNormalizeStoredAnchors() throws {
        let window = try ReadingWindow(chapters: chapters())
        for segment in window.segments {
            let start = try segment.projection.position(atUTF16Offset: 0)
            for offset in 0..<"👩🏽‍💻".utf16.count {
                #expect(try window.position(near: segment.textRange.location + offset) == start)
            }
            let invalid = try ReadingPosition(chapter: start.chapter, documentRevision: start.documentRevision,
                normalizationVersion: 1, elementID: start.elementID, utf16Offset: 1)
            #expect(throws: ChapterContentError.invalidTextBoundary) { try window.offset(of: invalid) }
        }
        #expect(throws: ReadingWindow.Failure.invalidWindow) { try ReadingWindow(chapters: []) }
        #expect(throws: ReadingWindow.Failure.invalidWindow) { try ReadingWindow(chapters: window.chapters + [window.chapters[0]]) }
        let other = try SourceBookReference(installationID: window.chapters[0].document.content.chapter.book.installationID, referenceVersion: 1, key: "different-book")
        let content = try ChapterContent(chapter: .init(book: other, key: "c0"), sourceRevision: "r1",
            blocks: [.paragraph(.init(id: "p", runs: [.text("same text", .init())]))])
        let foreign = try ReadingWindow.Chapter(title: "Same heading", document: .init(content: content, digest: { _ in String(repeating: "a", count: 64) }))
        #expect(throws: ReadingWindow.Failure.invalidWindow) { try ReadingWindow(chapters: [window.chapters[0], foreign]) }
    }

    private func chapters() throws -> [ReadingWindow.Chapter] {
        let book = try SourceBookReference(installationID: .init(), referenceVersion: 1, key: "book")
        return try (0..<3).map { n in
            let content = try ChapterContent(chapter: .init(book: book, key: "c\(n)"), sourceRevision: "r1", blocks: [
                .paragraph(.init(id: "p", runs: [.text("👩🏽‍💻 repeated", .init())]))])
            return try .init(title: "Same heading", document: .init(content: content, digest: { _ in String(repeating: "a", count: 64) }))
        }
    }
}
