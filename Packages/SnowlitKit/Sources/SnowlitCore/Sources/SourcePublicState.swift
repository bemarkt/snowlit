import Foundation

public enum SourcePublicStateFailure: Error, Equatable, Sendable {
    case invalidVersion, invalidRevision, invalidEntry, duplicateKey, staleAccess, revisionExhausted
}

/// Backup-eligible source data only. Login data belongs in CredentialStore and
/// the website session. Sources serialize their own structured public values.
public struct SourcePublicStateEntry: Codable, Equatable, Sendable {
    public let key: String
    public let value: String
    public init(key: String, value: String) throws {
        guard !key.isEmpty, !key.utf8.contains(0) else { throw SourcePublicStateFailure.invalidEntry }
        self.key = key; self.value = value
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }
    private enum CodingKeys: CodingKey { case key, value }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(key: values.decode(String.self, forKey: .key), value: values.decode(String.self, forKey: .value))
    }
}

public struct SourcePublicState: Codable, Equatable, Sendable {
    public let stateVersion: Int
    public let revision: Int
    public let entries: [SourcePublicStateEntry]
    public init(stateVersion: Int, revision: Int, entries: [SourcePublicStateEntry]) throws {
        guard (1...9_007_199_254_740_991).contains(stateVersion) else { throw SourcePublicStateFailure.invalidVersion }
        guard (0...9_007_199_254_740_991).contains(revision) else { throw SourcePublicStateFailure.invalidRevision }
        guard Set(entries.map { Data($0.key.utf8) }).count == entries.count else { throw SourcePublicStateFailure.duplicateKey }
        self.stateVersion = stateVersion; self.revision = revision; self.entries = entries
    }
    private enum CodingKeys: CodingKey { case stateVersion, revision, entries }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(stateVersion: values.decode(Int.self, forKey: .stateVersion), revision: values.decode(Int.self, forKey: .revision),
                      entries: values.decode([SourcePublicStateEntry].self, forKey: .entries))
    }
}

/// Native authorization for SQL writes, distinct from a script's operation ID.
/// Rotate/revoke when the installed script or session becomes invalid. A gate
/// check followed by an asynchronous DB call is not an atomic write guard.
public struct SourcePublicStateAccess: Equatable, Sendable {
    public let installationID: SourceInstallationID
    public let stateVersion: Int
    public let id: UUID
    public init(installationID: SourceInstallationID, stateVersion: Int, id: UUID = UUID()) throws {
        guard (1...9_007_199_254_740_991).contains(stateVersion) else { throw SourcePublicStateFailure.invalidVersion }
        self.installationID = installationID; self.stateVersion = stateVersion; self.id = id
    }
}

public struct SourcePublicStateWrite: Sendable {
    public let written: Bool
    public let snapshot: SourcePublicState
    public init(written: Bool, snapshot: SourcePublicState) { self.written = written; self.snapshot = snapshot }
}

/// One source operation's write permission. Cancelling it does not invalidate
/// another operation in the same installation session.
public struct SourcePublicStateOperation: Equatable, Sendable {
    public let access: SourcePublicStateAccess
    public let requestID: UUID
    public init(access: SourcePublicStateAccess, requestID: UUID) {
        self.access = access; self.requestID = requestID
    }
}

public protocol SourcePublicStateStore: Sendable {
    func beginPublicStateAccess(installationID: SourceInstallationID, stateVersion: Int) async throws -> SourcePublicStateAccess
    func revokePublicStateAccess(_ access: SourcePublicStateAccess) async throws
    func beginPublicStateOperation(requestID: UUID, using access: SourcePublicStateAccess) async throws -> SourcePublicStateOperation
    func revokePublicStateOperation(_ operation: SourcePublicStateOperation) async throws
    func readPublicState(using access: SourcePublicStateAccess) async throws -> SourcePublicState
    func writePublicState(_ entries: [SourcePublicStateEntry], expectedRevision: Int, using operation: SourcePublicStateOperation) async throws -> SourcePublicStateWrite
}
