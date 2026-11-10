import Foundation
import SnowlitCore

/// The composition owner supplies a DB access token for the active source and
/// revokes it when rotating the runtime. Candidate migrations receive snapshots,
/// not a live token that can replace the currently active version's state.
public struct SourcePublicStateHost: Sendable {
    private let store: any SourcePublicStateStore
    private let access: SourcePublicStateAccess
    private let operation: SourcePublicStateOperation
    private let policy: SourceHostPolicy

    public init(store: any SourcePublicStateStore, operation: SourcePublicStateOperation, policy: SourceHostPolicy) throws {
        let access = operation.access
        guard access.installationID == policy.installationID, access.stateVersion == policy.manifest.stateVersion,
              policy.manifest.capabilities.contains(.publicState) else { throw SourceHostFailure.wrongContext }
        self.store = store; self.access = access; self.policy = policy
        self.operation = operation
    }

    public func read(_ request: YingxueWire.ReadPublicState, gate: SourceOperationGate,
                     ticket: SourceOperationGate.Ticket) async throws -> YingxueWire.PublicStateSnapshot {
        _ = try YingxueWireCodec.encode(request)
        try policy.check(ticket.call.context, capability: .publicState)
        guard ticket.call.context.requestID == operation.requestID.uuidString.lowercased() else { throw SourceHostFailure.wrongContext }
        guard request.stateVersion == access.stateVersion else { throw SourceMigrationFailure.versionMismatch }
        try await gate.check(ticket)
        let snapshot = try await store.readPublicState(using: access)
        try await gate.check(ticket)
        return SourcePublicStateAdapter.encode(snapshot)
    }

    public func write(_ request: YingxueWire.WritePublicState, gate: SourceOperationGate,
                      ticket: SourceOperationGate.Ticket) async throws -> YingxueWire.PublicStateWriteResult {
        _ = try YingxueWireCodec.encode(request)
        try policy.check(ticket.call.context, capability: .publicState)
        guard ticket.call.context.requestID == operation.requestID.uuidString.lowercased() else { throw SourceHostFailure.wrongContext }
        guard request.stateVersion == access.stateVersion else { throw SourceMigrationFailure.versionMismatch }
        try await gate.check(ticket)
        let entries = try request.entries.map { try SourcePublicStateEntry(key: $0.key, value: $0.value) }
        let result = try await store.writePublicState(entries, expectedRevision: request.expectedRevision, using: operation)
        try await gate.check(ticket)
        return .init(written: result.written, snapshot: SourcePublicStateAdapter.encode(result.snapshot))
    }

    /// Await on operation cancellation/finish; other operations remain usable.
    /// Logout/update additionally revokes the installation access token in storage.
    public func revoke() async throws { try await store.revokePublicStateOperation(operation) }
}
