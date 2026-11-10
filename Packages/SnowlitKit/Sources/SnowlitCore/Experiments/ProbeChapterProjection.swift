import Foundation

/// Three resident chapters for feasibility measurements, not a limit on book length.
package struct ProbeChapterProjection: Sendable {
    package enum Failure: Error, Equatable { case invalidWindow, duplicateChapter, chapterNotResident }
    private struct Chapter: Sendable {
        let projection: ProbeTextProjection
        let start: Int
    }
    package let documents: [ProbeDocument]
    package let text: String
    private let chapters: [Chapter]

    package init(documents: [ProbeDocument]) throws {
        guard (1...3).contains(documents.count) else { throw Failure.invalidWindow }
        guard Set(documents.map(\.id)).count == documents.count else { throw Failure.duplicateChapter }
        var text = ""
        var chapters: [Chapter] = []
        for document in documents {
            if !chapters.isEmpty { text += "\n" }
            let projection = ProbeTextProjection(document: document)
            chapters.append(Chapter(projection: projection, start: text.utf16.count))
            text += projection.text
        }
        self.documents = documents
        self.text = text
        self.chapters = chapters
    }

    package func offset(of anchor: ProbeTextAnchor) throws -> Int {
        guard let chapter = chapters.first(where: { $0.projection.document.id == anchor.documentID }) else {
            throw Failure.chapterNotResident
        }
        return chapter.start + (try chapter.projection.utf16Offset(of: anchor))
    }

    package func anchor(at offset: Int) throws -> ProbeTextAnchor {
        // The single interchapter separator belongs to the previous chapter's end;
        // the following chapter begins at its own distinct offset, even if empty.
        guard let chapter = chapters.first(where: {
            offset >= $0.start && offset <= $0.start + $0.projection.text.utf16.count
        }) else { throw ProbeDocumentError.invalidTextBoundary }
        return try chapter.projection.anchor(atUTF16Offset: offset - chapter.start)
    }
}
