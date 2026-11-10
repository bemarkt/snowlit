import Foundation
import Testing
@testable import SnowlitCore

struct ProbeDocumentTests {
    @Test func stylesRoundTripWithoutChangingTextOrSplittingGraphemes() throws {
        let image = ProbeImage(id: "image", resourceReference: "retained.png")
        let document = try ProbeDocument(id: "styled", paragraphs: [
            ProbeParagraph(id: "p", runs: [.text("e"), .styledText("\u{301}", style: .emphasis),
                .styledText("👩🏽‍💻", style: .strong), .image(image),
                .styledText("中文 Bold Italic", style: .strongEmphasis)]),
        ])
        let restored = try JSONDecoder().decode(ProbeDocument.self, from: JSONEncoder().encode(document))
        #expect(restored == document)
        let projection = ProbeTextProjection(document: restored)
        #expect(projection.text == "e\u{301}👩🏽‍💻中文 Bold Italic")
        #expect(throws: ProbeDocumentError.invalidTextBoundary) { try projection.anchor(atUTF16Offset: 1) }
        for offset in 3..<9 {
            #expect(throws: ProbeDocumentError.invalidTextBoundary) { try projection.anchor(atUTF16Offset: offset) }
        }
        var offset = 0
        for character in projection.text {
            let anchor = try projection.anchor(atUTF16Offset: offset)
            #expect(try projection.utf16Offset(of: anchor) == offset)
            offset += character.utf16.count
        }
        #expect(try projection.anchor(atUTF16Offset: offset).utf16Offset == offset)
        #expect(restored.paragraphs[0].runs[3] == .image(image))
    }

    @Test func styleOnlyRevisionRejectsAnchorsFromThePreviousDocument() throws {
        let original = try ProbeDocument(id: "chapter", paragraphs: [
            ProbeParagraph(id: "p", runs: [.styledText("same text", style: .strong)]),
        ])
        let changed = try ProbeDocument(id: "chapter", paragraphs: [
            ProbeParagraph(id: "p", runs: [.styledText("same text", style: .emphasis)]),
        ])
        let before = ProbeTextProjection(document: original)
        let after = ProbeTextProjection(document: changed)
        #expect(before.text == after.text)
        let anchor = try before.anchor(atUTF16Offset: 4)
        #expect(throws: ProbeDocumentError.differentRevision) { try after.utf16Offset(of: anchor) }
        #expect(try JSONEncoder().encode(original) != JSONEncoder().encode(changed))
    }

    @Test func repeatedParagraphsKeepDistinctTargetsAcrossEncodingAndTextProjection() throws {
        let image = ProbeImage(id: "illustration", resourceReference: "image.png", alternateText: "图")
        let comment = ProbeImage(id: "comment-entry", resourceReference: "comment.svg",
                                 role: .comment(paragraphID: "second", externalReference: "remote-p2"))
        let document = try ProbeDocument(id: "chapter", paragraphs: [
            ProbeParagraph(id: "first", runs: [.text("重复段落"), .image(image)]),
            ProbeParagraph(id: "second", runs: [.text("重复段落"), .image(comment)]),
        ])
        let data = try JSONEncoder().encode(document)
        let restored = try JSONDecoder().decode(ProbeDocument.self, from: data)
        #expect(restored == document)
        let projection = ProbeTextProjection(document: restored)
        #expect(projection.text == "重复段落\n重复段落")
        #expect(projection.document.paragraphs[1].runs[1] == .image(comment))
        let anchor = try projection.anchor(atUTF16Offset: 5)
        #expect(anchor.paragraphID == "second")
        #expect(try projection.utf16Offset(of: anchor) == 5)
        #expect(try projection.anchor(atUTF16Offset: 0).paragraphID == "first")
        #expect(image.role == .illustration) // An unmarked image is never guessed to be a comment.
    }

