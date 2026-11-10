import Foundation

/// The M1 projection skips visual attachments without changing the semantic document.
public struct ChapterTextProjection: Sendable {
    public struct ParagraphRange: Equatable, Sendable {
        public let id: String
        public let range: NSRange
        fileprivate let boundaries: Set<Int>
    }
    public struct NonTextPosition: Equatable, Sendable {
        public let elementID: String
        public let utf16Offset: Int
    }
    public let document: ChapterDocument
    public let text: String
    public let paragraphs: [ParagraphRange]
    public let nonTextPositions: [NonTextPosition]

    public init(document: ChapterDocument) {
        self.document = document
        var text = ""
        var ranges: [ParagraphRange] = []
        var positions: [NonTextPosition] = []
        var offset = 0
        for block in document.content.blocks {
            if let paragraph = block.paragraph {
                if !ranges.isEmpty { text += "\n"; offset += 1 }
                var localOffset = offset
                for run in paragraph.runs {
                    switch run {
                    case .text(let value, _): localOffset += value.utf16.count
                    case .image(let value): positions.append(.init(elementID: value.id, utf16Offset: localOffset))
                    case .comment(let value): positions.append(.init(elementID: value.id, utf16Offset: localOffset))
                    }
                }
                let value = paragraph.text
                var end = 0
                var boundaries: Set<Int> = [0]
                // Concatenate runs before finding graphemes: marks may split an emoji or accent.
                for character in value { end += character.utf16.count; boundaries.insert(end) }
                ranges.append(.init(id: paragraph.id, range: NSRange(location: offset, length: end), boundaries: boundaries))
                text += value; offset += end
            } else {
                switch block {
                case .image(let value): positions.append(.init(elementID: value.id, utf16Offset: offset))
                case .comment(let value): positions.append(.init(elementID: value.id, utf16Offset: offset))
                case .paragraph, .heading: break
                }
            }
        }
        self.text = text; self.paragraphs = ranges; self.nonTextPositions = positions
    }

    public func position(atUTF16Offset offset: Int) throws -> ReadingPosition {
        guard let range = paragraphs.first(where: { offset >= $0.range.location && offset <= NSMaxRange($0.range) }),
              range.boundaries.contains(offset - range.range.location) else {
            throw ChapterContentError.invalidTextBoundary
        }
        return try ReadingPosition(chapter: document.content.chapter, documentRevision: document.revision,
            normalizationVersion: document.content.normalizationVersion,
            elementID: range.id, utf16Offset: offset - range.range.location)
    }

    public func utf16Offset(of position: ReadingPosition) throws -> Int {
        guard position.chapter == document.content.chapter, position.documentRevision == document.revision,
              position.normalizationVersion == document.content.normalizationVersion else {
            throw ChapterContentError.differentDocument
        }
        guard let range = paragraphs.first(where: { $0.id.utf8.elementsEqual(position.elementID.utf8) }) else {
            throw ChapterContentError.unknownParagraph
        }
        guard range.boundaries.contains(position.utf16Offset) else { throw ChapterContentError.invalidTextBoundary }
        return range.range.location + position.utf16Offset
    }
}
