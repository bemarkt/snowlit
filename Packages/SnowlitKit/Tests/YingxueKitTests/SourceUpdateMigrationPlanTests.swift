import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct SourceUpdateMigrationPlanTests {
    @Test func retainedInvalidatedChaptersAreMigratedFromTheirActualVersion() throws {
        let prepared = try snapshot(targetVersion: 3)
        let plan = try SourceUpdateMigrationPlan(prepared: prepared)
        #expect(plan.referenceInputs.map(\.fromVersion) == [1, 2])
        #expect(plan.referenceInputs[0].books[0].chapters == ["lost"])
        #expect(plan.referenceInputs[1].books[0].chapters == ["new-chapter"])
        let results = plan.referenceInputs.map(result)
        let values = try plan.validate(references: results.reversed(), state: nil)
        let changes = try #require(values.references)
        #expect(changes.books.count == 2 && values.state == nil)
        let adopted = try SourceReferenceAdoption(prepared: prepared, changes: changes)
        #expect(try adopted.binding(for: prepared.books[0].book).reference.referenceVersion == 3)
        let encoded = try YingxueWireCodec.encode(plan.referenceInputs[0])
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains(prepared.installation.id.rawValue.uuidString))
        #expect(!text.contains(prepared.books[0].book.id.rawValue.uuidString))
        #expect(!text.contains("documentRevision"))
    }

    @Test func everyVersionMustReturnExactlyOnceAndCollisionsAreRejectedTogether() throws {
        let plan = try SourceUpdateMigrationPlan(prepared: snapshot(targetVersion: 3))
        let first = result(plan.referenceInputs[0])
        #expect(throws: SourceMigrationFailure.incompleteMapping) { try plan.validate(references: [first], state: nil) }
        #expect(throws: SourceMigrationFailure.duplicateReference) { try plan.validate(references: [first, first], state: nil) }
        let conflicting = plan.referenceInputs.map { input in
            YingxueWire.ReferenceMigrationResult(fromVersion: input.fromVersion, toVersion: input.toVersion, books: input.books.map {
                .mapped(.init(kind: .mapped, old: $0.book, new: .init(key: "book"), chapters: $0.chapters.map {
                    .mapped(.init(kind: .mapped, oldKey: $0, newKey: "merged"))
                }))
            })
        }
        #expect(throws: SourceUpdateFailure.invalidMigration) { try plan.validate(references: conflicting, state: nil) }
        let wrongVersion = YingxueWire.ReferenceMigrationResult(fromVersion: first.fromVersion, toVersion: 4, books: first.books)
        #expect(throws: SourceMigrationFailure.versionMismatch) {
            try plan.validate(references: [wrongVersion, result(plan.referenceInputs[1])], state: nil)
        }
    }

    @Test func rollbackUsesHostIdentityForTargetVersionWithoutClearingInvalidation() throws {
        let prepared = try snapshot(targetVersion: 1)
        let plan = try SourceUpdateMigrationPlan(prepared: prepared)
        #expect(plan.referenceInputs.map(\.fromVersion) == [2])
        let input = try #require(plan.referenceInputs.first)
        let response = YingxueWire.ReferenceMigrationResult(fromVersion: 2, toVersion: 1, books: [
            .mapped(.init(kind: .mapped, old: input.books[0].book, new: .init(key: "old"), chapters: [
                .mapped(.init(kind: .mapped, oldKey: "new-chapter", newKey: "chapter"))]))])
        let values = try plan.validate(references: [response], state: nil)
        let transition = try SourceReferenceTransition(installationID: prepared.installation.id, installationRevision: 3,
            changes: #require(values.references))
        let history = try SourceReferenceHistory(prepared.referenceHistory + [transition])
        let lost = try ChapterReference(book: prepared.books[0].references[0], key: "lost")
        #expect(history.resolve(lost).invalidation == .removed)
    }

    @Test func stateAndReferencesHaveIndependentVersionsAndRequiredResults() throws {
        let plan = try SourceUpdateMigrationPlan(prepared: snapshot(targetVersion: 2, stateVersion: 2))
        #expect(plan.referenceInputs.isEmpty)
        let input = try #require(plan.stateInput)
        #expect(input.fromVersion == 1 && input.toVersion == 2 && input.snapshot.revision == 4)
        #expect(throws: SourceMigrationFailure.versionMismatch) { try plan.validate(references: [], state: nil) }
        let values = try plan.validate(references: [], state: .init(fromVersion: 1, toVersion: 2, expectedRevision: 4,
            entries: [.init(key: "setting", value: "new")]))
        #expect(values.references == nil && values.state?.entries.first?.value == "new")
        let same = try SourceUpdateMigrationPlan(prepared: snapshot(targetVersion: 2))
        #expect(same.referenceInputs.isEmpty && same.stateInput == nil)
        #expect(try same.validate(references: [], state: nil).references == nil)
    }

    private func result(_ input: YingxueWire.ReferenceMigrationInput) -> YingxueWire.ReferenceMigrationResult {
        .init(fromVersion: input.fromVersion, toVersion: input.toVersion, books: input.books.map { book in
            .mapped(.init(kind: .mapped, old: book.book, new: .init(key: "book"), chapters: book.chapters.map {
                .mapped(.init(kind: .mapped, oldKey: $0, newKey: "v\(input.fromVersion)-\($0)"))
            }))
        })
    }

    private func snapshot(targetVersion: Int, stateVersion: Int = 1) throws -> SourceUpdateSnapshot {
        let id = SourceInstallationID()
        let old = try SourceBookReference(installationID: id, referenceVersion: 1, key: "old")
        let current = try SourceBookReference(installationID: id, referenceVersion: 2, key: "current")
        let chapter = try ChapterReference(book: old, key: "chapter")
        let lost = try ChapterReference(book: old, key: "lost")
        let newChapter = try ChapterReference(book: current, key: "new-chapter")
        let changes = try SourceReferenceChanges(targetVersion: 2, books: [
            .init(original: old, outcome: .mapped(current), chapters: [
                .init(original: chapter, outcome: .mapped(newChapter)), .init(original: lost, outcome: .invalidated(.removed))])])
        let transition = try SourceReferenceTransition(installationID: id, installationRevision: 2, changes: changes)
        let installed = try SourceInstallationSnapshot(id: id, importID: UUID(), scriptSHA256: String(repeating: "a", count: 64),
            metadata: metadata(2, stateVersion: 1), revision: 2, state: .enabled, configuration: [],
            allowsCredentialRead: false, websiteSessionID: UUID(), pendingCleanup: nil)
        let receipt = try SourceImportRecord(scriptSHA256: String(repeating: "b", count: 64),
            inspectionContractSHA256: String(repeating: "f", count: 64), fileName: "fixture.js", importedAt: Date())
        let book = LibraryBook(id: LocalBookID(), reference: current, title: "Book", author: nil)
        return try .init(installation: installed, candidate: receipt, candidateMetadata: metadata(targetVersion, stateVersion: stateVersion),
            inventoryRevision: 4, books: [.init(book: book, references: [old, current], chapterReferences: [chapter, lost, newChapter],
                catalog: nil, checkpoint: nil)], currentState: .init(stateVersion: 1, revision: 4, entries: []),
            targetState: .init(stateVersion: stateVersion, revision: stateVersion == 1 ? 4 : 0, entries: []), referenceHistory: [transition])
    }

    private func metadata(_ version: Int, stateVersion: Int) throws -> SourceScriptMetadata {
        try .init(sourceID: "org.example.migration", name: "Fixture", scriptVersion: "\(version)", protocolVersion: 1,
                  referenceVersion: version, stateVersion: stateVersion)
    }
}
