import Foundation
import Testing
@testable import SnowlitCore

struct LibraryModelTests {
    @Test func opaqueReferenceEqualityMatchesExactUTF8Identity() throws {
        let installation = SourceInstallationID()
        let first = try SourceBookReference(installationID: installation, referenceVersion: 1, key: "é")
        let second = try SourceBookReference(installationID: installation, referenceVersion: 1, key: "e\u{301}")
        #expect(first != second)
        #expect(Set([first, second]).count == 2)
        let a = try ChapterReference(book: first, key: "é")
        let b = try ChapterReference(book: first, key: "e\u{301}")
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
        #expect(throws: LibraryModelError.invalidReference) {
            try SourceBookReference(installationID: installation, referenceVersion: 1, key: "\u{0}")
        }
    }
    @Test func referencesCarryInstallationAndVersionWithoutUsingTitlesOrLogin() throws {
        let installation = SourceInstallationID()
        let first = try SourceBookReference(installationID: installation, referenceVersion: 1, key: "book")
        let update = try SourceBookReference(installationID: installation, referenceVersion: 2, key: "book")
        let otherInstall = try SourceBookReference(installationID: SourceInstallationID(), referenceVersion: 1, key: "book")
        #expect(first != update && first != otherInstall)
        #expect(try JSONDecoder().decode(SourceBookReference.self, from: JSONEncoder().encode(first)) == first)
        #expect(throws: LibraryModelError.invalidReference) {
            try SourceBookReference(installationID: installation, referenceVersion: 0, key: "book")
        }
    }

    @Test func catalogKeepsDuplicateTitlesButRejectsDuplicateOrForeignReferences() throws {
        let book = try reference("book")
        let a = try CatalogEntry(reference: ChapterReference(book: book, key: "a"), title: "同名章节")
        let b = try CatalogEntry(reference: ChapterReference(book: book, key: "b"), title: "同名章节")
        let catalog = try CatalogSnapshot(book: book, revision: "r1", entries: [a, b])
        #expect(catalog.entries.map(\.reference.key) == ["a", "b"])
        #expect(throws: LibraryModelError.duplicateChapter) {
            try CatalogSnapshot(book: book, revision: "r1", entries: [a, a])
        }
        let foreign = try CatalogEntry(reference: ChapterReference(book: reference("other"), key: "a"), title: "same")
        #expect(throws: LibraryModelError.differentBook) {
            try CatalogSnapshot(book: book, revision: "r1", entries: [a, foreign])
        }
        #expect(throws: LibraryModelError.emptyCatalog) {
            try CatalogSnapshot(book: book, revision: "r1", entries: [])
        }
    }

    @Test func decodingRevalidatesPositionPreferencesAndCatalog() throws {
        let chapter = try ChapterReference(book: reference("book"), key: "chapter")
        let position = try ReadingPosition(chapter: chapter, documentRevision: "revision",
            normalizationVersion: 1, elementID: "p2", utf16Offset: 4)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(position)) as? [String: Any])
        json["utf16Offset"] = -1
        #expect(throws: LibraryModelError.invalidPosition) {
            try JSONDecoder().decode(ReadingPosition.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(throws: LibraryModelError.invalidPreferences) {
            try JSONDecoder().decode(ReaderPreferences.self, from: Data(#"{"fontSize":0,"theme":"dark"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ReaderPreferences.self, from: Data(#"{"fontSize":20,"theme":"unknown"}"#.utf8))
        }
        let entry = CatalogEntry(reference: chapter, title: "chapter")
        let snapshot = try CatalogSnapshot(book: chapter.book, revision: "r1", entries: [entry])
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        encoded["entries"] = []
        #expect(throws: LibraryModelError.emptyCatalog) {
            try JSONDecoder().decode(CatalogSnapshot.self, from: JSONSerialization.data(withJSONObject: encoded))
        }
    }

    private func reference(_ key: String) throws -> SourceBookReference {
        try SourceBookReference(installationID: SourceInstallationID(), referenceVersion: 1, key: key)
    }
}
