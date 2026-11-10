import Foundation

/// Host-owned identity. Neither this storage key nor its value belongs in public
/// source state, library records, ordinary backups, or source-provided messages.
public struct StoredCredentialID: Hashable, Sendable {
    public let installationID: SourceInstallationID
    public let id: UUID

    public init(installationID: SourceInstallationID, id: UUID = UUID()) {
        self.installationID = installationID
        self.id = id
    }
}

/// Intentionally not Codable. Access to bytes is explicit; ordinary diagnostics
/// and reflection redact the value. This does not promise memory zeroization.
public struct CredentialSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: Data
    public init(bytes: Data) { value = bytes }
    public init(utf8: String) { value = Data(utf8.utf8) }
    public var bytes: Data { value }
    public var description: String { "[redacted]" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum CredentialStoreFailure: Error, Equatable, Sendable {
    case unavailable
    case invalidData
    case systemStatus(Int32)
}

/// App-injected, dedicated secret storage. Only trusted host code writes/deletes
/// records; a source receives temporary operation-scoped handles instead.
public protocol CredentialStore: Sendable {
    func read(_ id: StoredCredentialID) async throws -> CredentialSecret?
    func write(_ value: CredentialSecret, for id: StoredCredentialID) async throws
    func remove(_ id: StoredCredentialID) async throws
    func removeAll(for installationID: SourceInstallationID) async throws
}
