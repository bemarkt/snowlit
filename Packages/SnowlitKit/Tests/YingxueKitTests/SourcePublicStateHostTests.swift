import Foundation
import SnowlitCore
import SnowlitStorage
import Testing
@testable import YingxueKit

struct SourcePublicStateHostTests {
    @Test func actualHostAndStoragePreserveCASAndIndependentCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnowlitStateHost-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error, "Unable to remove isolated state host") }
        }
        let store = try LibraryDatabase.create(at: root.appendingPathComponent("library.sqlite"))
        let installation = SourceInstallationID(), digest = String(repeating: "a", count: 64)
        let manifest = YingxueWire.Manifest(protocolVersion: 1, sourceID: "org.example.state", name: "State", scriptVersion: "1",
            referenceVersion: 1, stateVersion: 1, capabilities: [.publicState], origins: [], authentication: [], publicConfiguration: [])
        let policy = try SourceHostPolicy(installationID: installation, scriptSHA256: digest, manifest: manifest)
        let gate = try SourceOperationGate(installationID: installation, scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0)
        let access = try await store.beginPublicStateAccess(installationID: installation, stateVersion: 1)
        let request = YingxueWire.OperationInput.search(.init(kind: .search, input: .init(query: "book", cursor: nil)))
        let first = try await gate.begin(request), second = try await gate.begin(request)
        let a = try await store.beginPublicStateOperation(requestID: #require(UUID(uuidString: first.call.context.requestID)), using: access)
        let b = try await store.beginPublicStateOperation(requestID: #require(UUID(uuidString: second.call.context.requestID)), using: access)
        let firstHost = try SourcePublicStateHost(store: store, operation: a, policy: policy)
        let secondHost = try SourcePublicStateHost(store: store, operation: b, policy: policy)
        #expect(try await firstHost.read(.init(stateVersion: 1), gate: gate, ticket: first).revision == 0)
        let result = try await firstHost.write(.init(stateVersion: 1, expectedRevision: 0, entries: [.init(key: "category", value: "fiction")]), gate: gate, ticket: first)
        #expect(result.written && result.snapshot.revision == 1)
        #expect(try await !secondHost.write(.init(stateVersion: 1, expectedRevision: 0, entries: []), gate: gate, ticket: second).written)
        await #expect(throws: SourceHostFailure.wrongContext) { try await firstHost.read(.init(stateVersion: 1), gate: gate, ticket: second) }
        await #expect(throws: SourceMigrationFailure.versionMismatch) { try await secondHost.read(.init(stateVersion: 2), gate: gate, ticket: second) }
        _ = await gate.cancel(first)
        try await firstHost.revoke()
        await #expect(throws: SourceOperationGate.Failure.staleOperation) {
            try await firstHost.write(.init(stateVersion: 1, expectedRevision: 1, entries: []), gate: gate, ticket: first)
        }
        #expect(try await secondHost.write(.init(stateVersion: 1, expectedRevision: 1, entries: [.init(key: "category", value: "all")]), gate: gate, ticket: second).written)
        try await store.revokePublicStateAccess(access)
        try await gate.replace(scriptSHA256: digest, configurationRevision: 0, sessionRevision: 1, enabled: true)
        #expect(try await store.books().isEmpty)
        try await store.close()
    }
}
