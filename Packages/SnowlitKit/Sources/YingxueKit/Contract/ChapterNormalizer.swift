import Foundation
import SnowlitCore
import SwiftSoup

public struct HTMLParagraphBinding: Sendable {
    public let htmlID: String
    public let paragraphID: String
    public init(htmlID: String, paragraphID: String) { self.htmlID = htmlID; self.paragraphID = paragraphID }
}

public struct HTMLImageBinding: Sendable {
    public enum Role: Sendable {
        case illustration
        case comment(paragraphID: String, externalReference: String)
    }
    public let htmlID: String
    public let elementID: String
    public let resourceID: String
    public let reference: String?
    public let role: Role
    public init(htmlID: String, elementID: String, resourceID: String,
                reference: String? = nil, role: Role = .illustration) {
        self.htmlID = htmlID; self.elementID = elementID; self.resourceID = resourceID
        self.reference = reference; self.role = role
    }
}

public struct HTMLSemantics: Sendable {
    public let paragraphs: [HTMLParagraphBinding]
    public let images: [HTMLImageBinding]
    public init(paragraphs: [HTMLParagraphBinding] = [], images: [HTMLImageBinding] = []) {
        self.paragraphs = paragraphs; self.images = images
    }
}

public enum ChapterInput: Sendable {
    case text(String)
    case html(String, baseURL: URL, semantics: HTMLSemantics)
    case structured([ChapterBlock])
}

public struct NormalizedChapter: Sendable {
    public let content: ChapterContent
    /// Category/tag names only; never source scripts, attributes, credentials or body text.
    public let diagnostics: [String]
}

/// HTML is parsed as data, without a browser, resource loading, or script execution.
/// Parser nodes stay in this actor; only immutable Core values leave it.
public actor ChapterNormalizer {
    public enum Failure: Error, Equatable, Sendable {
        case invalidBaseURL
        case invalidMapping
        case duplicateMapping
        case missingMappedElement
        case ambiguousMappedElement
        case nestedMappedParagraph
    }

    public init() {}

    public func normalize(_ input: ChapterInput, chapter: ChapterReference, sourceRevision: String) throws -> NormalizedChapter {
        try Task.checkCancellation()
        let blocks: [ChapterBlock]
        let diagnostics: [String]
        switch input {
        case .structured(let values):
            blocks = values; diagnostics = []
        case .text(let text):
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            blocks = normalized.components(separatedBy: "\n").enumerated().map { index, value in
                .paragraph(.init(id: "generated:paragraph:\(index + 1)", runs: [.text(value, TextStyle())]))
            }
            diagnostics = []
        case .html(let html, let baseURL, let semantics):
            guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
                  baseURL.host != nil, baseURL.user == nil, baseURL.password == nil else {
                throw Failure.invalidBaseURL
            }
            let parsed = try SwiftSoup.parseBodyFragment(html, baseURL.absoluteString)
            guard let body = parsed.body() else { throw ChapterContentError.emptyContent }
            let builder = try HTMLChapterBuilder(baseURL: baseURL, semantics: semantics)
            try builder.walk(body)
            blocks = builder.blocks; diagnostics = builder.diagnostics
        }
        return try NormalizedChapter(content: ChapterContent(chapter: chapter, sourceRevision: sourceRevision, blocks: blocks),
                                     diagnostics: diagnostics)
    }
}

private final class HTMLChapterBuilder {
    private struct ParagraphDraft {
        let id: String
        let heading: Int?
        let explicitlyMapped: Bool
        let preserveEmpty: Bool
        var runs: [ChapterInline] = []
    }
    private enum Visit {
        case node(Node, TextStyle, preformatted: Bool)
        case endBlock
    }
    private let baseURL: URL
    private var paragraphBindings: [Data: HTMLParagraphBinding] = [:]
    private var imageBindings: [Data: HTMLImageBinding] = [:]
    private var usedParagraphs = Set<Data>()
    private var usedImages = Set<Data>()
    private var seenDiagnostics = Set<String>()
    private var paragraphNumber = 0
    private var imageNumber = 0
    private var current: ParagraphDraft?
    private var pendingSpace = false
    private var atLineStart = true
    private(set) var blocks: [ChapterBlock] = []
    private(set) var diagnostics: [String] = []

