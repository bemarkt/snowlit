import Foundation

/// Package-only feasibility model. Its encoding is not a published source/backup contract.
package struct ProbeDocument: Codable, Equatable, Sendable {
    package let id: String
    package let revision: UUID
    package let paragraphs: [ProbeParagraph]

    package init(id: String, paragraphs: [ProbeParagraph]) throws {
        try self.init(id: id, revision: UUID(), paragraphs: paragraphs)
    }

    private init(id: String, revision: UUID, paragraphs: [ProbeParagraph]) throws {
        guard !id.isEmpty, !paragraphs.isEmpty else { throw ProbeDocumentError.emptyDocument }
        var identifiers = Set<String>()
        for paragraph in paragraphs {
            guard !paragraph.id.isEmpty else { throw ProbeDocumentError.emptyIdentifier }
            guard identifiers.insert(paragraph.id).inserted else { throw ProbeDocumentError.duplicateIdentifier }
        }
        let paragraphIDs = identifiers
        for paragraph in paragraphs {
            for run in paragraph.runs {
                guard case .image(let image) = run else { continue }
                guard !image.id.isEmpty else { throw ProbeDocumentError.emptyIdentifier }
                guard identifiers.insert(image.id).inserted else { throw ProbeDocumentError.duplicateIdentifier }
                guard !image.resourceReference.isEmpty else { throw ProbeDocumentError.emptyResource }
                if case .comment(let target, let reference) = image.role {
                    guard paragraphIDs.contains(target), !reference.isEmpty else {
                        throw ProbeDocumentError.invalidCommentTarget
                    }
                }
            }
        }
        self.id = id
        self.revision = revision
        self.paragraphs = paragraphs
    }

    private enum CodingKeys: CodingKey { case id, revision, paragraphs }

    package init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id),
                      revision: values.decode(UUID.self, forKey: .revision),
                      paragraphs: values.decode([ProbeParagraph].self, forKey: .paragraphs))
    }
}

package struct ProbeParagraph: Codable, Equatable, Sendable {
    package let id: String
    package let runs: [ProbeInline]

    package init(id: String, runs: [ProbeInline]) {
        self.id = id
        self.runs = runs
    }

    package var text: String {
        runs.reduce(into: "") { text, run in
            if case .text(let value) = run { text += value }
        }
    }
}

package enum ProbeInline: Codable, Equatable, Sendable {
    case text(String)
    case image(ProbeImage)
}

package struct ProbeImage: Codable, Equatable, Sendable {
    package let id: String
    package let resourceReference: String
    package let alternateText: String?
    package let role: Role

    package enum Role: Codable, Equatable, Sendable {
        case illustration
        case comment(paragraphID: String, externalReference: String)
    }

    package init(id: String, resourceReference: String, alternateText: String? = nil,
                 role: Role = .illustration) {
        self.id = id
        self.resourceReference = resourceReference
        self.alternateText = alternateText
        self.role = role
    }
}

package enum ProbeDocumentError: Error, Equatable {
    case emptyDocument
    case emptyIdentifier
    case duplicateIdentifier
    case emptyResource
    case invalidCommentTarget
    case differentRevision
    case unknownParagraph
    case invalidTextBoundary
}

package struct ProbeTextAnchor: Codable, Equatable, Sendable {
    package let documentID: String
    package let revision: UUID
    package let paragraphID: String
    package let utf16Offset: Int

    package init(documentID: String, revision: UUID, paragraphID: String, utf16Offset: Int) {
        self.documentID = documentID
        self.revision = revision
        self.paragraphID = paragraphID
        self.utf16Offset = utf16Offset
    }
}

/// A reversible text view of an immutable semantic document. Image metadata stays in document.
package struct ProbeTextProjection: Sendable {
    package struct ParagraphRange: Equatable, Sendable {
        package let id: String
        package let range: NSRange
        fileprivate let boundaries: Set<Int>
    }

    package let document: ProbeDocument
    package let text: String
    package let paragraphs: [ParagraphRange]

    package init(document: ProbeDocument) {
        self.document = document
        var text = ""
        var ranges: [ParagraphRange] = []
        var offset = 0
        for (index, paragraph) in document.paragraphs.enumerated() {
            if index > 0 { text += "\n"; offset += 1 }
            let value = paragraph.text
            var boundary = 0
            var boundaries: Set<Int> = [0]
            // Extended grapheme boundaries forbid splitting emoji or combining sequences.
            // Runs may split a sequence; concatenate first, then compute boundaries.
            for character in value {
                boundary += character.utf16.count
                boundaries.insert(boundary)
            }
            ranges.append(ParagraphRange(id: paragraph.id,
                range: NSRange(location: offset, length: boundary), boundaries: boundaries))
            text += value
            offset += boundary
        }
        self.text = text
        self.paragraphs = ranges
    }

    package func anchor(atUTF16Offset offset: Int) throws -> ProbeTextAnchor {
        // The separator belongs to the preceding paragraph's end. The next start is
        // after the separator, so even adjacent empty paragraphs have distinct positions.
        guard let paragraph = paragraphs.first(where: {
            offset >= $0.range.location && offset <= NSMaxRange($0.range)
        }), paragraph.boundaries.contains(offset - paragraph.range.location) else {
            throw ProbeDocumentError.invalidTextBoundary
        }
        return ProbeTextAnchor(documentID: document.id, revision: document.revision,
                               paragraphID: paragraph.id, utf16Offset: offset - paragraph.range.location)
    }

    package func utf16Offset(of anchor: ProbeTextAnchor) throws -> Int {
        guard anchor.documentID == document.id, anchor.revision == document.revision else {
            throw ProbeDocumentError.differentRevision
        }
        guard let paragraph = paragraphs.first(where: { $0.id == anchor.paragraphID }) else {
            throw ProbeDocumentError.unknownParagraph
        }
        guard paragraph.boundaries.contains(anchor.utf16Offset) else {
            throw ProbeDocumentError.invalidTextBoundary
        }
        return paragraph.range.location + anchor.utf16Offset
    }
}
