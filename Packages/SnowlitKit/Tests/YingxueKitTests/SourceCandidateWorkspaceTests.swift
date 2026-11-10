import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct SourceCandidateWorkspaceTests {
    @Test func candidateWritesAreIsolatedAndRequireTheSnapshotRevision() async throws {
        let original = try SourcePublicState(stateVersion: 2, revision: 4, entries: [.init(key: "saved", value: "old")])
        let workspace = SourceCandidateWorkspace(installationID: .init(), state: original)
        let accepted = try await workspace.writeState(.init(stateVersion: 2, expectedRevision: 4, entries: [.init(key: "saved", value: "candidate")]))
        #expect(accepted.written && accepted.snapshot.revision == 5)
        let stale = try await workspace.writeState(.init(stateVersion: 2, expectedRevision: 4, entries: []))
        #expect(!stale.written && stale.snapshot == accepted.snapshot)
        #expect(original.revision == 4 && original.entries.first?.value == "old")
        await #expect(throws: SourceCandidateFailure.wrongStateVersion) {
            try await workspace.readState(.init(stateVersion: 1))
        }
        await #expect(throws: SourcePublicStateFailure.duplicateKey) {
            try await workspace.writeState(.init(stateVersion: 2, expectedRevision: 4,
                entries: [.init(key: "x", value: "one"), .init(key: "x", value: "two")]))
        }
    }

    @Test func concurrentCandidateWritesHaveOneWinner() async throws {
        let workspace = SourceCandidateWorkspace(installationID: .init(), state: try .init(stateVersion: 1, revision: 0, entries: []))
        async let first = workspace.writeState(.init(stateVersion: 1, expectedRevision: 0, entries: [.init(key: "value", value: "first")]))
        async let second = workspace.writeState(.init(stateVersion: 1, expectedRevision: 0, entries: [.init(key: "value", value: "second")]))
        let results = try await [first, second]
        #expect(results.filter(\.written).count == 1)
        #expect(results[0].snapshot == results[1].snapshot)
        #expect(try await workspace.readState(.init(stateVersion: 1)).revision == 1)
    }

    @Test func candidateCredentialsCannotUseOtherInstallationsOrSurviveClose() async throws {
        let installation = SourceInstallationID()
        let workspace = SourceCandidateWorkspace(installationID: installation, state: try .init(stateVersion: 1, revision: 0, entries: []))
        let id = StoredCredentialID(installationID: installation)
        try await workspace.write(.init(utf8: "temporary"), for: id)
        #expect(try await workspace.read(id)?.bytes == Data("temporary".utf8))
        await #expect(throws: SourceCandidateFailure.wrongInstallation) {
            try await workspace.write(.init(utf8: "other"), for: .init(installationID: .init()))
        }
        await workspace.close()
        await #expect(throws: SourceCandidateFailure.closed) { try await workspace.read(id) }
        await #expect(throws: SourceCandidateFailure.closed) { try await workspace.write(.init(utf8: "late"), for: id) }
        await #expect(throws: SourceCandidateFailure.closed) {
            try await workspace.writeState(.init(stateVersion: 1, expectedRevision: 0, entries: []))
        }
        try await workspace.remove(id)
        try await workspace.removeAll(for: installation)
    }
}
