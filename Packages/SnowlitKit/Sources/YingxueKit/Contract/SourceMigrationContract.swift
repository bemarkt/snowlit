import Foundation
import SnowlitCore

public enum SourceMigrationFailure: Error, Equatable, Sendable {
    case versionMismatch, duplicateReference, incompleteMapping, unexpectedReference, mergedIdentity, revisionMismatch
}

/// A validated candidate; activating it and persisting reference changes must
/// share the installation update transaction. Invalidated books stay local.
public struct SourceReferenceMigration: Sendable {
    public struct Chapter: Sendable {
        public let original: ChapterReference
        public let replacement: ChapterReference?
        public let invalidation: YingxueWire.ReferenceInvalidationReason?
    }
    public struct Book: Sendable {
        public let original: SourceBookReference
        public let replacement: SourceBookReference?
        public let chapters: [Chapter]
        public let invalidation: YingxueWire.ReferenceInvalidationReason?
    }
    public let books: [Book]

    public init(input: YingxueWire.ReferenceMigrationInput, result: YingxueWire.ReferenceMigrationResult,
                installationID: SourceInstallationID) throws {
        _ = try YingxueWireCodec.encode(input)
        _ = try YingxueWireCodec.encode(result)
        guard input.fromVersion != input.toVersion, input.fromVersion == result.fromVersion,
              input.toVersion == result.toVersion else { throw SourceMigrationFailure.versionMismatch }
        var inventory: [Data: YingxueWire.ReferenceInventoryBook] = [:]
        for book in input.books {
            let key = Data(book.book.key.utf8)
            guard inventory[key] == nil, Set(book.chapters.map { Data($0.utf8) }).count == book.chapters.count else {
                throw SourceMigrationFailure.duplicateReference
            }
            inventory[key] = book
        }
        var mapped = Set<Data>(), destinations = Set<Data>(), books: [Book] = []
        for mapping in result.books {
            let old: String
            switch mapping { case .mapped(let value): old = value.old.key; case .invalidated(let value): old = value.old.key }
            let key = Data(old.utf8)
            guard let source = inventory[key] else { throw SourceMigrationFailure.unexpectedReference }
            guard mapped.insert(key).inserted else { throw SourceMigrationFailure.duplicateReference }
            let original = try SourceBookReference(installationID: installationID, referenceVersion: input.fromVersion, key: old)
            switch mapping {
            case .invalidated(let value):
                let chapters = try source.chapters.map { try Chapter(original: ChapterReference(book: original, key: $0), replacement: nil, invalidation: value.reason) }
                books.append(.init(original: original, replacement: nil, chapters: chapters, invalidation: value.reason))
            case .mapped(let value):
                guard destinations.insert(Data(value.new.key.utf8)).inserted else { throw SourceMigrationFailure.mergedIdentity }
                let replacement = try SourceBookReference(installationID: installationID, referenceVersion: input.toVersion, key: value.new.key)
                let expected = Set(source.chapters.map { Data($0.utf8) })
                var seen = Set<Data>(), targets = Set<Data>(), chapters: [Chapter] = []
                for chapter in value.chapters {
                    let oldKey: String
                    switch chapter { case .mapped(let value): oldKey = value.oldKey; case .invalidated(let value): oldKey = value.oldKey }
                    guard expected.contains(Data(oldKey.utf8)) else { throw SourceMigrationFailure.unexpectedReference }
                    guard seen.insert(Data(oldKey.utf8)).inserted else { throw SourceMigrationFailure.duplicateReference }
                    let before = try ChapterReference(book: original, key: oldKey)
                    switch chapter {
                    case .mapped(let value):
                        guard targets.insert(Data(value.newKey.utf8)).inserted else { throw SourceMigrationFailure.mergedIdentity }
                        chapters.append(try .init(original: before, replacement: ChapterReference(book: replacement, key: value.newKey), invalidation: nil))
                    case .invalidated(let value): chapters.append(.init(original: before, replacement: nil, invalidation: value.reason))
                    }
                }
                guard seen == expected else { throw SourceMigrationFailure.incompleteMapping }
                books.append(.init(original: original, replacement: replacement, chapters: chapters, invalidation: nil))
            }
        }
        guard mapped == Set(inventory.keys) else { throw SourceMigrationFailure.incompleteMapping }
        self.books = books
    }
}

public enum SourceStateMigration {
    /// The returned version starts a new state's revision sequence. The old
    /// snapshot remains intact until the installation update commits atomically.
    public static func validate(input: YingxueWire.StateMigrationInput, result: YingxueWire.StateMigrationResult) throws -> SourcePublicState {
        _ = try YingxueWireCodec.encode(input)
        _ = try YingxueWireCodec.encode(result)
        guard input.fromVersion != input.toVersion, input.fromVersion == input.snapshot.stateVersion,
              result.fromVersion == input.fromVersion, result.toVersion == input.toVersion else { throw SourceMigrationFailure.versionMismatch }
        guard result.expectedRevision == input.snapshot.revision else { throw SourceMigrationFailure.revisionMismatch }
        _ = try SourcePublicStateAdapter.decode(input.snapshot)
        return try SourcePublicState(stateVersion: input.toVersion, revision: 0,
            entries: result.entries.map { try .init(key: $0.key, value: $0.value) })
    }
}

public enum SourcePublicStateAdapter {
    public static func decode(_ value: YingxueWire.PublicStateSnapshot) throws -> SourcePublicState {
        _ = try YingxueWireCodec.encode(value)
        return try .init(stateVersion: value.stateVersion, revision: value.revision, entries: value.entries.map { try .init(key: $0.key, value: $0.value) })
    }
    public static func encode(_ value: SourcePublicState) -> YingxueWire.PublicStateSnapshot {
        .init(stateVersion: value.stateVersion, revision: value.revision, entries: value.entries.map { .init(key: $0.key, value: $0.value) })
    }
}
