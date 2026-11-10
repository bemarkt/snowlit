import Foundation

/// A bounded text projection. Headings and separators have no persistent
/// identity: a viewport hit there resolves to the adjacent document's text.
public struct ReadingWindow: Sendable {
    public struct Chapter: Equatable, Sendable {
        public let title: String
        public let document: ChapterDocument
        public init(title: String, document: ChapterDocument) { self.title = title; self.document = document }
    }
    public struct Segment: Sendable {
        public let chapter: Chapter
        public let projection: ChapterTextProjection
        public let titleRange: NSRange
        public let textRange: NSRange
    }
    public enum Failure: Error, Equatable { case invalidWindow, unavailablePosition }
    public let chapters: [Chapter]
    public let segments: [Segment]
    public let text: String

    public init(chapters: [Chapter]) throws {
        guard (1...3).contains(chapters.count),
              Set(chapters.map { $0.document.content.chapter }).count == chapters.count,
              Set(chapters.map { $0.document.content.chapter.book }).count == 1 else {
            throw Failure.invalidWindow
        }
        var text = "", segments: [Segment] = []
        for chapter in chapters {
            if !text.isEmpty { text += "\n\n" }
            let title = NSRange(location: text.utf16.count, length: chapter.title.utf16.count)
            text += chapter.title + "\n\n"
            let projection = ChapterTextProjection(document: chapter.document)
            let range = NSRange(location: text.utf16.count, length: projection.text.utf16.count)
            text += projection.text
            segments.append(.init(chapter: chapter, projection: projection, titleRange: title, textRange: range))
        }
        self.chapters = chapters; self.segments = segments; self.text = text
    }

    public func offset(of position: ReadingPosition) throws -> Int {
        guard let segment = segments.first(where: { $0.chapter.document.content.chapter == position.chapter }) else {
            throw Failure.unavailablePosition
        }
        return segment.textRange.location + (try segment.projection.utf16Offset(of: position))
    }

    /// Only hit-testing rounds toward a preceding grapheme boundary. Persisted
    /// anchors use offset(of:) and always require the exact document and element.
    public func position(near offset: Int) throws -> ReadingPosition {
        guard offset >= 0, offset <= text.utf16.count, let last = segments.last else { throw Failure.unavailablePosition }
        let segment = segments.first { offset <= NSMaxRange($0.textRange) } ?? last
        let local = min(segment.textRange.length, max(0, offset - segment.textRange.location))
        var boundary = 0
        for character in segment.projection.text {
            let next = boundary + character.utf16.count
            if next > local { break }
            boundary = next
        }
        return try segment.projection.position(atUTF16Offset: boundary)
    }
}
