import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct SourceMigrationTests {
    @Test func completeMappingPreservesInstallationAndExactByteIdentities() throws {
        let installation = SourceInstallationID()
        let input = YingxueWire.ReferenceMigrationInput(fromVersion: 1, toVersion: 2, books: [
            .init(book: .init(key: "é"), chapters: ["c1", "c2"]), .init(book: .init(key: "e\u{301}"), chapters: ["c1"])])
        let result = YingxueWire.ReferenceMigrationResult(fromVersion: 1, toVersion: 2, books: [
            .mapped(.init(kind: .mapped, old: .init(key: "é"), new: .init(key: "new"), chapters: [
                .mapped(.init(kind: .mapped, oldKey: "c1", newKey: "n1")),
                .invalidated(.init(kind: .invalidated, oldKey: "c2", reason: .removed))])),
            .invalidated(.init(kind: .invalidated, old: .init(key: "e\u{301}"), reason: .changedIdentity))])
        let plan = try SourceReferenceMigration(input: input, result: result, installationID: installation)
        #expect(plan.books.count == 2)
        #expect(plan.books[0].original.installationID == installation && plan.books[0].replacement?.installationID == installation)
        #expect(plan.books[0].replacement?.referenceVersion == 2)
        #expect(plan.books[0].chapters[0].replacement?.key == "n1")
        #expect(plan.books[0].chapters[1].replacement == nil && plan.books[0].chapters[1].invalidation == .removed)
        #expect(plan.books[1].replacement == nil && plan.books[1].chapters[0].invalidation == .changedIdentity)
        #expect(plan.books[0].original != plan.books[1].original)
    }

    @Test func incompleteUnknownDuplicateAndMergedMappingsAreRejected() throws {
        let input = YingxueWire.ReferenceMigrationInput(fromVersion: 1, toVersion: 2, books: [.init(book: .init(key: "a"), chapters: ["1", "2"])])
        func check(_ books: [YingxueWire.BookMapping], _ failure: SourceMigrationFailure) {
            #expect(throws: failure) { try SourceReferenceMigration(input: input, result: .init(fromVersion: 1, toVersion: 2, books: books), installationID: SourceInstallationID()) }
        }
        check([], .incompleteMapping)
        check([.invalidated(.init(kind: .invalidated, old: .init(key: "foreign"), reason: .removed))], .unexpectedReference)
        let invalidated = YingxueWire.BookMapping.invalidated(.init(kind: .invalidated, old: .init(key: "a"), reason: .removed))
        check([invalidated, invalidated], .duplicateReference)
        func mapped(_ chapters: [YingxueWire.ChapterMapping]) -> YingxueWire.BookMapping {
            .mapped(.init(kind: .mapped, old: .init(key: "a"), new: .init(key: "b"), chapters: chapters))
        }
        check([mapped([])], .incompleteMapping)
        check([mapped([.mapped(.init(kind: .mapped, oldKey: "foreign", newKey: "new"))])], .unexpectedReference)
        check([mapped([.mapped(.init(kind: .mapped, oldKey: "1", newKey: "new")), .mapped(.init(kind: .mapped, oldKey: "2", newKey: "new"))])], .mergedIdentity)
        check([mapped([.mapped(.init(kind: .mapped, oldKey: "1", newKey: "new")), .invalidated(.init(kind: .invalidated, oldKey: "1", reason: .removed))])], .duplicateReference)
        let two = YingxueWire.ReferenceMigrationInput(fromVersion: 1, toVersion: 2, books: [.init(book: .init(key: "a"), chapters: []), .init(book: .init(key: "b"), chapters: [])])
        #expect(throws: SourceMigrationFailure.mergedIdentity) {
            try SourceReferenceMigration(input: two, result: .init(fromVersion: 1, toVersion: 2, books: [
                .mapped(.init(kind: .mapped, old: .init(key: "a"), new: .init(key: "merged"), chapters: [])),
                .mapped(.init(kind: .mapped, old: .init(key: "b"), new: .init(key: "merged"), chapters: []))]), installationID: SourceInstallationID())
        }
    }

    @Test func stateMigrationChecksVersionAndReadRevisionWithoutMutatingSnapshot() throws {
        let original = YingxueWire.PublicStateSnapshot(stateVersion: 1, revision: 4, entries: [.init(key: "category", value: "old")])
        let input = YingxueWire.StateMigrationInput(fromVersion: 1, toVersion: 2, snapshot: original)
        let result = YingxueWire.StateMigrationResult(fromVersion: 1, toVersion: 2, expectedRevision: 4, entries: [.init(key: "selectedCategory", value: "new")])
        let candidate = try SourceStateMigration.validate(input: input, result: result)
        #expect(candidate.stateVersion == 2 && candidate.revision == 0 && candidate.entries[0].value == "new")
        #expect(original.entries[0].value == "old" && original.revision == 4)
        #expect(throws: SourceMigrationFailure.revisionMismatch) {
            try SourceStateMigration.validate(input: input, result: .init(fromVersion: 1, toVersion: 2, expectedRevision: 3, entries: []))
        }
        #expect(throws: SourceMigrationFailure.versionMismatch) {
            try SourceStateMigration.validate(input: input, result: .init(fromVersion: 1, toVersion: 3, expectedRevision: 4, entries: []))
        }
        #expect(throws: SourcePublicStateFailure.duplicateKey) {
            try SourceStateMigration.validate(input: input, result: .init(fromVersion: 1, toVersion: 2, expectedRevision: 4, entries: [.init(key: "k", value: "a"), .init(key: "k", value: "b")]))
        }
    }

    @Test func upgradesRequireBothMigrationExportsWhenTheirVersionsChange() throws {
        let old = YingxueWire.Manifest(protocolVersion: 1, sourceID: "org.example.reader", name: "Fixture", scriptVersion: "1",
            referenceVersion: 1, stateVersion: 1, capabilities: [], origins: [], authentication: [], publicConfiguration: [])
        let next = YingxueWire.Manifest(protocolVersion: 1, sourceID: old.sourceID, name: old.name, scriptVersion: "2",
            referenceVersion: 2, stateVersion: 2, capabilities: [], origins: [], authentication: [], publicConfiguration: [])
        let upgrade = try SourceUpgradeAssessment(current: old, candidate: next)
        #expect(SourceModuleInspection.requirements(for: next, upgrade: upgrade) == ["migrateReferences", "migrateState"])
        let minimal = Data(#"{"kind":"accepted","exports":["search","book","chapters","chapter"]}"#.utf8)
        #expect(throws: SourceModuleInspection.Failure.missingExport) { try SourceModuleInspection.accept(minimal, manifest: next, upgrade: upgrade) }
        let complete = Data(#"{"kind":"accepted","exports":["search","book","chapters","chapter","migrateReferences","migrateState"]}"#.utf8)
        #expect(try SourceModuleInspection.accept(complete, manifest: next, upgrade: upgrade).count == 6)
    }

    @Test func publicStateValidationUsesExactUTF8AndValidatesDecoding() throws {
        let state = try SourcePublicState(stateVersion: 1, revision: 0, entries: [.init(key: "é", value: "é"), .init(key: "e\u{301}", value: "e\u{301}")])
        #expect(state.entries[0] != state.entries[1])
        #expect(try SourcePublicStateAdapter.decode(SourcePublicStateAdapter.encode(state)) == state)
        #expect(throws: SourcePublicStateFailure.duplicateKey) { try SourcePublicState(stateVersion: 1, revision: 0, entries: state.entries + state.entries) }
        #expect(throws: SourcePublicStateFailure.invalidRevision) { try SourcePublicState(stateVersion: 1, revision: -1, entries: []) }
        #expect(throws: SourcePublicStateFailure.invalidEntry) {
            try JSONDecoder().decode(SourcePublicStateEntry.self, from: Data(#"{"key":"","value":"x"}"#.utf8))
        }
    }
}
