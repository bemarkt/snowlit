import Foundation

public struct LocalBookID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct SourceInstallationID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Opaque source identity. Script digests, redirects, titles and website sessions
/// are deliberately absent; updating a script preserves its installation.
public struct SourceBookReference: Hashable, Codable, Sendable {
    public let installationID: SourceInstallationID
    public let referenceVersion: Int
    public let key: String

    public init(installationID: SourceInstallationID, referenceVersion: Int, key: String) throws {
        guard referenceVersion > 0, !key.isEmpty, !key.utf8.contains(0) else { throw LibraryModelError.invalidReference }
        self.installationID = installationID
        self.referenceVersion = referenceVersion
        self.key = key
    }

    // Opaque remote keys use exact UTF-8 identity, matching SQLite BINARY comparison.
    // Swift's canonical Unicode String equality could otherwise merge distinct keys.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.installationID == rhs.installationID && lhs.referenceVersion == rhs.referenceVersion
            && lhs.key.utf8.elementsEqual(rhs.key.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(installationID)
        hasher.combine(referenceVersion)
        hasher.combine(Data(key.utf8))
    }

    private enum CodingKeys: CodingKey { case installationID, referenceVersion, key }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(installationID: values.decode(SourceInstallationID.self, forKey: .installationID),
                      referenceVersion: values.decode(Int.self, forKey: .referenceVersion),
                      key: values.decode(String.self, forKey: .key))
    }
}

public struct ChapterReference: Hashable, Codable, Sendable {
    public let book: SourceBookReference
    public let key: String

    public init(book: SourceBookReference, key: String) throws {
        guard !key.isEmpty, !key.utf8.contains(0) else { throw LibraryModelError.invalidReference }
        self.book = book
        self.key = key
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.book == rhs.book && lhs.key.utf8.elementsEqual(rhs.key.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(book)
        hasher.combine(Data(key.utf8))
    }

    private enum CodingKeys: CodingKey { case book, key }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(book: values.decode(SourceBookReference.self, forKey: .book),
                      key: values.decode(String.self, forKey: .key))
    }
}

public enum LibraryModelError: Error, Equatable, Sendable {
    case invalidReference
    case emptyCatalog
    case invalidRevision
    case differentBook
    case duplicateChapter
    case invalidPosition
    case invalidPreferences
}
