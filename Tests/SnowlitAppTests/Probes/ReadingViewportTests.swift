#if os(iOS)
import CryptoKit
import SnowlitCore
import SnowlitReader
import Testing
import UIKit

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ReadingViewportTests {
    @Test func productionWindowRetainsExactVisibleTextAcrossChapterFontThemeAndWidthChanges() throws {
        let book = try SourceBookReference(installationID: .init(), referenceVersion: 1, key: "book")
        let chapters = try (0..<5).map { n in
            let content = try ChapterContent(chapter: .init(book: book, key: "c\(n)"), sourceRevision: "r1", blocks: (0..<40).map { p in
                .paragraph(.init(id: "p\(p)", runs: [.text(String(repeating: "中文 repeated 👩🏽‍💻 e\u{301}。", count: 12), .init(strong: p == 0))]))
            })
            return try ReadingWindow.Chapter(title: "Chapter \(n)", document: .init(content: content, digest: Self.digest))
        }
        let controller = ReadingViewportController()
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        controller.view.layoutIfNeeded()
        let id = UUID(), initial = try ChapterTextProjection(document: chapters[0].document).position(atUTF16Offset: 0)
        try controller.update(window: .init(chapters: Array(chapters[0...2])), preferences: .defaults, position: initial, navigationID: id)
        var preferences = ReaderPreferences.defaults
        for (index, range) in [(2, 1...3), (3, 2...4), (2, 1...3), (1, 0...2)] {
            let document = chapters[index].document
            let anchor = try ReadingPosition(chapter: document.content.chapter, documentRevision: document.revision,
                normalizationVersion: 1, elementID: "p10", utf16Offset: 0)
            let expectedWindow = try ReadingWindow(chapters: Array(chapters[range]))
            // Make the target chapter resident in the intended window before
            // measuring an exact offset; a chapter at a window edge may not have
            // enough following text to place it 80pt below the top.
            let current = try controller.capture()
            try controller.update(window: expectedWindow, preferences: preferences,
                position: current.anchor, navigationID: id)
            try controller.restore(.init(anchor: anchor, y: 80))
            let restoredY = try controller.visibleY(of: anchor)
            #expect(abs(restoredY - 80) <= 1)
            let visible = try controller.capture()
            #expect(visible.anchor.chapter == document.content.chapter)
            for (width, size, theme) in [(390.0, 28.0, ReaderPreferences.Theme.dark), (844.0, 18.0, .light), (390.0, 20.0, .system)] {
                // Each reflow preserves the anchor that is visible immediately
                // before it. Measuring an anchor captured several reflows ago
                // would assert against a position the reader no longer shows.
                let before = try controller.capture()
                controller.view.frame.size.width = width
                preferences = try .init(fontSize: size, theme: theme)
                try controller.update(window: expectedWindow, preferences: preferences,
                    position: before.anchor, navigationID: id)
                let measuredY = try controller.visibleY(of: before.anchor)
                let captured = try controller.capture()
                print("ReadingWindowCheck chapter=\(index) width=\(width) size=\(size) expectedY=\(before.y) measuredY=\(measuredY) expectedElement=\(before.anchor.elementID) capturedElement=\(captured.anchor.elementID)")
                #expect(abs(measuredY - before.y) <= 1)
                #expect(captured.anchor.chapter == document.content.chapter)
                #expect(controller.textView.textLayoutManager != nil)
                #expect(controller.textView.text.contains("👩🏽‍💻"))
                #expect(controller.textView.attributedText.length == expectedWindow.text.utf16.count)
            }
        }
    }

    @Test func changingDocumentRejectsAStaleAnchorBeforeReplacingVisibleText() throws {
        let book = try SourceBookReference(installationID: .init(), referenceVersion: 1, key: "book")
        let chapter = try ChapterReference(book: book, key: "c")
        func value(_ text: String) throws -> ChapterDocument {
            try .init(content: .init(chapter: chapter, sourceRevision: text,
                blocks: [.paragraph(.init(id: "p", runs: [.text(text, .init())]))]), digest: Self.digest)
        }
        let old = try value("original"), fresh = try value("new text")
        let controller = ReadingViewportController()
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        controller.view.layoutIfNeeded()
        let id = UUID(), anchor = try ChapterTextProjection(document: old).position(atUTF16Offset: 0)
        try controller.update(window: .init(chapters: [.init(title: "Title", document: old)]), preferences: .defaults, position: anchor, navigationID: id)
        #expect(throws: ChapterContentError.differentDocument) {
            try controller.update(window: .init(chapters: [.init(title: "Title", document: fresh)]), preferences: .defaults, position: anchor, navigationID: id)
        }
        #expect(controller.textView.text.contains("original"))
    }

    nonisolated private static let digest: @Sendable (Data) throws -> String = {
        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
