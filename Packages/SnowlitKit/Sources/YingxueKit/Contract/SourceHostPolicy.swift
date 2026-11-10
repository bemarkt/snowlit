import Foundation
import SnowlitCore

public enum SourceHostFailure: Error, Equatable, Sendable {
    case wrongContext, undeclaredCapability, invalidURL, originDenied, invalidHeader, invalidBody
    case invalidEncoding, invalidSelector, duplicateKey, invalidInteraction, missingInteraction, mismatchedInteraction
    case invalidRedirect, redirectLoop, redirectLimit
    case duplicateHostCall, staleHostCall
}

/// Trusted installation metadata, never reconstructed from a script's host call.
public struct SourceHostPolicy: Sendable {
    let installationID: SourceInstallationID
    let scriptSHA256: String
    let manifest: YingxueWire.Manifest
    let origins: Set<String>

    public init(installationID: SourceInstallationID, scriptSHA256: String, manifest: YingxueWire.Manifest) throws {
        try SourceFileHeader.validate(manifest)
        try YingxueWireCodec.validate(JSONEncoder().encode(scriptSHA256), as: "SHA256")
        self.installationID = installationID; self.scriptSHA256 = scriptSHA256
        self.manifest = manifest; origins = Set(manifest.origins.map(SourceFileHeader.originKey))
    }

    public func check(_ context: YingxueWire.OperationContext, capability: YingxueWire.Capability? = nil) throws {
        guard context.installationID == installationID.rawValue.uuidString.lowercased(), context.scriptSHA256 == scriptSHA256 else {
            throw SourceHostFailure.wrongContext
        }
        if let capability, !manifest.capabilities.contains(capability) { throw SourceHostFailure.undeclaredCapability }
    }

    public func resolve(_ reference: YingxueWire.URLReference) throws -> URL {
        _ = try YingxueWireCodec.encode(reference)
        guard Self.cleanURLText(reference.url) else { throw SourceHostFailure.invalidURL }
        var base: URL?
        if let text = reference.baseURL {
            guard Self.cleanURLText(text), let url = URL(string: text), SourceOrigin.key(for: url) != nil else {
                throw SourceHostFailure.invalidURL
            }
            base = url
        }
        guard let url = URL(string: reference.url, relativeTo: base)?.absoluteURL,
              let origin = SourceOrigin.key(for: url) else { throw SourceHostFailure.invalidURL }
        guard origins.contains(origin) else { throw SourceHostFailure.originDenied }
        return url
    }

    private static func cleanURLText(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 || $0.value == 92 }
    }
}

enum SourceOrigin {
    static func key(for url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.percentEncodedHost?.contains("%") == false else { return nil }
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        return "\(scheme)://\(host):\(port)"
    }
}
