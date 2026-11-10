import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#elseif os(Windows)
import WinSDK
#endif
@testable import SnowlitCore

struct ChapterContentTests {
    @Test func semanticEqualityDoesNotSuppressByteDistinctContentOrRemoteIdentities() throws {
        let composed = "é", decomposed = "e\u{301}"
        #expect(composed == decomposed) // Swift display-text equivalence differs from opaque identity.
        let resource = ChapterResource(id: "resource", reference: "image.png")
        #expect(ChapterImage(id: composed, resource: resource) != ChapterImage(id: decomposed, resource: resource))
        #expect(ParagraphComment(id: "c", paragraphID: "p", externalReference: composed)
                != ParagraphComment(id: "c", paragraphID: "p", externalReference: decomposed))
        #expect(ChapterParagraph(id: composed, runs: []) != ChapterParagraph(id: decomposed, runs: []))
        #expect(ChapterInline.text(composed, TextStyle()) != ChapterInline.text(decomposed, TextStyle()))
        let original = try sample()
        let left = try ChapterContent(chapter: original.chapter, sourceRevision: composed, blocks: original.blocks)
        let right = try ChapterContent(chapter: original.chapter, sourceRevision: decomposed, blocks: original.blocks)
        #expect(left != right)
        #expect(try left.canonicalBytes() != right.canonicalBytes())
    }

    @Test func digestAdapterMatchesSHA256KnownAnswers() throws {
        #expect(try digest(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(try digest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    @Test func opaqueParagraphAndResourceIdentifiersDoNotMergeUnicodeSpellings() throws {
        let original = try sample()
        let content = try ChapterContent(chapter: original.chapter, sourceRevision: "r", blocks: [
            .paragraph(.init(id: "é", runs: [.text("same", TextStyle())])),
            .paragraph(.init(id: "e\u{301}", runs: [.text("same", TextStyle())]))
        ])
        let projection = try ChapterTextProjection(document: ChapterDocument(content: content, digest: digest))
        #expect(try projection.position(atUTF16Offset: 0) != projection.position(atUTF16Offset: 5))
        #expect(throws: ChapterContentError.conflictingResource) {
            try ChapterContent(chapter: original.chapter, sourceRevision: "r", blocks: [original.blocks[1],
                .image(.init(id: "a", resource: .init(id: "resource", reference: "é.png"))),
                .image(.init(id: "b", resource: .init(id: "resource", reference: "e\u{301}.png")))])
        }
    }
    @Test func semanticRoundTripKeepsDuplicateParagraphsImageOrderAndCommentTargets() throws {
        let content = try sample()
        let decoded = try JSONDecoder().decode(ChapterContent.self, from: content.canonicalBytes())
        #expect(decoded == content)
        #expect(try decoded.canonicalBytes() == content.canonicalBytes())
        let document = try ChapterDocument(content: decoded, digest: digest)
        let projection = ChapterTextProjection(document: document)
        #expect(projection.text == "重复\n重复\né 👩🏽‍💻")
        #expect(projection.paragraphs.map(\.id) == ["p1", "p2", "unicode"])
        #expect(projection.nonTextPositions.map(\.elementID) == ["cover", "inline", "comment", "unmarked"])
        #expect(projection.nonTextPositions.map(\.utf16Offset) == [0, 3, 5, 5])
        #expect(document.content.blocks.count == 5)
    }

    @Test func everyGraphemeBoundaryRoundTripsButSplitEmojiAndAccentsAreRejected() throws {
        let document = try ChapterDocument(content: sample(), digest: digest)
        let projection = ChapterTextProjection(document: document)
        var offset = 0
        for character in projection.text {
            let anchor = try projection.position(atUTF16Offset: offset)
            #expect(try projection.utf16Offset(of: anchor) == offset)
            offset += character.utf16.count
        }
        #expect(try projection.utf16Offset(of: projection.position(atUTF16Offset: offset)) == offset)
        let unicodeStart = try #require(projection.paragraphs.last).range.location
        #expect(throws: ChapterContentError.invalidTextBoundary) { try projection.position(atUTF16Offset: unicodeStart + 1) }
        #expect(throws: ChapterContentError.invalidTextBoundary) { try projection.position(atUTF16Offset: unicodeStart + 4) }
        let left = try projection.position(atUTF16Offset: 0)
        let right = try projection.position(atUTF16Offset: 3)
        #expect(left.elementID == "p1" && right.elementID == "p2")
    }

    @Test func styleResourceAndCommentOnlyChangesInvalidateExactAnchorsWithoutChangingTextDigest() throws {
        let original = try sample()
        let document = try ChapterDocument(content: original, digest: digest)
        let position = try ChapterTextProjection(document: document).position(atUTF16Offset: 3)
        let replacements: [ChapterBlock] = [
            .heading(.init(id: "p1", runs: [.text("重复", TextStyle())]), level: 2),
            .paragraph(.init(id: "p1", runs: [.text("重复", TextStyle(strong: true))])),
        ]
        for replacement in replacements {
            var blocks = original.blocks; blocks[1] = replacement
            let content = try ChapterContent(chapter: original.chapter, sourceRevision: original.sourceRevision, blocks: blocks)
            let changed = try ChapterDocument(content: content, digest: digest)
            #expect(changed.textDigest == document.textDigest)
            #expect(changed.revision != document.revision)
            #expect(throws: ChapterContentError.differentDocument) { try ChapterTextProjection(document: changed).utf16Offset(of: position) }
        }
        var blocks = original.blocks
        blocks[0] = .image(.init(id: "cover", resource: .init(id: "cover-resource", reference: "changed.png", alternateText: "changed")))
        let resourceChanged = try ChapterDocument(content: ChapterContent(chapter: original.chapter, sourceRevision: original.sourceRevision, blocks: blocks), digest: digest)
        #expect(resourceChanged.revision != document.revision && resourceChanged.textDigest == document.textDigest)
        blocks = original.blocks
        blocks[2] = .paragraph(.init(id: "p2", runs: [
            .image(.init(id: "inline", resource: .init(id: "inline-resource", reference: "inline.png"))),
            .text("重复", TextStyle()),
            .comment(.init(id: "comment", paragraphID: "p2", externalReference: "changed-thread"))
        ]))
        let commentChanged = try ChapterDocument(content: ChapterContent(chapter: original.chapter, sourceRevision: original.sourceRevision, blocks: blocks), digest: digest)
        #expect(commentChanged.revision != document.revision && commentChanged.textDigest == document.textDigest)
    }

    @Test func invalidGraphsAndUnknownNormalizationAreRejectedDuringDecoding() throws {
        let original = try sample()
        var json = try #require(JSONSerialization.jsonObject(with: original.canonicalBytes()) as? [String: Any])
        json["normalizationVersion"] = 999
        #expect(throws: ChapterContentError.unsupportedNormalization) {
            try JSONDecoder().decode(ChapterContent.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(throws: ChapterContentError.duplicateElement) {
            try ChapterContent(chapter: original.chapter, sourceRevision: "r", blocks: [original.blocks[1], original.blocks[1]])
        }
        #expect(throws: ChapterContentError.invalidCommentTarget) {
            try ChapterContent(chapter: original.chapter, sourceRevision: "r", blocks: [original.blocks[1],
                .comment(.init(id: "c", paragraphID: "absent", externalReference: "thread"))])
        }
        #expect(throws: ChapterContentError.emptyContent) {
            try ChapterContent(chapter: original.chapter, sourceRevision: "r", blocks: [original.blocks[0]])
        }
        #expect(throws: ChapterContentError.invalidDigest) { try ChapterDocument(content: original) { _ in "not-sha256" } }
    }

    private func sample() throws -> ChapterContent {
        let book = try SourceBookReference(installationID: SourceInstallationID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), referenceVersion: 1, key: "book")
        return try ChapterContent(chapter: ChapterReference(book: book, key: "chapter"), sourceRevision: "r1", blocks: [
            .image(.init(id: "cover", resource: .init(id: "cover-resource", reference: "cover.png"))),
            .paragraph(.init(id: "p1", runs: [.text("重复", TextStyle())])),
            .paragraph(.init(id: "p2", runs: [
                .image(.init(id: "inline", resource: .init(id: "inline-resource", reference: "inline.png"))),
                .text("重复", TextStyle()),
                .comment(.init(id: "comment", paragraphID: "p2", externalReference: "thread"))
            ])),
            .image(.init(id: "unmarked", resource: .init(id: "unmarked-resource", reference: "trailing.svg"))),
            .paragraph(.init(id: "unicode", runs: [.text("e", TextStyle()), .text("\u{301} 👩🏽‍💻", TextStyle(emphasis: true))]))
        ])
    }

    private func digest(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #elseif os(Windows)
        // Use the system SHA-256 provider in process: spawning a child can inherit
        // another parallel test's file handles and block Windows atomic replacement.
        var provider: BCRYPT_ALG_HANDLE?
        let algorithm = Array("SHA256".utf16) + [0]
        let opened = algorithm.withUnsafeBufferPointer { BCryptOpenAlgorithmProvider(&provider, $0.baseAddress, nil, 0) }
        try #require(opened == 0)
        defer { _ = BCryptCloseAlgorithmProvider(provider, 0) }
        var input = Array(data)
        var output = [UInt8](repeating: 0, count: 32)
        let status = input.withUnsafeMutableBufferPointer {
            BCryptHash(provider, nil, 0, $0.baseAddress, ULONG($0.count), &output, 32)
        }
        try #require(status == 0)
        return output.map { String(format: "%02x", $0) }.joined()
        #else
        throw ChapterContentError.invalidDigest
        #endif
    }
}