    @Test func anchorsRoundTripAtEveryCharacterBoundaryIncludingEmptyParagraphs() throws {
        let texts = ["", "重复", "重复", "中文 👩🏽‍💻 e\u{301}", "", "𝄞🇭🇰\r\n尾"]
        let document = try ProbeDocument(id: "unicode", paragraphs: texts.enumerated().map {
            ProbeParagraph(id: "p\($0.offset)", runs: [.text($0.element)])
        })
        let projection = ProbeTextProjection(document: document)
        for (index, paragraph) in projection.paragraphs.enumerated() {
            var localOffset = 0
            let boundaries = [0] + texts[index].map { character in
                localOffset += character.utf16.count
                return localOffset
            }
            for offset in boundaries {
                let anchor = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                             paragraphID: paragraph.id, utf16Offset: offset)
                let absolute = try projection.utf16Offset(of: anchor)
                #expect(absolute == paragraph.range.location + offset)
                #expect(try projection.anchor(atUTF16Offset: absolute) == anchor)
            }
        }
    }

    @Test func splitRunsDoNotPermitAnchorsInsideOneGrapheme() throws {
        let document = try ProbeDocument(id: "split", paragraphs: [
            ProbeParagraph(id: "p", runs: [.text("e"), .text("\u{301}"), .text("👩🏽‍💻")]),
        ])
        let projection = ProbeTextProjection(document: document)
        #expect(throws: ProbeDocumentError.invalidTextBoundary) { try projection.anchor(atUTF16Offset: 1) }
        for offset in 3..<9 {
            #expect(throws: ProbeDocumentError.invalidTextBoundary) { try projection.anchor(atUTF16Offset: offset) }
        }
        #expect(try projection.anchor(atUTF16Offset: 2).utf16Offset == 2)
        #expect(try projection.anchor(atUTF16Offset: 9).utf16Offset == 9)
    }

    @Test func oldRevisionCannotSilentlyResolveAgainstNewTextOrImageMetadata() throws {
        let original = try ProbeDocument(id: "chapter", paragraphs: [
            ProbeParagraph(id: "same", runs: [.text("text"), .image(ProbeImage(id: "img", resourceReference: "a.png"))]),
        ])
        let changed = try ProbeDocument(id: "chapter", paragraphs: [
            ProbeParagraph(id: "same", runs: [.text("text"), .image(ProbeImage(id: "img", resourceReference: "b.png"))]),
        ])
        let anchor = try ProbeTextProjection(document: original).anchor(atUTF16Offset: 2)
        let projection = ProbeTextProjection(document: changed)
        #expect(projection.text == "text")
        #expect(throws: ProbeDocumentError.differentRevision) { try projection.utf16Offset(of: anchor) }
    }

    @Test func malformedSemanticTargetsAreRejectedOnConstructionAndDecoding() throws {
        let repeated = ProbeParagraph(id: "p", runs: [.text("text")])
        #expect(throws: ProbeDocumentError.duplicateIdentifier) {
            try ProbeDocument(id: "c", paragraphs: [repeated, repeated])
        }
        let badComment = ProbeImage(id: "image", resourceReference: "comment.svg",
                                   role: .comment(paragraphID: "missing", externalReference: "remote"))
        #expect(throws: ProbeDocumentError.invalidCommentTarget) {
            try ProbeDocument(id: "c", paragraphs: [ProbeParagraph(id: "p", runs: [.image(badComment)])])
        }
        let document = try ProbeDocument(id: "c", paragraphs: [repeated])
        let encoded = try JSONEncoder().encode(document)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["paragraphs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([repeated, repeated]))
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: ProbeDocumentError.duplicateIdentifier) {
            try JSONDecoder().decode(ProbeDocument.self, from: corrupt)
        }
    }

    @Test func outOfBoundsAndUnknownParagraphsNeverFallBackToSimilarText() throws {
        let document = try ProbeDocument(id: "c", paragraphs: [ProbeParagraph(id: "p", runs: [.text("text")])])
        let projection = ProbeTextProjection(document: document)
        for offset in [-1, 5, Int.max] {
            #expect(throws: ProbeDocumentError.invalidTextBoundary) { try projection.anchor(atUTF16Offset: offset) }
        }
        let unknown = ProbeTextAnchor(documentID: document.id, revision: document.revision,
                                      paragraphID: "unknown", utf16Offset: 0)
        #expect(throws: ProbeDocumentError.unknownParagraph) { try projection.utf16Offset(of: unknown) }
    }

    @Test func longParagraphRoundTripRetainsCompleteText() throws {
        let text = String(repeating: "长段 👩🏽‍💻 e\u{301}。", count: 10_000)
        let document = try ProbeDocument(id: "long", paragraphs: [ProbeParagraph(id: "p", runs: [.text(text)])])
        let projection = ProbeTextProjection(document: document)
        #expect(projection.text == text)
        let end = try projection.anchor(atUTF16Offset: text.utf16.count)
        #expect(try projection.utf16Offset(of: end) == text.utf16.count)
        #expect(try JSONDecoder().decode(ProbeDocument.self, from: JSONEncoder().encode(document)) == document)
    }
}
