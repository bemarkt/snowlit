import Foundation

/// Deduplicates only aliases established by accepted transitions. An invalidated
/// chapter retains its last known version and remains an explicit migration input.
public struct SourceReferenceMigrationInventory: Sendable {
    public struct Book: Sendable {
        public let localBookID: LocalBookID
        public let reference: SourceBookReference
        public let chapters: [ChapterReference]
    }
    public let books: [Book]
    public let history: SourceReferenceHistory

    public init(prepared: SourceUpdateSnapshot) throws {
        history = try SourceReferenceHistory(prepared.referenceHistory)
        var owners: [SourceBookReference: LocalBookID] = [:]
        var chapters: [SourceBookReference: Set<ChapterReference>] = [:]
        func register(_ reference: SourceBookReference, bookID: LocalBookID) throws {
            guard owners[reference] == nil || owners[reference] == bookID else { throw SourceUpdateFailure.invalidInventory }
            owners[reference] = bookID
        }
        for book in prepared.books {
            for reference in book.references {
                try register(history.resolve(reference).reference, bookID: book.book.id)
            }
            for reference in book.chapterReferences {
                let resolved = history.resolve(reference).reference
                try register(resolved.book, bookID: book.book.id)
                chapters[resolved.book, default: []].insert(resolved)
            }
        }
        books = owners.keys.sorted {
            if $0.referenceVersion != $1.referenceVersion { return $0.referenceVersion < $1.referenceVersion }
            return $0.key.utf8.lexicographicallyPrecedes($1.key.utf8)
        }.map { reference in
            Book(localBookID: owners[reference]!, reference: reference,
                 chapters: (chapters[reference] ?? []).sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) })
        }
    }
}

/// Validates complete coverage and historical ownership against the exact SQL
/// preparation snapshot. Storage must still compare that snapshot at commit.
public struct SourceReferenceAdoption: Sendable {
    public let prepared: SourceUpdateSnapshot
    public let changes: SourceReferenceChanges
    public let inventory: SourceReferenceMigrationInventory

    public init(prepared: SourceUpdateSnapshot, changes: SourceReferenceChanges) throws {
        guard changes.targetVersion == prepared.candidateMetadata.referenceVersion,
              changes.targetVersion != prepared.installation.metadata.referenceVersion else {
            throw SourceUpdateFailure.invalidMigration
        }
        let inventory = try SourceReferenceMigrationInventory(prepared: prepared)
        let expected = Dictionary(uniqueKeysWithValues: inventory.books.map { ($0.reference, $0) })
        guard Set(changes.books.map(\.original)) == Set(expected.keys) else { throw SourceUpdateFailure.invalidMigration }
        var historicalOwners: [SourceBookReference: LocalBookID] = [:]
        var historicalChapters = Set<ChapterReference>()
        for item in prepared.books {
            for reference in item.references {
                guard historicalOwners[reference] == nil || historicalOwners[reference] == item.book.id else {
                    throw SourceUpdateFailure.invalidInventory
                }
                historicalOwners[reference] = item.book.id
            }
            historicalChapters.formUnion(item.chapterReferences)
        }
        var targetOwners: [SourceBookReference: LocalBookID] = [:]
        var bookTargets: [LocalBookID: SourceBookReference] = [:]
        for mapping in changes.books {
            guard let source = expected[mapping.original],
                  Set(mapping.chapters.map(\.original)) == Set(source.chapters) else { throw SourceUpdateFailure.invalidMigration }
            if case .mapped(let target) = mapping.outcome {
                guard historicalOwners[target] == nil || historicalOwners[target] == source.localBookID,
                      targetOwners[target] == nil || targetOwners[target] == source.localBookID,
                      bookTargets[source.localBookID] == nil || bookTargets[source.localBookID] == target else {
                    throw SourceUpdateFailure.invalidMigration
                }
                targetOwners[target] = source.localBookID; bookTargets[source.localBookID] = target
            }
            for chapter in mapping.chapters {
                if case .mapped(let target) = chapter.outcome, historicalChapters.contains(target) {
                    guard inventory.history.resolve(target).reference == chapter.original else {
                        throw SourceUpdateFailure.invalidMigration
                    }
                }
            }
        }
        self.prepared = prepared; self.changes = changes; self.inventory = inventory
    }

    public func binding(for book: LibraryBook) throws -> SourceReferenceResolution<SourceBookReference> {
        let current = inventory.history.resolve(book.reference)
        guard let mapping = changes.books.first(where: { $0.original == current.reference }) else { throw SourceUpdateFailure.invalidInventory }
        switch mapping.outcome {
        case .mapped(let next):
            return .init(reference: next, invalidation: next == current.reference ? current.invalidation : nil)
        case .invalidated(let reason): return .init(reference: current.reference, invalidation: reason)
        }
    }
}
