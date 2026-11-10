import Foundation
import SnowlitCore

/// Adapts one immutable preparation snapshot into source-visible migrations.
/// Invalidated historical references may belong to several older versions.
/// No local IDs, database tokens or saved document anchors enter the wire input.
public struct SourceUpdateMigrationPlan: Sendable {
    public let referenceInputs: [YingxueWire.ReferenceMigrationInput]
    public let stateInput: YingxueWire.StateMigrationInput?
    private let prepared: SourceUpdateSnapshot
    private let inventory: SourceReferenceMigrationInventory

    public init(prepared: SourceUpdateSnapshot) throws {
        self.prepared = prepared
        inventory = try SourceReferenceMigrationInventory(prepared: prepared)
        let target = prepared.candidateMetadata.referenceVersion
        if target != prepared.installation.metadata.referenceVersion {
            let groups = Dictionary(grouping: inventory.books, by: { $0.reference.referenceVersion })
            referenceInputs = groups.keys.filter { $0 != target }.sorted().map { version in
                .init(fromVersion: version, toVersion: target, books: (groups[version] ?? []).map {
                    .init(book: .init(key: $0.reference.key), chapters: $0.chapters.map(\.key))
                })
            }
        } else {
            referenceInputs = []
        }
        stateInput = prepared.currentState.stateVersion == prepared.targetState.stateVersion ? nil :
            .init(fromVersion: prepared.currentState.stateVersion, toVersion: prepared.targetState.stateVersion,
                  snapshot: SourcePublicStateAdapter.encode(prepared.currentState))
    }

    /// All groups are required exactly once. Cross-version identity collisions
    /// are checked together before Storage repeats its SQL snapshot comparison.
    public func validate(references: [YingxueWire.ReferenceMigrationResult],
                         state: YingxueWire.StateMigrationResult?) throws -> SourceUpdateMigrationValues {
        var results: [Int: YingxueWire.ReferenceMigrationResult] = [:]
        for result in references {
            guard results.updateValue(result, forKey: result.fromVersion) == nil else {
                throw SourceMigrationFailure.duplicateReference
            }
        }
        guard Set(results.keys) == Set(referenceInputs.map(\.fromVersion)) else {
            throw SourceMigrationFailure.incompleteMapping
        }
        let target = prepared.candidateMetadata.referenceVersion
        let changes: SourceReferenceChanges?
        if target != prepared.installation.metadata.referenceVersion {
            var books: [SourceReferenceChanges.Book] = inventory.books.filter {
                $0.reference.referenceVersion == target
            }.map { item in
                .init(original: item.reference, outcome: .mapped(item.reference),
                      chapters: item.chapters.map { .init(original: $0, outcome: .mapped($0)) })
            }
            for input in referenceInputs {
                guard let result = results[input.fromVersion] else { throw SourceMigrationFailure.incompleteMapping }
                let migration = try SourceReferenceMigration(input: input, result: result, installationID: prepared.installation.id)
                books += try migration.books.map { book in
                    .init(original: book.original, outcome: try Self.outcome(book.replacement, book.invalidation),
                          chapters: try book.chapters.map {
                              .init(original: $0.original, outcome: try Self.outcome($0.replacement, $0.invalidation))
                          })
                }
            }
            let combined = try SourceReferenceChanges(targetVersion: target, books: books)
            _ = try SourceReferenceAdoption(prepared: prepared, changes: combined)
            changes = combined
        } else {
            changes = nil
        }
        let migratedState: SourcePublicState?
        switch (stateInput, state) {
        case (.some(let input), .some(let result)):
            migratedState = try SourceStateMigration.validate(input: input, result: result)
        case (nil, nil): migratedState = nil
        default: throw SourceMigrationFailure.versionMismatch
        }
        return .init(references: changes, state: migratedState)
    }

    private static func outcome<T>(_ replacement: T?, _ reason: YingxueWire.ReferenceInvalidationReason?) throws -> SourceReferenceOutcome<T> {
        if let replacement { return .mapped(replacement) }
        guard let reason, let invalidation = SourceReferenceInvalidation(rawValue: reason.rawValue) else {
            throw SourceMigrationFailure.incompleteMapping
        }
        return .invalidated(invalidation)
    }
}

public struct SourceUpdateMigrationValues: Sendable {
    public let references: SourceReferenceChanges?
    public let state: SourcePublicState?
}
