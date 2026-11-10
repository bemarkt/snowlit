import Foundation
import SnowlitCore

public enum SourceCandidateFailure: Error, Equatable, Sendable { case closed, wrongInstallation, wrongStateVersion }

/// Disposable validation state, never a live library access token. Temporary
/// credentials remain in memory and disappear if candidate validation crashes.
/// Only explicit migration return values may later be adopted by Storage.
public actor SourceCandidateWorkspace: CredentialStore {
    private let installationID: SourceInstallationID
    private var state: SourcePublicState
    private var credentials: [StoredCredentialID: CredentialSecret] = [:]
    private var closed = false

    public init(installationID: SourceInstallationID, state: SourcePublicState) {
        self.installationID = installationID; self.state = state
    }

    public func readState(_ request: YingxueWire.ReadPublicState) throws -> YingxueWire.PublicStateSnapshot {
        try checkOpen()
        _ = try YingxueWireCodec.encode(request)
        guard request.stateVersion == state.stateVersion else { throw SourceCandidateFailure.wrongStateVersion }
        return SourcePublicStateAdapter.encode(state)
    }

    public func writeState(_ request: YingxueWire.WritePublicState) throws -> YingxueWire.PublicStateWriteResult {
        try checkOpen()
        _ = try YingxueWireCodec.encode(request)
        guard request.stateVersion == state.stateVersion else { throw SourceCandidateFailure.wrongStateVersion }
        let entries = try request.entries.map { try SourcePublicStateEntry(key: $0.key, value: $0.value) }
        // Validate the proposed snapshot even when CAS is stale. Malformed
        // input must not be mistaken for a normal concurrent update.
        let proposed = try SourcePublicState(stateVersion: state.stateVersion, revision: state.revision, entries: entries)
        guard request.expectedRevision == state.revision else {
            return .init(written: false, snapshot: SourcePublicStateAdapter.encode(state))
        }
        guard state.revision < 9_007_199_254_740_991 else { throw SourcePublicStateFailure.revisionExhausted }
        state = try .init(stateVersion: state.stateVersion, revision: state.revision + 1, entries: proposed.entries)
        return .init(written: true, snapshot: SourcePublicStateAdapter.encode(state))
    }

    public func read(_ id: StoredCredentialID) throws -> CredentialSecret? {
        try checkOpen(); try check(id.installationID)
        return credentials[id]
    }

    public func write(_ value: CredentialSecret, for id: StoredCredentialID) throws {
        try checkOpen(); try check(id.installationID)
        credentials[id] = value
    }

    public func remove(_ id: StoredCredentialID) throws {
        try check(id.installationID)
        credentials.removeValue(forKey: id)
    }

    public func removeAll(for installationID: SourceInstallationID) throws {
        try check(installationID)
        credentials.removeAll()
    }

    public func close() { closed = true; credentials.removeAll() }

    private func check(_ installationID: SourceInstallationID) throws {
        guard installationID == self.installationID else { throw SourceCandidateFailure.wrongInstallation }
    }
    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw SourceCandidateFailure.closed }
    }
}
