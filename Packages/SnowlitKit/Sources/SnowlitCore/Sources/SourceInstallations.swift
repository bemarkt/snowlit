import Foundation

public enum SourceInstallationFailure: Error, Equatable, Sendable {
    case missingImport, missingInstallation, alreadyInstalled, restorationRequired
    case staleInstallation, differentSource, migrationRequired, alreadyCurrent
    case cleanupPending, invalidState, invalidConfiguration, revisionExhausted
}

/// Public user settings only. The manifest adapter validates allowed keys,
/// choices and defaults before passing these native values to storage.
public enum SourceSettingValue: Codable, Equatable, Sendable {
    case text(key: String, value: String)
    case boolean(key: String, value: Bool)

    public var key: String {
        switch self { case .text(let key, _), .boolean(let key, _): key }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.text(let left, let a), .text(let right, let b)):
            left.utf8.elementsEqual(right.utf8) && a.utf8.elementsEqual(b.utf8)
        case (.boolean(let left, let a), .boolean(let right, let b)):
            left.utf8.elementsEqual(right.utf8) && a == b
        default: false
        }
    }

    public static func validate(_ values: [Self]) throws {
        guard values.allSatisfy({ !$0.key.isEmpty && !$0.key.utf8.contains(0) }),
              Set(values.map { Data($0.key.utf8) }).count == values.count else {
            throw SourceInstallationFailure.invalidConfiguration
        }
    }
}

/// Website data and Keychain cleanup are external effects. The App acknowledges
/// this token only after both have completed; retries must use the same token.
public struct SourceSessionCleanup: Codable, Equatable, Sendable {
    public let id: UUID
    public let websiteSessionID: UUID
    public init(id: UUID = UUID(), websiteSessionID: UUID) {
        self.id = id; self.websiteSessionID = websiteSessionID
    }
}

public enum SourceCredentialReadConsent: Sendable {
    case managedOnly
    /// Supplied by the native confirmation flow for this exact candidate.
    /// The runtime still requires the manifest's credentials.read declaration.
    case approvedForCandidate
}

public struct SourceInstallationSnapshot: Equatable, Sendable {
    public enum State: String, Codable, Sendable { case enabled, disabled, removed }
    public let id: SourceInstallationID
    public let importID: UUID
    public let scriptSHA256: String
    public let metadata: SourceScriptMetadata
    public let revision: Int
    public let state: State
    public let configuration: [SourceSettingValue]
    /// Bound to this installation and scriptSHA256, never inherited by an update.
    public let allowsCredentialRead: Bool
    public let websiteSessionID: UUID
    public let pendingCleanup: SourceSessionCleanup?
    public var canExecute: Bool { state == .enabled && pendingCleanup == nil }

    public init(id: SourceInstallationID, importID: UUID, scriptSHA256: String,
                metadata: SourceScriptMetadata, revision: Int, state: State,
                configuration: [SourceSettingValue], allowsCredentialRead: Bool,
                websiteSessionID: UUID, pendingCleanup: SourceSessionCleanup?) throws {
        try SourceScriptSnapshot.validateDigest(scriptSHA256)
        try SourceSettingValue.validate(configuration)
        guard (1...9_007_199_254_740_991).contains(revision),
              state != .removed || !allowsCredentialRead,
              pendingCleanup?.websiteSessionID != websiteSessionID else {
            throw SourceInstallationFailure.invalidState
        }
        self.id = id; self.importID = importID; self.scriptSHA256 = scriptSHA256; self.metadata = metadata
        self.revision = revision; self.state = state; self.configuration = configuration
        self.allowsCredentialRead = allowsCredentialRead; self.websiteSessionID = websiteSessionID
        self.pendingCleanup = pendingCleanup
    }
}

/// Native management transaction boundary. The caller inspects and validates
/// the candidate before adoption. Storing a receipt does not activate it.
public protocol SourceInstallationStore: Sendable {
    func sourceInstallations() async throws -> [SourceInstallationSnapshot]
    /// Read-only preparation; candidate scripts receive adapted values, never
    /// these host-owned IDs or a live database access token.
    func captureSourceUpdate(importID: UUID, expected: SourceInstallationSnapshot) async throws -> SourceUpdateSnapshot
    /// Adopts a prepared state migration while reference semantics are unchanged.
    /// The migrated value is validated by the source adapter; nil means no change.
    func updateSource(prepared: SourceUpdateSnapshot, migratedState: SourcePublicState?,
                      configuration: [SourceSettingValue], consent: SourceCredentialReadConsent) async throws -> SourceInstallationSnapshot
    func restoreSource(confirmed prepared: SourceUpdateSnapshot, migratedState: SourcePublicState?,
                       configuration: [SourceSettingValue], consent: SourceCredentialReadConsent) async throws -> SourceInstallationSnapshot
    func installSource(importID: UUID, id: SourceInstallationID, configuration: [SourceSettingValue],
                       consent: SourceCredentialReadConsent) async throws -> SourceInstallationSnapshot
    /// Version changes require a complete migration transaction, not this path.
    func updateSource(importID: UUID, replacing expected: SourceInstallationSnapshot,
                      configuration: [SourceSettingValue], consent: SourceCredentialReadConsent) async throws -> SourceInstallationSnapshot
    /// Separate entry point: reimporting alone never reconnects retained books.
    func restoreSource(importID: UUID, confirmed expected: SourceInstallationSnapshot,
                       configuration: [SourceSettingValue], consent: SourceCredentialReadConsent) async throws -> SourceInstallationSnapshot
    func setSourceEnabled(_ enabled: Bool, expected: SourceInstallationSnapshot) async throws -> SourceInstallationSnapshot
    func configureSource(_ values: [SourceSettingValue], expected: SourceInstallationSnapshot) async throws -> SourceInstallationSnapshot
    func removeSource(expected: SourceInstallationSnapshot) async throws -> SourceInstallationSnapshot
    func signOutSource(expected: SourceInstallationSnapshot) async throws -> SourceInstallationSnapshot
    func finishSourceSessionCleanup(_ cleanup: SourceSessionCleanup, installationID: SourceInstallationID) async throws -> Bool
    func beginInstalledPublicStateAccess(expected: SourceInstallationSnapshot) async throws -> SourcePublicStateAccess
}
