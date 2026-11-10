import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct ChapterNormalizerTests {
    @Test func htmlRetainsHeadingEmphasisImagesAndExplicitCommentsWithoutExecutingContent() async throws {
        let html = """
        <h2>章节 &amp; 标题</h2><p id="one"> 重复 <strong>段落</strong> </p>
        <p id="two">重复 <em>段落</em><img id="comment" src="comments.svg" alt="段评" onclick="steal()"></p>
        <img src="picture.png" width="320" height="160"><p>e<strong>́</strong> 👩🏽‍💻<img src="ordinary.svg">尾</p>
        <script>document.body.textContent='hijacked';fetch('/should-not-run')</script>
        <iframe src="https://invalid.example/should-not-load"></iframe>
        """
        let result = try await normalize(html, semantics: HTMLSemantics(
            paragraphs: [.init(htmlID: "one", paragraphID: "p1"), .init(htmlID: "two", paragraphID: "p2")],
            images: [.init(htmlID: "comment", elementID: "comment", resourceID: "comment-icon", role: .comment(paragraphID: "p2", externalReference: "thread-2"))]))
        #expect(result.content.text == "章节 & 标题\n重复 段落\n重复 段落\né 👩🏽‍💻尾")
        #expect(result.content.blocks.count == 5)
        guard case .heading(_, level: 2) = result.content.blocks[0] else { Issue.record("Heading was flattened"); return }
        let second = try #require(result.content.blocks[2].paragraph)
        guard case .comment(let comment) = second.runs.last else { Issue.record("Explicit comment role was lost"); return }
        #expect(comment.paragraphID == "source:p2" && comment.externalReference == "thread-2")
        #expect(comment.appearance?.reference == "comments.svg" && comment.appearance?.alternateText == "段评")
        guard case .image(let image) = result.content.blocks[3] else { Issue.record("Block image was lost"); return }
        #expect(image.resource.width == 320 && image.resource.height == 160)
        #expect(image.resource.baseURL?.absoluteString == "https://fixture.invalid/books/one/")
        let last = try #require(result.content.blocks.last?.paragraph)
        #expect(last.runs.contains { if case .image = $0 { true } else { false } })
        #expect(result.diagnostics == ["discarded:script", "discarded:iframe"])
        let encoded = String(decoding: try result.content.canonicalBytes(), as: UTF8.self)
        #expect(!encoded.contains("steal") && !encoded.contains("hijacked") && !encoded.contains("should-not-load"))
    }

    @Test func whitespaceAndLineBreakRulesAreExplicitAcrossMarksAndParagraphs() async throws {
        let result = try await normalize("<p>  a <b> b </b> c &nbsp; d<br> e</p><p></p><pre> x\r\n y </pre><p>a <img src='x'> b</p>")
        #expect(result.content.text == "a b c \u{a0} d\ne\n\n x\n y \na  b")
        let first = try #require(result.content.blocks[0].paragraph)
        #expect(first.runs.contains { if case .text(let text, let style) = $0 { style.strong && text.contains("b") } else { false } })
        let plain = try await ChapterNormalizer().normalize(.text(" one\r\n\r\n two\rthree"), chapter: chapter(), sourceRevision: "r1")
        #expect(plain.content.text == " one\n\n two\nthree")
        #expect(plain.content.blocks.count == 4)
    }

    @Test func unmarkedTrailingImagesStayOrdinaryAndMissingOrAmbiguousMappingsFail() async throws {
        let ordinary = try await normalize("<p id='p'>text<img id='tail' src='comment-looking.svg' alt='99 comments'></p>")
        let paragraph = try #require(ordinary.content.blocks.first?.paragraph)
        guard case .image = paragraph.runs.last else { Issue.record("Unmarked image was guessed as a comment"); return }
        await #expect(throws: ChapterNormalizer.Failure.missingMappedElement) {
            try await normalize("<p>text</p>", semantics: .init(paragraphs: [.init(htmlID: "missing", paragraphID: "p")]))
        }
        await #expect(throws: ChapterNormalizer.Failure.ambiguousMappedElement) {
            try await normalize("<p id='same'>one</p><p id='same'>two</p>", semantics: .init(paragraphs: [.init(htmlID: "same", paragraphID: "p")]))
        }
        await #expect(throws: ChapterContentError.invalidCommentTarget) {
            try await normalize("<p>text<img id='icon' src='icon.svg'></p>", semantics: .init(images: [
                .init(htmlID: "icon", elementID: "c", resourceID: "r", role: .comment(paragraphID: "absent", externalReference: "thread"))]))
        }
    }

    @Test func malformedHTMLUsesOneParserAndUnknownStylingIsReported() async throws {
        let result = try await normalize("<p style='color:red'>one <strong>bold<p>two &amp; text<a href='javascript:bad()'> link</a>")
        #expect(result.content.blocks.compactMap(\.paragraph).count == 2)
        #expect(result.content.text == "one bold\ntwo & text link")
        #expect(result.diagnostics.contains("ignored:inline-css"))
        #expect(result.diagnostics.contains("flattened:a"))
        await #expect(throws: ChapterContentError.emptyContent) { try await normalize("<script>body</script><img src='only.png'>") }
        await #expect(throws: ChapterNormalizer.Failure.nestedMappedParagraph) {
            try await normalize("<div id='outer'><p>child</p></div>", semantics: .init(paragraphs: [.init(htmlID: "outer", paragraphID: "p")]))
        }
    }

    @Test func sourceBindingsOverrideLazyImageReferencesAndStructuredInputUsesSameValidation() async throws {
        let normalized = try await normalize("<p id='p'>text<img id='lazy' data-src='chosen.png'></p>", semantics: .init(
            paragraphs: [.init(htmlID: "p", paragraphID: "p")],
            images: [.init(htmlID: "lazy", elementID: "image", resourceID: "resource", reference: "chosen.png")]))
        let structured = try await ChapterNormalizer().normalize(.structured(normalized.content.blocks), chapter: normalized.content.chapter, sourceRevision: "r1")
        #expect(structured.content == normalized.content)
        #expect(try structured.content.canonicalBytes() == normalized.content.canonicalBytes())
    }

    private func normalize(_ html: String, semantics: HTMLSemantics = HTMLSemantics()) async throws -> NormalizedChapter {
        try await ChapterNormalizer().normalize(.html(html, baseURL: URL(string: "https://fixture.invalid/books/one/")!, semantics: semantics),
                                                chapter: chapter(), sourceRevision: "r1")
    }
    private func chapter() throws -> ChapterReference {
        try ChapterReference(book: SourceBookReference(installationID: SourceInstallationID(), referenceVersion: 1, key: "book"), key: "chapter")
    }
}