    private static let discarded: Set<String> = ["script", "style", "iframe", "object", "embed", "template", "noscript", "svg", "math", "head", "meta", "link", "base"]
    private static let blockTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "div", "section", "article", "blockquote", "li", "ul", "ol", "pre", "table", "tr", "td", "th", "hr"]
    private static let inlineTags: Set<String> = ["span", "strong", "b", "em", "i", "a", "u", "s", "small", "sup", "sub", "code"]

    init(baseURL: URL, semantics: HTMLSemantics) throws {
        self.baseURL = baseURL
        for binding in semantics.paragraphs {
            guard valid(binding.htmlID), valid(binding.paragraphID) else { throw ChapterNormalizer.Failure.invalidMapping }
            guard paragraphBindings.updateValue(binding, forKey: Data(binding.htmlID.utf8)) == nil else {
                throw ChapterNormalizer.Failure.duplicateMapping
            }
        }
        for binding in semantics.images {
            guard valid(binding.htmlID), valid(binding.elementID), valid(binding.resourceID),
                  paragraphBindings[Data(binding.htmlID.utf8)] == nil else { throw ChapterNormalizer.Failure.invalidMapping }
            guard imageBindings.updateValue(binding, forKey: Data(binding.htmlID.utf8)) == nil else {
                throw ChapterNormalizer.Failure.duplicateMapping
            }
        }
    }

    func walk(_ root: Element) throws {
        var stack: [Visit] = root.getChildNodes().reversed().map { .node($0, TextStyle(), preformatted: false) }
        while let visit = stack.popLast() {
            try Task.checkCancellation()
            switch visit {
            case .endBlock: flush()
            case .node(let node, let inherited, let preformatted):
                if let text = node as? TextNode {
                    append(text.getWholeText(), style: inherited, preformatted: preformatted)
                    continue
                }
                guard let element = node as? Element else { continue }
                let tag = element.tagNameNormal()
                let htmlID = Data(try element.attr("id").utf8)
                if Self.discarded.contains(tag) {
                    diagnose("discarded:\(tag)"); continue
                }
                if element.hasAttr("style") { diagnose("ignored:inline-css") }
                if imageBindings[htmlID] != nil && tag != "img" { throw ChapterNormalizer.Failure.invalidMapping }
                if paragraphBindings[htmlID] != nil && !Self.blockTags.contains(tag) { throw ChapterNormalizer.Failure.invalidMapping }
                let style = TextStyle(strong: inherited.strong || tag == "strong" || tag == "b",
                                      emphasis: inherited.emphasis || tag == "em" || tag == "i")
                if tag == "img" { try appendImage(element, htmlID: htmlID, style: style); continue }
                if tag == "br" { appendBreak(style); continue }
                if Self.blockTags.contains(tag) {
                    if current?.explicitlyMapped == true { throw ChapterNormalizer.Failure.nestedMappedParagraph }
                    flush()
                    let binding = paragraphBindings[htmlID]
                    if binding != nil && !usedParagraphs.insert(htmlID).inserted {
                        throw ChapterNormalizer.Failure.ambiguousMappedElement
                    }
                    paragraphNumber += 1
                    let heading = tag.count == 2 && tag.first == "h" ? Int(tag.suffix(1)) : nil
                    current = ParagraphDraft(id: binding.map { "source:\($0.paragraphID)" } ?? "generated:paragraph:\(paragraphNumber)",
                        heading: heading, explicitlyMapped: binding != nil, preserveEmpty: binding != nil || tag == "p" || heading != nil)
                    stack.append(.endBlock)
                } else if !Self.inlineTags.contains(tag) {
                    diagnose("flattened:\(tag)")
                } else if !["span", "strong", "b", "em", "i"].contains(tag) {
                    diagnose("flattened:\(tag)")
                }
                for child in element.getChildNodes().reversed() {
                    stack.append(.node(child, style, preformatted: preformatted || tag == "pre"))
                }
            }
        }
        flush()
        guard usedParagraphs.count == paragraphBindings.count, usedImages.count == imageBindings.count else {
            throw ChapterNormalizer.Failure.missingMappedElement
        }
    }

    private func append(_ raw: String, style: TextStyle, preformatted: Bool) {
        let raw = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if preformatted {
            pendingSpace = false
            if !raw.isEmpty { appendRun(.text(raw, style)); atLineStart = raw.last == "\n" }
            return
        }
        var normalized = ""
        normalized.reserveCapacity(raw.utf8.count)
        for scalar in raw.unicodeScalars {
            if [9, 10, 12, 13, 32].contains(scalar.value) {
                if !atLineStart { pendingSpace = true }
            } else {
                if pendingSpace { normalized += " "; pendingSpace = false }
                normalized.unicodeScalars.append(scalar)
                atLineStart = false
            }
        }
        if !normalized.isEmpty { appendRun(.text(normalized, style)) }
    }

    private func appendBreak(_ style: TextStyle) {
        pendingSpace = false
        appendRun(.text("\n", style))
        atLineStart = true
    }

    private func appendRun(_ run: ChapterInline) {
        if current == nil {
            paragraphNumber += 1
            current = ParagraphDraft(id: "generated:paragraph:\(paragraphNumber)", heading: nil,
                                     explicitlyMapped: false, preserveEmpty: false)
        }
        current?.runs.append(run)
    }

    private func appendImage(_ element: Element, htmlID: Data, style: TextStyle) throws {
        if pendingSpace { appendRun(.text(" ", style)); pendingSpace = false }
        imageNumber += 1
        let binding = imageBindings[htmlID]
        if binding != nil && !usedImages.insert(htmlID).inserted {
            throw ChapterNormalizer.Failure.ambiguousMappedElement
        }
        let id = binding.map { "source:\($0.elementID)" } ?? "generated:image:\(imageNumber)"
        let reference = try binding?.reference ?? element.attr("src")
        let resource = try ChapterResource(id: binding.map { "source:\($0.resourceID)" } ?? "generated:resource:\(imageNumber)",
            reference: reference, baseURL: baseURL,
            alternateText: element.hasAttr("alt") ? element.attr("alt") : nil,
            mimeType: element.hasAttr("type") ? element.attr("type") : nil,
            width: dimension(element, "width"), height: dimension(element, "height"))
        if case .comment(let target, let external)? = binding?.role {
            let comment = ParagraphComment(id: id, paragraphID: "source:\(target)", externalReference: external, appearance: resource)
            if current == nil { blocks.append(.comment(comment)) } else { appendRun(.comment(comment)) }
        } else {
            let image = ChapterImage(id: id, resource: resource)
            if current == nil { blocks.append(.image(image)) } else { appendRun(.image(image)) }
        }
    }

    private func dimension(_ element: Element, _ name: String) throws -> Int? {
        guard element.hasAttr(name) else { return nil }
        guard let result = Int(try element.attr(name)), result > 0 else {
            diagnose("ignored:image-\(name)"); return nil
        }
        return result
    }

    private func flush() {
        if let current, !current.runs.isEmpty || current.preserveEmpty {
            let paragraph = ChapterParagraph(id: current.id, runs: current.runs)
            if let level = current.heading { blocks.append(.heading(paragraph, level: level)) }
            else { blocks.append(.paragraph(paragraph)) }
        }
        current = nil; pendingSpace = false; atLineStart = true
    }

    private func valid(_ value: String) -> Bool { !value.isEmpty && !value.utf8.contains(0) }
    private func diagnose(_ value: String) {
        if seenDiagnostics.insert(value).inserted { diagnostics.append(value) }
    }
}
