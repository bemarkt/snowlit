#if os(iOS)
import CoreText
@testable import SnowlitCore
import Testing
import UIKit
@testable import SnowlitReader

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ReaderProbeTests {
    @Test func chapterWindowPreservesVisibleIdentityAcrossForwardAndReverseReplacement() throws {
        let documents = try (0..<5).map { number in
            try ProbeDocument(id: "window-chapter-\(number)", paragraphs: (0..<24).map { paragraph in
                ProbeParagraph(id: "p\(paragraph)", runs: [.text(String(repeating: "重复中文 👩🏽‍💻 e\u{301}。", count: 12))])
            })
        }
        let window = ProbeChapterWindow()
        window.loadViewIfNeeded()
        window.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        try window.render(Array(documents[0...2]), fontSize: 20)
        for _ in 0..<3 {
            // Move across a real chapter boundary before replacing the preceding chapter.
            for (chapterIndex, range) in [(2, 1...3), (3, 2...4), (2, 1...3), (1, 0...2)] {
                let document = documents[chapterIndex]
                let target = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                              paragraphID: "p12", utf16Offset: 0)
                try window.restore(.init(anchor: target, y: 80))
                let visible = try window.capture()
                #expect(visible.anchor.documentID == document.id)
                for (width, size) in [(CGFloat(390), CGFloat(28)), (844, 18), (390, 20)] {
                    window.view.frame.size.width = width
                    try window.render(Array(documents[range]), fontSize: size, maintaining: visible)
                    #expect(abs(try window.visibleY(of: visible.anchor) - visible.y) <= 1)
                    #expect(try window.capture().anchor.documentID == document.id)
                    #expect(window.textView.textLayoutManager != nil)
                    #expect(window.projection?.documents.map(\.id) == documents[range].map(\.id))
                    print("ChapterWindowObservation chapter=\(document.id) width=\(width) font=\(size) visibleY=\(try window.visibleY(of: visible.anchor))")
                }
            }
        }
        let before = try window.capture()
        let text = window.textView.text
        #expect(throws: ProbeChapterProjection.Failure.chapterNotResident) {
            try window.render(Array(documents[2...4]), fontSize: 20, maintaining: before)
        }
        #expect(window.textView.text == text)
        #expect(try window.capture().anchor == before.anchor)
    }

    @Test func visibleTextPositionSurvivesReflowIndependentlyOfTheSelection() throws {
        let document = try fixture(repetitions: 300)
        let viewport = ProbeViewport(document: document)
        viewport.loadViewIfNeeded()
        viewport.view.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        try viewport.render(fontSize: 20, attachmentHeight: 40)
        viewport.textView.selectedRange = NSRange(location: 0, length: 0)
        let middle = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                     paragraphID: "long", utf16Offset: String(repeating: "中文 👩🏽‍💻 e\u{301} long text。", count: 150).utf16.count)
        try viewport.restoreVisible(.init(anchor: middle, verticalOffset: 80))
        let visible = try viewport.captureVisiblePosition()
        #expect(visible.anchor.paragraphID == "long")
        #expect(visible.anchor != (try viewport.selectedAnchor()))
        #expect(viewport.textView.selectedRange.location == 0)
        let changes: [(CGFloat, CGFloat, CGFloat?)] = [(820, 32, 200), (600, 18, nil), (390, 24, 80), (390, 20, 40)]
        for (width, size, imageHeight) in changes {
            viewport.view.frame.size.width = width
            try viewport.render(fontSize: size, attachmentHeight: imageHeight, maintaining: visible)
            let measured = try viewport.visibleOffset(of: visible.anchor)
            #expect(abs(measured - visible.verticalOffset) <= 1)
            #expect(viewport.textView.selectedRange.location == 0)
            let rectangle = try viewport.caretInViewport(at: visible.anchor)
            #expect(rectangle.intersects(viewport.view.bounds))
            print("VisibleAnchorObservation width=\(width) font=\(size) expectedY=\(visible.verticalOffset) observedY=\(measured)")
        }
        let beginning = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                        paragraphID: "first", utf16Offset: 0)
        try viewport.restoreVisible(.init(anchor: beginning, verticalOffset: 400))
        #expect(abs(viewport.textView.contentOffset.y + viewport.textView.adjustedContentInset.top) <= 1)
        let end = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                  paragraphID: "long", utf16Offset: document.paragraphs[2].text.utf16.count)
        try viewport.restoreVisible(.init(anchor: end, verticalOffset: -400))
        let lastRectangle = try viewport.caretInViewport(at: end)
        #expect(lastRectangle.intersects(viewport.view.bounds))
        #expect(lastRectangle.maxY <= viewport.textView.frame.maxY + 1)
        // Real drag gestures, cross-chapter windows and device frame timing remain separate probes.
    }

    @Test func selectedTextKeepsSemanticEndpointsWhenEarlierAttachmentsChange() throws {
        let document = try fixture(repetitions: 300)
        let viewport = ProbeViewport(document: document)
        viewport.loadViewIfNeeded()
        viewport.view.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        try viewport.render(fontSize: 20)
        let start = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                    paragraphID: "second", utf16Offset: 0)
        let end = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                  paragraphID: "long", utf16Offset: "中文 👩🏽‍💻 e\u{301}".utf16.count)
        let initialStart = try viewport.layoutOffset(of: start)
        let initialEnd = try viewport.layoutOffset(of: end)
        viewport.textView.selectedRange = NSRange(location: initialStart, length: initialEnd - initialStart)
        let selectedText = (viewport.textView.text as NSString).substring(with: viewport.textView.selectedRange)
        let middle = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                     paragraphID: "long", utf16Offset: String(repeating: "中文 👩🏽‍💻 e\u{301} long text。", count: 150).utf16.count)
        try viewport.restoreVisible(.init(anchor: middle, verticalOffset: 80))
        let visible = try viewport.captureVisiblePosition()
        let heights: [CGFloat?] = [40, 200, nil, 80, nil]
        for height in heights {
            try viewport.render(fontSize: 28, attachmentHeight: height, maintaining: visible)
            let selected = viewport.textView.selectedRange
            #expect(selected.location == initialStart + (height == nil ? 0 : 1))
            #expect(selected.location == (try viewport.layoutOffset(of: start)))
            #expect(NSMaxRange(selected) == (try viewport.layoutOffset(of: end)))
            #expect((viewport.textView.text as NSString).substring(with: selected) == selectedText)
            let measured = try viewport.visibleOffset(of: visible.anchor)
            #expect(abs(measured - visible.verticalOffset) <= 1)
        }
    }

    @Test func textKit2AndCoreTextLocateTheSameTextAtMultipleWidths() throws {
        let document = try fixture()
        let viewport = ProbeViewport(document: document)
        viewport.loadViewIfNeeded()
        for width in [CGFloat(390), 600, 820] {
            for size in [CGFloat(18), 32] {
                viewport.view.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                try viewport.render(fontSize: size)
                let text = try #require(viewport.textView.attributedText)
                let lineWidth = viewport.textView.bounds.width
                    - viewport.textView.textContainerInset.left - viewport.textView.textContainerInset.right
                    - 2 * viewport.textView.textContainer.lineFragmentPadding
                try #require(lineWidth > 0)
                let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
                var fitted = CFRange()
                let extent = CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter, CFRange(location: 0, length: 0), nil,
                    CGSize(width: lineWidth, height: .greatestFiniteMagnitude), &fitted)
                try #require(extent.height.isFinite && extent.height > 0)
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: lineWidth, height: ceil(extent.height) + 1), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                #expect(fitted.location == 0 && fitted.length == text.length)
                #expect(visible.location == 0 && visible.length == text.length)
                let lines = try #require(CTFrameGetLines(frame) as? [CTLine])
                try #require(!lines.isEmpty)
                for paragraph in document.paragraphs {
                    for logical in [0, paragraph.text.utf16.count] {
                        let anchor = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                                     paragraphID: paragraph.id, utf16Offset: logical)
                        let offset = try viewport.layoutOffset(of: anchor)
                        try viewport.restore(anchor)
                        #expect(try viewport.selectedAnchor() == anchor)
                        #expect(try viewport.caret(at: anchor).height > 0)
                        let line = try #require(lines.first { candidate in
                            let range = CTLineGetStringRange(candidate)
                            return offset >= range.location && offset <= range.location + range.length
                        })
                        #expect(CTLineGetOffsetForStringIndex(line, offset, nil).isFinite)
                    }
                }
                let layout = try #require(viewport.textView.textLayoutManager)
                let content = try #require(layout.textContentManager)
                var textKitLines = 0
                _ = layout.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
                    textKitLines += fragment.textLineFragments.filter { $0.characterRange.length > 0 }.count
                    return true
                }
                #expect(textKitLines > 0)
                print("LayoutComparison width=\(lineWidth) font=\(size) utf16=\(text.length) textKitLines=\(textKitLines) coreTextLines=\(lines.count) textKitHeight=\(viewport.textView.contentSize.height) coreTextHeight=\(extent.height)")
                // These are coverage/geometry observations, not a rendering-quality or speed verdict.
            }
        }
    }

    @Test func textKit2KeepsTheSameAnchorAcrossWidthsAndFontChanges() throws {
        let document = try fixture()
        let viewport = ProbeViewport(document: document)
        viewport.loadViewIfNeeded()
        let anchor = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                     paragraphID: "second", utf16Offset: 4)
        for width in [CGFloat(390), 820, 600] {
            for size in [CGFloat(18), 24, 32] {
                viewport.view.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                try viewport.render(fontSize: size, preserving: anchor)
                #expect(viewport.textView.textLayoutManager != nil)
                #expect(try viewport.selectedAnchor() == anchor)
                let rectangle = try viewport.caret(at: anchor)
                #expect(rectangle.height > 0 && rectangle.minX.isFinite && rectangle.minY.isFinite)
            }
        }
    }

    @Test func attachmentReflowPreservesTextAnchorAndNativeCommentTarget() throws {
        let document = try fixture()
        let viewport = ProbeViewport(document: document)
        viewport.loadViewIfNeeded()
        viewport.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let anchor = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                     paragraphID: "second", utf16Offset: 0)
        try viewport.render(fontSize: 20, preserving: anchor)
        let textOnlyOffset = try viewport.layoutOffset(of: anchor)
        try viewport.render(fontSize: 20, attachmentHeight: 40, preserving: anchor)
        let shortImageRect = try viewport.caret(at: anchor)
        #expect(try viewport.layoutOffset(of: anchor) == textOnlyOffset + 1)
        try viewport.render(fontSize: 20, attachmentHeight: 200, preserving: anchor)
        #expect(try viewport.caret(at: anchor).minY > shortImageRect.minY)
        #expect(try viewport.selectedAnchor() == anchor)
        let button = try #require(viewport.commentButtons["second"])
        #expect(button.bounds.width >= 44 && button.bounds.height >= 44)
        button.sendActions(for: .touchUpInside)
        #expect(viewport.lastCommentTarget == "second")
        #expect(viewport.projection.document == document)
        // sendActions validates native target routing; real finger hit testing is separate evidence.
    }

    @Test func longTextProducesValidGeometryWithoutFallingBackToTextKit1() throws {
        let document = try fixture(repetitions: 2_000)
        let viewport = ProbeViewport(document: document)
        viewport.loadViewIfNeeded()
        viewport.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        try viewport.render(fontSize: 20)
        let anchor = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                     paragraphID: "long", utf16Offset: document.paragraphs[2].text.utf16.count)
        try viewport.restore(anchor)
        #expect(try viewport.selectedAnchor() == anchor)
        #expect(try viewport.caret(at: anchor).height > 0)
        #expect(viewport.textView.textLayoutManager != nil)
    }

    @Test func preparedTextKitPagesCanBeHostedBySystemPageCurl() async throws {
        let first = ProbeViewport(document: try fixture())
        let second = ProbeViewport(document: try fixture())
        let curl = ProbePageCurl(first: first, second: second)
        curl.controller.loadViewIfNeeded()
        curl.controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        first.view.frame = curl.controller.view.bounds
        second.view.frame = curl.controller.view.bounds
        try first.render(fontSize: 20)
        try second.render(fontSize: 24, attachmentHeight: 80)
        #expect(curl.controller.transitionStyle == .pageCurl)
        for _ in 0..<3 {
            #expect(await curl.show(1, animated: false))
            #expect(curl.committedPage == 1)
            #expect(curl.controller.viewControllers?.first === second)
            #expect(await curl.show(0, animated: false))
            #expect(curl.committedPage == 0)
        }
        // Not an interactive gesture/animation test. Cancellation and visible curl need UI/device evidence.
    }

    private func fixture(repetitions: Int = 20) throws -> ProbeDocument {
        try ProbeDocument(id: "layout", paragraphs: [
            ProbeParagraph(id: "first", runs: [.text("重复段落"),
                .image(ProbeImage(id: "picture", resourceReference: "synthetic.png"))]),
            ProbeParagraph(id: "second", runs: [.text("重复段落"),
                .image(ProbeImage(id: "comment", resourceReference: "synthetic.svg",
                                 role: .comment(paragraphID: "second", externalReference: "p2")))]),
            ProbeParagraph(id: "long", runs: [.text(String(repeating: "中文 👩🏽‍💻 e\u{301} long text。", count: repetitions))]),
        ])
    }
}
#endif
