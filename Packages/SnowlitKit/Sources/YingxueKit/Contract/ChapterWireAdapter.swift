import Foundation
import SnowlitCore

/// The host supplies installation identity, expected reference, and normalization service.
/// A response cannot choose a different local namespace or silently substitute a chapter.
public enum ChapterWireAdapter {
    public enum Failure: Error, Equatable, Sendable { case differentReference, invalidURL }

    public static func normalize(_ bytes: Data, expected: SnowlitCore.ChapterReference,
                                 using normalizer: ChapterNormalizer) async throws -> NormalizedChapter {
        let result = try YingxueWireCodec.decode(YingxueWire.ChapterResult.self, from: bytes)
        guard result.reference.book.key.utf8.elementsEqual(expected.book.key.utf8),
              result.reference.key.utf8.elementsEqual(expected.key.utf8) else { throw Failure.differentReference }
        let input: ChapterInput
        switch result.body {
        case .text(let body): input = .text(body.text)
        case .html(let body):
            let semantics = HTMLSemantics(
                paragraphs: body.paragraphs.map { .init(htmlID: $0.htmlID, paragraphID: $0.paragraphID) },
                images: body.images.map { binding in
                    switch binding {
                    case .illustration(let value):
                        return .init(htmlID: value.htmlID, elementID: value.elementID, resourceID: value.resourceID, reference: value.reference)
                    case .comment(let value):
                        return .init(htmlID: value.htmlID, elementID: value.elementID, resourceID: value.resourceID, reference: value.reference,
                                     role: .comment(paragraphID: value.paragraphID, externalReference: value.externalReference))
                    }
                })
            input = try .html(body.html, baseURL: url(body.baseURL), semantics: semantics)
        case .structured(let body):
            input = .structured(try body.blocks.map { block in
                switch block {
                case .paragraph(let value): return .paragraph(.init(id: value.id, runs: try value.runs.map(inline)))
                case .heading(let value): return .heading(.init(id: value.id, runs: try value.runs.map(inline)), level: value.level)
                case .image(let value): return .image(try image(value))
                case .comment(let value): return .comment(try comment(value))
                }
            })
        }
        return try await normalizer.normalize(input, chapter: expected, sourceRevision: result.revision)
    }

    private static func inline(_ value: YingxueWire.Inline) throws -> ChapterInline {
        switch value {
        case .text(let value): return .text(value.text, .init(strong: value.strong, emphasis: value.emphasis))
        case .image(let value): return .image(try image(value))
        case .comment(let value): return .comment(try comment(value))
        }
    }
    private static func image(_ value: YingxueWire.Image) throws -> ChapterImage {
        try .init(id: value.id, resource: resource(value.resource))
    }
    private static func comment(_ value: YingxueWire.Comment) throws -> ParagraphComment {
        try .init(id: value.id, paragraphID: value.paragraphID, externalReference: value.externalReference,
                  appearance: value.appearance.map(resource))
    }
    private static func resource(_ value: YingxueWire.Resource) throws -> ChapterResource {
        try .init(id: value.id, reference: value.reference, baseURL: value.baseURL.map(url),
                  alternateText: value.alternateText, mimeType: value.mimeType, width: value.width, height: value.height)
    }
    private static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { throw Failure.invalidURL }
        return url
    }
}
