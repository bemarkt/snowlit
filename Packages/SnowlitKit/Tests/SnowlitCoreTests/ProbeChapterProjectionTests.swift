import Foundation
import Testing
@testable import SnowlitCore

struct ProbeChapterProjectionTests {
    @Test func repeatedParagraphsRemainChapterSpecificWhenWindowMovesBothWays() throws {
        let documents = try (0..<5).map { index in
            try ProbeDocument(id: "chapter-\(index)", paragraphs: [
                ProbeParagraph(id: "same", runs: [.text("重复 👩🏽‍💻 e\u{301}")]),
                ProbeParagraph(id: "empty", runs: []),
            ])
        }
        let windows = try [Array(documents[0...2]), Array(documents[1...3]), Array(documents[2...4]),
                           Array(documents[1...3]), Array(documents[0...2])].map {
            try ProbeChapterProjection(documents: $0)
        }
        for window in windows {
            for document in window.documents {
                let local = ProbeTextProjection(document: document)
                var offsets = [0]
                var position = 0
                for character in local.text {
                    position += character.utf16.count
                    offsets.append(position)
                }
                for offset in offsets {
                    let anchor = try local.anchor(atUTF16Offset: offset)
                    #expect(try window.anchor(at: window.offset(of: anchor)) == anchor)
                }
            }
            let center = documents[2]
            let anchor = ProbeTextAnchor(documentID: center.id, revision: center.revision,
                                         paragraphID: "same", utf16Offset: 3)
            #expect(try window.anchor(at: window.offset(of: anchor)) == anchor)
            #expect(window.documents.map(\.id).count == 3)
        }
    }

    @Test func evictionRevisionChangesAndInvalidGraphemeOffsetsFailExplicitly() throws {
        let first = try ProbeDocument(id: "first", paragraphs: [.init(id: "p", runs: [.text("👩🏽‍💻")])])
        let next = try ProbeDocument(id: "next", paragraphs: [.init(id: "p", runs: [.text("同文")])])
        let window = try ProbeChapterProjection(documents: [first, next])
        let valid = ProbeTextAnchor(documentID: first.id, revision: first.revision, paragraphID: "p", utf16Offset: 0)
        let evicted = try ProbeChapterProjection(documents: [next])
        #expect(throws: ProbeChapterProjection.Failure.chapterNotResident) { try evicted.offset(of: valid) }
        let stale = ProbeTextAnchor(documentID: first.id, revision: UUID(), paragraphID: "p", utf16Offset: 0)
        #expect(throws: ProbeDocumentError.differentRevision) { try window.offset(of: stale) }
        #expect(throws: ProbeDocumentError.invalidTextBoundary) { try window.anchor(at: 1) }
        #expect(throws: ProbeChapterProjection.Failure.duplicateChapter) {
            try ProbeChapterProjection(documents: [first, first])
        }
        #expect(throws: ProbeChapterProjection.Failure.invalidWindow) { try ProbeChapterProjection(documents: []) }
    }
}
