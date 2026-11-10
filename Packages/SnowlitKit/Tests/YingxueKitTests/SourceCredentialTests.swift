import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct SourceCredentialTests {
    private let digest = String(repeating: "a", count: 64)
    private let origin = YingxueWire.Origin(scheme: .https, host: "fixture.invalid")
    private var input: YingxueWire.OperationInput { .search(.init(kind: .search, input: .init(query: "book", cursor: nil))) }

    @Test func hostCanUseCredentialsWithoutPlaintextConsentOrDeclaration() async throws {
        for declared in [false, true] {
            let env = try environment(declared: declared, confirmed: false)
            let ticket = try await env.gate.begin(input)
            try await env.store.write(CredentialSecret(utf8: "synthetic-secret"), for: env.record)
            let handle = try await env.gate.issueCredential(env.record, origins: [origin], for: ticket)
            let value = try await env.gate.credentialForHost(handle, destination: URL(string: "https://fixture.invalid/login")!, for: ticket, store: env.store)
            #expect(value.bytes == Data("synthetic-secret".utf8))
            await #expect(throws: SourceCredentialFailure.permissionDenied) {
                try await env.gate.credentialForSource(handle, for: ticket, store: env.store)
            }
            #expect(await env.store.readCount == 1)
        }
    }

    @Test func plaintextRequiresBothDeclarationAndInstallationDigestConsent() async throws {
        let installation = SourceInstallationID()
        let consent = try SourceCredentialReadConsent(confirmedFor: installation, scriptSHA256: digest)
        let update = try SourceUpgradeAssessment(current: manifest(), candidate: manifest())
        #expect(!update.permissionsExpanded && update.credentialReadConsentRequired)
        #expect(throws: SourceCredentialFailure.invalidPolicy) {
            try SourceCredentialPolicy(installationID: installation, scriptSHA256: digest, manifest: manifest(declared: false), consent: consent)
        }
        #expect(throws: SourceCredentialFailure.invalidPolicy) {
            try SourceCredentialPolicy(installationID: SourceInstallationID(), scriptSHA256: digest, manifest: manifest(), consent: consent)
        }
        #expect(throws: SourceCredentialFailure.invalidPolicy) {
            try SourceCredentialPolicy(installationID: installation, scriptSHA256: String(repeating: "b", count: 64), manifest: manifest(), consent: consent)
        }
        let env = try environment()
        let ticket = try await env.gate.begin(input)
        try await env.store.write(CredentialSecret(utf8: "synthetic-secret"), for: env.record)
        let handle = try await env.gate.issueCredential(env.record, origins: [origin], for: ticket)
        let value = try await env.gate.credentialForSource(handle, for: ticket, store: env.store)
        #expect(value.value == "synthetic-secret")
        #expect(String(describing: value) == "[redacted]")
        #expect(String(reflecting: value) == "[redacted]")
        #expect(Mirror(reflecting: value).children.isEmpty)
        // Sensitive encoding is deliberate and is only sent to an authorized caller.
        #expect(try YingxueWireCodec.decode(YingxueWire.CredentialReadResult.self, from: YingxueWireCodec.encode(value)).value == "synthetic-secret")
        let secret = CredentialSecret(utf8: "synthetic-secret")
        #expect(String(reflecting: secret) == "[redacted]")
        #expect(Mirror(reflecting: secret).children.isEmpty)
    }

    @Test func handlesCannotCrossConsumersInstallationsOrCredentialAudiences() async throws {
        let env = try environment()
        let first = try await env.gate.begin(input), second = try await env.gate.begin(input)
        let handle = try await env.gate.issueCredential(env.record, origins: [origin], for: first)
        await #expect(throws: SourceCredentialFailure.invalidHandle) {
            try await env.gate.credentialForSource(handle, for: second, store: env.store)
        }
        await #expect(throws: SourceCredentialFailure.invalidPolicy) {
            try await env.gate.issueCredential(.init(installationID: SourceInstallationID()), origins: [origin], for: first)
        }
        await #expect(throws: SourceCredentialFailure.originDenied) {
            try await env.gate.issueCredential(env.record, origins: [.init(scheme: .https, host: "outside.invalid")], for: first)
        }
        for destination in ["http://fixture.invalid/", "https://sub.fixture.invalid/", "https://fixture.invalid:444/",
                            "https://user:password@fixture.invalid/", "https://login.invalid/"] {
            await #expect(throws: SourceCredentialFailure.originDenied) {
                try await env.gate.credentialForHost(handle, destination: URL(string: destination)!, for: first, store: env.store)
            }
        }
        // login.invalid is declared by the source, but not in this credential's audience.
        #expect(await env.store.readCount == 0)
        let foreign = try environment()
        let other = try await foreign.gate.begin(input)
        await #expect(throws: SourceCredentialFailure.invalidHandle) {
            try await foreign.gate.credentialForSource(handle, for: other, store: env.store)
        }
    }

    @Test func cancellationLogoutUpdateDisableCloseAndRevocationRejectReadInFlight() async throws {
        for action in ["cancel", "finish", "logout", "update", "disable", "close", "revoke", "taskCancel"] {
            let env = try environment(suspendReads: true)
            let ticket = try await env.gate.begin(input)
            try await env.store.write(CredentialSecret(utf8: "synthetic-secret"), for: env.record)
            let handle = try await env.gate.issueCredential(env.record, origins: [origin], for: ticket)
            let pending = Task { try await env.gate.credentialForSource(handle, for: ticket, store: env.store) }
            await env.store.waitForRead()
            switch action {
            case "cancel": _ = await env.gate.cancel(ticket)
            case "finish": try await env.gate.finish(ticket)
            case "logout": try await env.gate.replace(scriptSHA256: digest, configurationRevision: 0, sessionRevision: 1, enabled: true)
            case "update": try await env.gate.replace(scriptSHA256: String(repeating: "b", count: 64), configurationRevision: 0, sessionRevision: 0, enabled: true)
            case "disable": try await env.gate.replace(scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0, enabled: false)
            case "close": _ = await env.gate.close()
            case "revoke": #expect(await env.gate.revokeCredentialRead() == [ticket.call.context.requestID])
            case "taskCancel": pending.cancel()
            default: Issue.record("Unknown fixture action")
            }
            await env.store.resumeRead()
            await #expect(throws: (any Error).self, "Late secret was exposed after \(action)") { try await pending.value }
        }
    }

    @Test func hostSecretReadAlsoRejectsLogoutDuringStorageAwait() async throws {
        let env = try environment(confirmed: false, suspendReads: true)
        let ticket = try await env.gate.begin(input)
        try await env.store.write(CredentialSecret(utf8: "synthetic-secret"), for: env.record)
        let handle = try await env.gate.issueCredential(env.record, origins: [origin], for: ticket)
        let pending = Task { try await env.gate.credentialForHost(handle, destination: URL(string: "https://fixture.invalid/")!, for: ticket, store: env.store) }
        await env.store.waitForRead()
        try await env.gate.replace(scriptSHA256: digest, configurationRevision: 0, sessionRevision: 1, enabled: true)
        await env.store.resumeRead()
        await #expect(throws: SourceOperationGate.Failure.staleOperation) { try await pending.value }
    }

    @Test func revokedConfirmationCannotBeReplayedByReplacingTheSamePolicy() async throws {
        let env = try environment()
        _ = await env.gate.revokeCredentialRead()
        try await env.gate.replace(scriptSHA256: digest, configurationRevision: 0, sessionRevision: 1, enabled: true, credentialPolicy: env.policy)
        let ticket = try await env.gate.begin(input)
        let handle = try await env.gate.issueCredential(env.record, origins: [origin], for: ticket)
        await #expect(throws: SourceCredentialFailure.permissionDenied) {
            try await env.gate.credentialForSource(handle, for: ticket, store: env.store)
        }
        // A new native confirmation, not a source request, can authorize it again.
        let fresh = try SourceCredentialPolicy(installationID: env.installation, scriptSHA256: digest, manifest: manifest(),
            consent: .init(confirmedFor: env.installation, scriptSHA256: digest))
        try await env.gate.replace(scriptSHA256: digest, configurationRevision: 0, sessionRevision: 1, enabled: true, credentialPolicy: fresh)
        let next = try await env.gate.begin(input)
        let nextHandle = try await env.gate.issueCredential(env.record, origins: [origin], for: next)
        try await env.store.write(.init(utf8: "renewed"), for: env.record)
        #expect(try await env.gate.credentialForSource(nextHandle, for: next, store: env.store).value == "renewed")
    }

    @Test func scriptUpgradeDoesNotInheritConsentAndInvalidPolicyPreservesLiveTicket() async throws {
        let env = try environment()
        let before = try await env.gate.begin(input)
        let updatedDigest = String(repeating: "b", count: 64)
        await #expect(throws: SourceCredentialFailure.invalidPolicy) {
            try await env.gate.replace(scriptSHA256: updatedDigest, configurationRevision: 0, sessionRevision: 0, enabled: true, credentialPolicy: env.policy)
        }
        try await env.gate.check(before)
        let nextPolicy = try SourceCredentialPolicy(installationID: env.installation, scriptSHA256: updatedDigest, manifest: manifest())
        try await env.gate.replace(scriptSHA256: updatedDigest, configurationRevision: 0, sessionRevision: 0, enabled: true, credentialPolicy: nextPolicy)
        let after = try await env.gate.begin(input)
        let handle = try await env.gate.issueCredential(env.record, origins: [origin], for: after)
        await #expect(throws: SourceCredentialFailure.permissionDenied) { try await env.gate.credentialForSource(handle, for: after, store: env.store) }
        #expect(after.call.context.installationID == before.call.context.installationID)
    }

    @Test func missingMalformedAndFailingSecretsHaveCategorizedRedactedFailures() async throws {
        let env = try environment()
        let ticket = try await env.gate.begin(input)
        let handle = try await env.gate.issueCredential(env.record, origins: [origin], for: ticket)
        await #expect(throws: SourceCredentialFailure.missingCredential) { try await env.gate.credentialForSource(handle, for: ticket, store: env.store) }
        try await env.store.write(.init(bytes: Data([0xff])), for: env.record)
        await #expect(throws: SourceCredentialFailure.invalidUTF8) { try await env.gate.credentialForSource(handle, for: ticket, store: env.store) }
        await #expect(throws: SourceCredentialFailure.storeUnavailable) { try await env.gate.credentialForSource(handle, for: ticket, store: FailedCredentialStore()) }
    }

    private func manifest(declared: Bool = true) -> YingxueWire.Manifest {
        .init(protocolVersion: 1, sourceID: "org.example.reader", name: "Fixture", scriptVersion: "1", referenceVersion: 1,
              stateVersion: 1, capabilities: declared ? [.http, .credentialsRead] : [.http],
              origins: [origin, .init(scheme: .https, host: "login.invalid")], authentication: [], publicConfiguration: [])
    }

    private func environment(declared: Bool = true, confirmed: Bool = true, suspendReads: Bool = false) throws -> CredentialEnvironment {
        let installation = SourceInstallationID()
        let consent = try confirmed ? SourceCredentialReadConsent(confirmedFor: installation, scriptSHA256: digest) : nil
        let policy = try SourceCredentialPolicy(installationID: installation, scriptSHA256: digest, manifest: manifest(declared: declared), consent: consent)
        return try .init(installation: installation, record: .init(installationID: installation), policy: policy,
            gate: .init(installationID: installation, scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0, credentialPolicy: policy),
            store: MemoryCredentialStore(suspendReads: suspendReads))
    }
}

