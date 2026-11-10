import Foundation

public enum ChapterContentError: Error, Equatable, Sendable {
    case unsupportedNormalization
    case emptyContent
    case invalidIdentifier
    case duplicateElement
    case conflictingResource
    case invalidResource
    case invalidCommentTarget
    case invalidHeading
    case invalidDigest
    case differentDocument
    case unknownParagraph
    case invalidTextBoundary
}

public struct TextStyle: Equatable, Codable, Sendable {
    public let strong: Bool
    public let emphasis: Bool
    public init(strong: Bool = false, emphasis: Bool = false) {
        self.strong = strong
        self.emphasis = emphasis
    }
}

/// An inert source-scoped description. It contains no cookies, headers, or action code.
/// The resource service resolves reference/baseURL when that capability is enabled.
public struct ChapterResource: Equatable, Codable, Sendable {
    public let id: String
    public let reference: String
    public let baseURL: URL?
    public let alternateText: String?
    public let mimeType: String?
    public let width: Int?
    public let height: Int?

    public init(id: String, reference: String, baseURL: URL? = nil, alternateText: String? = nil,
                mimeType: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.id = id; self.reference = reference; self.baseURL = baseURL
        self.alternateText = alternateText; self.mimeType = mimeType
        self.width = width; self.height = height
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        func bytes(_ value: String?) -> Data? { value.map { Data($0.utf8) } }
        return bytes(lhs.id) == bytes(rhs.id) && bytes(lhs.reference) == bytes(rhs.reference)
            && bytes(lhs.baseURL?.absoluteString) == bytes(rhs.baseURL?.absoluteString)
            && bytes(lhs.alternateText) == bytes(rhs.alternateText) && bytes(lhs.mimeType) == bytes(rhs.mimeType)
            && lhs.width == rhs.width && lhs.height == rhs.height
    }
}

public struct ChapterImage: Equatable, Codable, Sendable {
    public let id: String
    public let resource: ChapterResource
    public init(id: String, resource: ChapterResource) { self.id = id; self.resource = resource }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.resource == rhs.resource
    }
}

public struct ParagraphComment: Equatable, Codable, Sendable {
    public let id: String
    public let paragraphID: String
    public let externalReference: String
    public let appearance: ChapterResource?
    public init(id: String, paragraphID: String, externalReference: String, appearance: ChapterResource? = nil) {
        self.id = id; self.paragraphID = paragraphID
        self.externalReference = externalReference; self.appearance = appearance
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.paragraphID.utf8.elementsEqual(rhs.paragraphID.utf8)
            && lhs.externalReference.utf8.elementsEqual(rhs.externalReference.utf8) && lhs.appearance == rhs.appearance
    }
}

public enum ChapterInline: Equatable, Codable, Sendable {
    case text(String, TextStyle)
    case image(ChapterImage)
    case comment(ParagraphComment)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.text(let left, let leftStyle), .text(let right, let rightStyle)):
            left.utf8.elementsEqual(right.utf8) && leftStyle == rightStyle
        case (.image(let left), .image(let right)): left == right
        case (.comment(let left), .comment(let right)): left == right
        default: false
        }
    }
}

public struct ChapterParagraph: Equatable, Codable, Sendable {
    public let id: String
    public let runs: [ChapterInline]
    public init(id: String, runs: [ChapterInline]) { self.id = id; self.runs = runs }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.runs == rhs.runs
    }
    public var text: String {
        runs.reduce(into: "") { output, run in
            if case .text(let value, _) = run { output += value }
        }
    }
}

public enum ChapterBlock: Equatable, Codable, Sendable {
    case paragraph(ChapterParagraph)
    case heading(ChapterParagraph, level: Int)
    case image(ChapterImage)
    case comment(ParagraphComment)

    public var paragraph: ChapterParagraph? {
        switch self {
        case .paragraph(let value), .heading(let value, _): value
        case .image, .comment: nil
        }
    }
}

/// Versioned, validated semantic content, independent of display mode and source wire encoding.
public struct ChapterContent: Equatable, Codable, Sendable {
    public static let currentNormalizationVersion = 1
    public let chapter: ChapterReference
    public let sourceRevision: String
    public let normalizationVersion: Int
    public let blocks: [ChapterBlock]

