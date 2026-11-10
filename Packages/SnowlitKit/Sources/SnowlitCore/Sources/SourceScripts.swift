import Foundation

public enum SourceScriptFailure: Error, Equatable, Sendable {
    case invalidMetadata, invalidDigest, invalidBytes, invalidImport
    case digestMismatch, conflictingScript
}

/// Native display and identity metadata, extracted by the source inspector.
/// This is not the source wire manifest or an authorization to execute a script.
public struct SourceScriptMetadata: Codable, Equatable, Sendable {
    public let sourceID: String
    public let name: String
    public let scriptVersion: String
    public let protocolVersion: Int
    public let referenceVersion: Int
    public let stateVersion: Int

    public init(sourceID: String, name: String, scriptVersion: String,
                protocolVersion: Int, referenceVersion: Int, stateVersion: Int) throws {
        guard [sourceID, name, scriptVersion].allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }),
              [protocolVersion, referenceVersion, stateVersion].allSatisfy({ $0 > 0 && $0 <= 9_007_199_254_740_991 }) else {
            throw SourceScriptFailure.invalidMetadata
        }
        self.sourceID = sourceID; self.name = name; self.scriptVersion = scriptVersion
        self.protocolVersion = protocolVersion; self.referenceVersion = referenceVersion; self.stateVersion = stateVersion
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceID.utf8.elementsEqual(rhs.sourceID.utf8)
            && lhs.name.utf8.elementsEqual(rhs.name.utf8)
            && lhs.scriptVersion.utf8.elementsEqual(rhs.scriptVersion.utf8)
            && lhs.protocolVersion == rhs.protocolVersion
            && lhs.referenceVersion == rhs.referenceVersion && lhs.stateVersion == rhs.stateVersion
    }

    private enum CodingKeys: CodingKey { case sourceID, name, scriptVersion, protocolVersion, referenceVersion, stateVersion }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sourceID: values.decode(String.self, forKey: .sourceID),
                      name: values.decode(String.self, forKey: .name),
                      scriptVersion: values.decode(String.self, forKey: .scriptVersion),
                      protocolVersion: values.decode(Int.self, forKey: .protocolVersion),
                      referenceVersion: values.decode(Int.self, forKey: .referenceVersion),
                      stateVersion: values.decode(Int.self, forKey: .stateVersion))
    }
}

/// Original bytes include the BOM, header and original line endings. Hashing is
/// injected at the system boundary (SHA-256); no decode path bypasses verification.
public struct SourceScriptSnapshot: Equatable, Sendable {
    public typealias Digest = @Sendable (Data) throws -> String
    public let bytes: Data
    public let sha256: String
    public let metadata: SourceScriptMetadata

    public init(bytes: Data, metadata: SourceScriptMetadata, digest: Digest) throws {
        guard !bytes.isEmpty, String(data: bytes, encoding: .utf8) != nil else { throw SourceScriptFailure.invalidBytes }
        let sha256 = try digest(bytes)
        try Self.validateDigest(sha256)
        self.bytes = bytes; self.sha256 = sha256; self.metadata = metadata
    }

    public static func validateDigest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SourceScriptFailure.invalidDigest
        }
    }
}

/// A separate receipt for each inspected import. A receipt is a candidate only:
/// it has no active installation, credential grant or restored book association.
public struct SourceImportRecord: Equatable, Sendable {
    public let id: UUID
    public let scriptSHA256: String
    public let inspectionContractSHA256: String
    public let fileName: String
    public let importedAt: Date

    public init(id: UUID = UUID(), scriptSHA256: String, inspectionContractSHA256: String,
                fileName: String, importedAt: Date) throws {
        try SourceScriptSnapshot.validateDigest(scriptSHA256)
        try SourceScriptSnapshot.validateDigest(inspectionContractSHA256)
        guard !fileName.isEmpty, !fileName.utf8.contains(0),
              !fileName.contains("/"), !fileName.contains("\\"),
              importedAt.timeIntervalSince1970.isFinite else { throw SourceScriptFailure.invalidImport }
        self.id = id; self.scriptSHA256 = scriptSHA256; self.inspectionContractSHA256 = inspectionContractSHA256
        self.fileName = fileName; self.importedAt = importedAt
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.scriptSHA256 == rhs.scriptSHA256
            && lhs.inspectionContractSHA256 == rhs.inspectionContractSHA256
            && lhs.fileName.utf8.elementsEqual(rhs.fileName.utf8) && lhs.importedAt == rhs.importedAt
    }
}

public protocol SourceScriptStore: Sendable {
    /// Both immutable bytes and the import receipt commit together.
    func stageSourceScript(_ script: SourceScriptSnapshot, receipt: SourceImportRecord) async throws
    func sourceScript(sha256: String, digest: SourceScriptSnapshot.Digest) async throws -> SourceScriptSnapshot?
    func sourceImports() async throws -> [SourceImportRecord]
}
