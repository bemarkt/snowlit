import Foundation

public enum SourceReferenceInvalidation: String, Codable, Sendable {
    case removed, unavailable, changedIdentity
}

public enum SourceReferenceOutcome<Reference: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    case mapped(Reference)
    case invalidated(SourceReferenceInvalidation)
}

/// A last known identity is retained even when a source explicitly invalidates
/// it. This permits offline reading and a later, explicit manual migration.
public struct SourceReferenceResolution<Reference: Equatable & Sendable>: Equatable, Sendable {
    public let reference: Reference
    public let invalidation: SourceReferenceInvalidation?
    public init(reference: Reference, invalidation: SourceReferenceInvalidation? = nil) {
        self.reference = reference; self.invalidation = invalidation
    }
}

/// Native, validated mapping values. These are not wire models or document
/// edits: adopting a mapping never rewrites a saved paragraph anchor.
public struct SourceReferenceChanges: Equatable, Codable, Sendable {
    public struct Chapter: Equatable, Codable, Sendable {
        public let original: ChapterReference
        public let outcome: SourceReferenceOutcome<ChapterReference>
        public init(original: ChapterReference, outcome: SourceReferenceOutcome<ChapterReference>) {
            self.original = original; self.outcome = outcome
        }
    }
    public struct Book: Equatable, Codable, Sendable {
        public let original: SourceBookReference
        public let outcome: SourceReferenceOutcome<SourceBookReference>
        public let chapters: [Chapter]
        public init(original: SourceBookReference, outcome: SourceReferenceOutcome<SourceBookReference>, chapters: [Chapter]) {
            self.original = original; self.outcome = outcome; self.chapters = chapters
        }
    }

    public let targetVersion: Int
    public let books: [Book]

    public init(targetVersion: Int, books: [Book]) throws {
        guard targetVersion > 0, Set(books.map(\.original)).count == books.count else {
            throw SourceUpdateFailure.invalidMigration
        }
        var chapterDestinations = Set<ChapterReference>()
        for book in books {
            guard Set(book.chapters.map(\.original)).count == book.chapters.count,
                  book.chapters.allSatisfy({ $0.original.book == book.original }) else {
                throw SourceUpdateFailure.invalidMigration
            }
            switch book.outcome {
            case .mapped(let replacement):
                guard replacement.installationID == book.original.installationID,
                      replacement.referenceVersion == targetVersion else { throw SourceUpdateFailure.invalidMigration }
            case .invalidated: break
            }
            for chapter in book.chapters {
                switch (book.outcome, chapter.outcome) {
                case (.mapped(let replacement), .mapped(let next)):
                    guard next.book == replacement, chapterDestinations.insert(next).inserted else {
                        throw SourceUpdateFailure.invalidMigration
                    }
                case (.mapped, .invalidated): break
                case (.invalidated(let reason), .invalidated(let childReason)):
                    guard reason == childReason else { throw SourceUpdateFailure.invalidMigration }
                case (.invalidated, .mapped): throw SourceUpdateFailure.invalidMigration
                }
            }
            // A version already present in the target inventory retains its
            // exact identity. A source cannot reinterpret keys within a version.
            if book.original.referenceVersion == targetVersion {
                guard book.outcome == .mapped(book.original),
                      book.chapters.allSatisfy({ $0.outcome == .mapped($0.original) }) else {
                    throw SourceUpdateFailure.invalidMigration
                }
            }
        }
        self.targetVersion = targetVersion; self.books = books
    }

    private enum CodingKeys: CodingKey { case targetVersion, books }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(targetVersion: values.decode(Int.self, forKey: .targetVersion),
                      books: values.decode([Book].self, forKey: .books))
    }
}

public struct SourceReferenceTransition: Equatable, Codable, Sendable {
    public let installationID: SourceInstallationID
    public let installationRevision: Int64
    public let changes: SourceReferenceChanges

    public init(installationID: SourceInstallationID, installationRevision: Int64, changes: SourceReferenceChanges) throws {
        guard installationRevision > 0, installationRevision <= 9_007_199_254_740_991,
              changes.books.allSatisfy({ $0.original.installationID == installationID }) else {
            throw SourceUpdateFailure.invalidMigration
        }
        self.installationID = installationID; self.installationRevision = installationRevision; self.changes = changes
    }

    private enum CodingKeys: CodingKey { case installationID, installationRevision, changes }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(installationID: values.decode(SourceInstallationID.self, forKey: .installationID),
                      installationRevision: values.decode(Int64.self, forKey: .installationRevision),
                      changes: values.decode(SourceReferenceChanges.self, forKey: .changes))
    }
}

/// Replay accepted transitions in installation order, never by reference version
/// number. A manual rollback may revisit a version without causing a graph cycle.
public struct SourceReferenceHistory: Sendable {
    private let books: [[SourceBookReference: SourceReferenceOutcome<SourceBookReference>]]
    private let chapters: [[ChapterReference: SourceReferenceOutcome<ChapterReference>]]

    public init(_ transitions: [SourceReferenceTransition]) throws {
        var previous: Int64 = 0
        let installation = transitions.first?.installationID
        for item in transitions {
            guard item.installationID == installation, item.installationRevision > previous else {
                throw SourceUpdateFailure.invalidInventory
            }
            previous = item.installationRevision
        }
        books = transitions.map { Dictionary(uniqueKeysWithValues: $0.changes.books.map { ($0.original, $0.outcome) }) }
        chapters = transitions.map { Dictionary(uniqueKeysWithValues: $0.changes.books.flatMap(\.chapters).map { ($0.original, $0.outcome) }) }
    }

    public func resolve(_ reference: SourceBookReference) -> SourceReferenceResolution<SourceBookReference> {
        Self.resolve(reference, using: books)
    }

    public func resolve(_ reference: ChapterReference) -> SourceReferenceResolution<ChapterReference> {
        Self.resolve(reference, using: chapters)
    }

    private static func resolve<T: Hashable & Codable & Sendable>(_ original: T, using steps: [[T: SourceReferenceOutcome<T>]]) -> SourceReferenceResolution<T> {
        var reference = original
        var invalidation: SourceReferenceInvalidation?
        for step in steps {
            switch step[reference] {
            case .mapped(let next):
                // Retaining an identity already in the target version is a
                // host operation, not new source evidence of availability.
                if next != reference { invalidation = nil }
                reference = next
            case .invalidated(let reason): invalidation = reason
            case nil: break
            }
        }
        return .init(reference: reference, invalidation: invalidation)
    }
}