    public init(chapter: ChapterReference, sourceRevision: String,
                normalizationVersion: Int = currentNormalizationVersion, blocks: [ChapterBlock]) throws {
        guard normalizationVersion == Self.currentNormalizationVersion else {
            throw ChapterContentError.unsupportedNormalization
        }
        try Self.validateIdentifier(sourceRevision)
        var identifiers = Set<Data>()
        var paragraphIDs = Set<Data>()
        var resources: [Data: ChapterResource] = [:]
        var comments: [ParagraphComment] = []
        var hasText = false

        func claim(_ id: String) throws {
            try Self.validateIdentifier(id)
            guard identifiers.insert(Data(id.utf8)).inserted else { throw ChapterContentError.duplicateElement }
        }
        func resource(_ value: ChapterResource) throws {
            try Self.validateIdentifier(value.id)
            guard !value.reference.isEmpty, !value.reference.utf8.contains(0),
                  value.width.map({ $0 > 0 }) ?? true,
                  value.height.map({ $0 > 0 }) ?? true else { throw ChapterContentError.invalidResource }
            if let baseURL = value.baseURL {
                guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
                      baseURL.host != nil, baseURL.user == nil, baseURL.password == nil else {
                    throw ChapterContentError.invalidResource
                }
            }
            let key = Data(value.id.utf8)
            if let existing = resources[key], existing != value { throw ChapterContentError.conflictingResource }
            resources[key] = value
        }
        func image(_ value: ChapterImage) throws { try claim(value.id); try resource(value.resource) }
        func comment(_ value: ParagraphComment) throws {
            try claim(value.id)
            try Self.validateIdentifier(value.externalReference)
            if let appearance = value.appearance { try resource(appearance) }
            comments.append(value)
        }
        for block in blocks {
            if let paragraph = block.paragraph {
                try claim(paragraph.id)
                paragraphIDs.insert(Data(paragraph.id.utf8))
                if !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true }
                if case .heading(_, let level) = block, !(1...6).contains(level) {
                    throw ChapterContentError.invalidHeading
                }
                for run in paragraph.runs {
                    switch run {
                    case .text: break
                    case .image(let value): try image(value)
                    case .comment(let value): try comment(value)
                    }
                }
            } else {
                switch block {
                case .image(let value): try image(value)
                case .comment(let value): try comment(value)
                case .paragraph, .heading: break
                }
            }
        }
        guard hasText else { throw ChapterContentError.emptyContent }
        for value in comments {
            guard paragraphIDs.contains(Data(value.paragraphID.utf8)) else {
                throw ChapterContentError.invalidCommentTarget
            }
        }
        self.chapter = chapter; self.sourceRevision = sourceRevision
        self.normalizationVersion = normalizationVersion; self.blocks = blocks
    }

    public var text: String { blocks.compactMap(\.paragraph).map(\.text).joined(separator: "\n") }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chapter == rhs.chapter && lhs.sourceRevision.utf8.elementsEqual(rhs.sourceRevision.utf8)
            && lhs.normalizationVersion == rhs.normalizationVersion && lhs.blocks == rhs.blocks
    }

    /// Fixed-key JSON, integral dimensions, and ordered arrays form normalization v1 bytes.
    /// Unicode is preserved, never normalized to merge opaque identifiers.
    public func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private enum CodingKeys: CodingKey { case chapter, sourceRevision, normalizationVersion, blocks }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(chapter: values.decode(ChapterReference.self, forKey: .chapter),
                      sourceRevision: values.decode(String.self, forKey: .sourceRevision),
                      normalizationVersion: values.decode(Int.self, forKey: .normalizationVersion),
                      blocks: values.decode([ChapterBlock].self, forKey: .blocks))
    }

    private static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty, !value.utf8.contains(0) else { throw ChapterContentError.invalidIdentifier }
    }
}

/// Fingerprints are derived from all semantic content, never supplied by a source as trusted identity.
/// Digest is injected at the system boundary; callers use SHA-256. Cached content is decoded
/// and reconstructed through this initializer before its recorded digest is compared.
public struct ChapterDocument: Equatable, Sendable {
    public let content: ChapterContent
    public let revision: String
    public let textDigest: String

    public init(content: ChapterContent, digest: (Data) throws -> String) throws {
        let revision = try digest(content.canonicalBytes())
        let textDigest = try digest(Data(content.text.utf8))
        for value in [revision, textDigest] {
            guard value.utf8.count == 64,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ChapterContentError.invalidDigest
            }
        }
        self.content = content; self.revision = revision; self.textDigest = textDigest
    }
}