private struct CredentialEnvironment {
    let installation: SourceInstallationID
    let record: StoredCredentialID
    let policy: SourceCredentialPolicy
    let gate: SourceOperationGate
    let store: MemoryCredentialStore
}

private actor MemoryCredentialStore: CredentialStore {
    private var values: [StoredCredentialID: CredentialSecret] = [:]
    private let suspendReads: Bool
    private var pending: CheckedContinuation<CredentialSecret?, Never>?
    private var captured: CredentialSecret?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var readCount = 0
    init(suspendReads: Bool) { self.suspendReads = suspendReads }
    func read(_ id: StoredCredentialID) async -> CredentialSecret? {
        readCount += 1
        if !suspendReads { return values[id] }
        captured = values[id]
        return await withCheckedContinuation { continuation in
            pending = continuation
            for waiter in waiting { waiter.resume() }
            waiting.removeAll()
        }
    }
    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func resumeRead() { pending?.resume(returning: captured); pending = nil; captured = nil }
    func write(_ value: CredentialSecret, for id: StoredCredentialID) { values[id] = value }
    func remove(_ id: StoredCredentialID) { values.removeValue(forKey: id) }
    func removeAll(for installationID: SourceInstallationID) { values = values.filter { $0.key.installationID != installationID } }
}

private struct FailedCredentialStore: CredentialStore {
    struct PrivateFailure: Error { let secret = "synthetic-secret" }
    func read(_ id: StoredCredentialID) async throws -> CredentialSecret? { throw PrivateFailure() }
    func write(_ value: CredentialSecret, for id: StoredCredentialID) async throws { throw PrivateFailure() }
    func remove(_ id: StoredCredentialID) async throws { throw PrivateFailure() }
    func removeAll(for installationID: SourceInstallationID) async throws { throw PrivateFailure() }
}
