#if os(iOS)
import CoreText
import SnowlitCore
import Testing
import UIKit
@testable import SnowlitReader

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ReaderProbeTests {
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

    @Test func textKit2KeepsTheSameAnchorAcrossPhoneTabletAndFontChanges() throws {
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
