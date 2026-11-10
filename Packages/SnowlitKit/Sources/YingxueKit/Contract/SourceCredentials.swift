import Foundation
import SnowlitCore

public enum SourceCredentialFailure: Error, Equatable, Sendable {
    case invalidPolicy, permissionDenied, invalidHandle, originDenied, missingCredential, storeUnavailable, invalidUTF8
}

/// Created by the trusted install/upgrade UI after explicit confirmation. There
/// is no wire decoder or script-facing method that can create user consent.
public struct SourceCredentialReadConsent: Sendable {
    public let installationID: SourceInstallationID
    public let scriptSHA256: String
    let confirmationID = UUID()

    public init(confirmedFor installationID: SourceInstallationID, scriptSHA256: String) throws {
        try YingxueWireCodec.validate(JSONEncoder().encode(scriptSHA256), as: "SHA256")
        self.installationID = installationID
        self.scriptSHA256 = scriptSHA256
    }
}

public struct SourceCredentialPolicy: Sendable {
    let installationID: SourceInstallationID
    let scriptSHA256: String
    let origins: Set<String>
    let consentID: UUID?

    public init(installationID: SourceInstallationID, scriptSHA256: String, manifest: YingxueWire.Manifest,
                consent: SourceCredentialReadConsent? = nil) throws {
        try SourceFileHeader.validate(manifest)
        try YingxueWireCodec.validate(JSONEncoder().encode(scriptSHA256), as: "SHA256")
        if let consent {
            guard consent.installationID == installationID, consent.scriptSHA256 == scriptSHA256,
                  manifest.capabilities.contains(.credentialsRead) else { throw SourceCredentialFailure.invalidPolicy }
        }
        self.installationID = installationID
        self.scriptSHA256 = scriptSHA256
        origins = Set(manifest.origins.map(SourceFileHeader.originKey))
        consentID = consent?.confirmationID
    }
}

struct SourceCredentialLease: Sendable {
    let requestID: String
    let record: StoredCredentialID
    let origins: Set<String>
}

extension SourceOperationGate {
    /// Called only by the host after a native credential form or trusted secret
    /// capture. The source cannot submit a storage key or invent its audience.
    public func issueCredential(_ record: StoredCredentialID, origins: [YingxueWire.Origin],
                                for ticket: Ticket) throws -> YingxueWire.CredentialHandle {
        try check(ticket)
        guard let policy = credentialPolicy, record.installationID == policy.installationID else {
            throw SourceCredentialFailure.invalidPolicy
        }
        var audience = Set<String>()
        for origin in origins {
            _ = try YingxueWireCodec.encode(origin)
            audience.insert(SourceFileHeader.originKey(origin))
        }
        guard !audience.isEmpty, audience.isSubset(of: policy.origins) else { throw SourceCredentialFailure.originDenied }
        let id = UUID()
        credentialHandles[id] = .init(requestID: ticket.call.context.requestID, record: record, origins: audience)
        return .init(id: id.uuidString.lowercased())
    }

    /// Native transport only. Re-resolve/check on every redirect before sending;
    /// never encode this result into a JavaScript callback or public state.
    public func credentialForHost(_ handle: YingxueWire.CredentialHandle, destination: URL,
                                  for ticket: Ticket, store: any CredentialStore) async throws -> CredentialSecret {
        let lease = try credentialLease(handle, for: ticket)
        guard let origin = SourceOrigin.key(for: destination), lease.origins.contains(origin),
              credentialPolicy?.origins.contains(origin) == true else { throw SourceCredentialFailure.originDenied }
        let value = try await loadCredential(handle, for: ticket, store: store, plaintext: false)
        try check(ticket)
        return value
    }

    /// This is the only dedicated credential-store result the source may read.
    /// A declaration alone does not grant it; permission is checked after the
    /// storage await as well, under the same actor as operation invalidation.
    public func credentialForSource(_ handle: YingxueWire.CredentialHandle,
                                    for ticket: Ticket, store: any CredentialStore) async throws -> YingxueWire.CredentialReadResult {
        let secret = try await loadCredential(handle, for: ticket, store: store, plaintext: true)
        try check(ticket)
        guard let value = String(data: secret.bytes, encoding: .utf8) else { throw SourceCredentialFailure.invalidUTF8 }
        return .init(value: value)
    }

    /// Revocation also cancels operations that may already hold plaintext. The
    /// owner must close their backend/network/UI resources using these IDs.
    @discardableResult
    public func revokeCredentialRead() -> [String] {
        if let id = credentialPolicy?.consentID { revokedCredentialConsents.insert(id) }
        return invalidate()
    }

    func discardCredentials(for requestID: String) {
        credentialHandles = credentialHandles.filter { $0.value.requestID != requestID }
    }

    func credentialLease(_ handle: YingxueWire.CredentialHandle, for ticket: Ticket) throws -> SourceCredentialLease {
        try check(ticket)
        _ = try YingxueWireCodec.encode(handle)
        guard let id = UUID(uuidString: handle.id), let lease = credentialHandles[id],
              lease.requestID == ticket.call.context.requestID else { throw SourceCredentialFailure.invalidHandle }
        return lease
    }

    private func loadCredential(_ handle: YingxueWire.CredentialHandle, for ticket: Ticket,
                                store: any CredentialStore, plaintext: Bool) async throws -> CredentialSecret {
        let lease = try credentialLease(handle, for: ticket)
        if plaintext { try checkPlaintextPermission() }
        let value: CredentialSecret?
        do { value = try await store.read(lease.record) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try check(ticket)
            // Storage implementations must not leak arbitrary error payloads.
            throw SourceCredentialFailure.storeUnavailable
        }
        _ = try credentialLease(handle, for: ticket)
        if plaintext { try checkPlaintextPermission() }
        guard let value else { throw SourceCredentialFailure.missingCredential }
        return value
    }

    private func checkPlaintextPermission() throws {
        guard let id = credentialPolicy?.consentID, !revokedCredentialConsents.contains(id) else {
            throw SourceCredentialFailure.permissionDenied
        }
    }

}
