import Foundation
import SnowlitCore

/// Owns a copy of the file before the trusted AST invocation. Inspect `source`
/// from this value, then accept that invocation's report on the same value.
/// The author script itself is never evaluated to produce a preview.
public struct SourceImportPreview: Sendable {
    public let header: SourceFileHeader
    private let bytes: Data

    public init(bytes: Data) throws {
        header = try SourceFileHeader(bytes: bytes)
        self.bytes = bytes
    }

    public func acceptInspection(_ trustedReport: Data, upgrade: SourceUpgradeAssessment? = nil,
                                 digest: SourceScriptSnapshot.Digest) throws -> SourceScriptSnapshot {
        _ = try SourceModuleInspection.accept(trustedReport, manifest: header.manifest, upgrade: upgrade)
        let manifest = header.manifest
        let metadata = try SourceScriptMetadata(sourceID: manifest.sourceID, name: manifest.name,
            scriptVersion: manifest.scriptVersion, protocolVersion: manifest.protocolVersion,
            referenceVersion: manifest.referenceVersion, stateVersion: manifest.stateVersion)
        return try SourceScriptSnapshot(bytes: bytes, metadata: metadata, digest: digest)
    }
}
