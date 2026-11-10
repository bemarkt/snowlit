import Foundation

/// Reads metadata as data. A successful header inspection is not JS syntax,
/// module-import, capability, or host-execution acceptance.
public struct SourceFileHeader: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case invalidUTF8, missingHeader, unclosedHeader, missingModule
        case duplicateOrigin, duplicateSetting, invalidChoice, missingOrigins, differentSource
    }

    public let manifest: YingxueWire.Manifest
    /// The original complete file, including its comment header, for module analysis.
    public let source: String

    public init(bytes: Data) throws {
        guard let decoded = String(data: bytes, encoding: .utf8) else { throw Failure.invalidUTF8 }
        let source = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        let prefix: String
        if source.hasPrefix("/* @yingxue\r\n") { prefix = "/* @yingxue\r\n" }
        else if source.hasPrefix("/* @yingxue\n") { prefix = "/* @yingxue\n" }
        else { throw Failure.missingHeader }
        let start = source.index(source.startIndex, offsetBy: prefix.count)
        guard let end = source.range(of: "*/", range: start..<source.endIndex) else { throw Failure.unclosedHeader }
        guard !source[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.missingModule }
        let manifest = try YingxueWireCodec.decode(YingxueWire.Manifest.self, from: Data(source[start..<end.lowerBound].utf8))
        try Self.validate(manifest)
        self.manifest = manifest
        self.source = decoded
    }

    public static func validate(_ manifest: YingxueWire.Manifest) throws {
        // Validate values constructed directly in Swift as well as decoded headers.
        _ = try YingxueWireCodec.encode(manifest)
        let origins = manifest.origins.map(originKey)
        guard Set(origins).count == origins.count else { throw Failure.duplicateOrigin }
        if manifest.capabilities.contains(.http) || manifest.capabilities.contains(.browser) || !manifest.authentication.isEmpty {
            guard !origins.isEmpty else { throw Failure.missingOrigins }
        }
        var keys = Set<Data>()
        for setting in manifest.publicConfiguration {
            let key: String
            switch setting {
            case .text(let value): key = value.key
            case .boolean(let value): key = value.key
            case .choice(let value):
                key = value.key
                let choices = value.choices.map { Data($0.value.utf8) }
                guard !choices.isEmpty, Set(choices).count == choices.count,
                      choices.contains(Data(value.initial.utf8)) else { throw Failure.invalidChoice }
            }
            guard keys.insert(Data(key.utf8)).inserted else { throw Failure.duplicateSetting }
        }
    }

    static func originKey(_ origin: YingxueWire.Origin) -> String {
        "\(origin.scheme.rawValue)://\(origin.host):\(origin.port ?? (origin.scheme == .https ? 443 : 80))"
    }
}

/// A review result, never an instruction to activate an unchecked script or erase state.
/// The installation ID and local book/reading identities remain owned by the host.
public struct SourceUpgradeAssessment: Equatable, Sendable {
    public let referenceMigrationRequired: Bool
    public let publicStateMigrationRequired: Bool
    public let addedOrigins: [String]
    public let addedCapabilities: [YingxueWire.Capability]
    public let addedAuthentication: [YingxueWire.Authentication]
    public var permissionsExpanded: Bool {
        !addedOrigins.isEmpty || !addedCapabilities.isEmpty || !addedAuthentication.isEmpty
    }

    public init(current: YingxueWire.Manifest, candidate: YingxueWire.Manifest) throws {
        try SourceFileHeader.validate(current)
        try SourceFileHeader.validate(candidate)
        guard current.sourceID.utf8.elementsEqual(candidate.sourceID.utf8) else { throw SourceFileHeader.Failure.differentSource }
        referenceMigrationRequired = current.referenceVersion != candidate.referenceVersion
        publicStateMigrationRequired = current.stateVersion != candidate.stateVersion
        let origins = Set(current.origins.map(SourceFileHeader.originKey))
        addedOrigins = candidate.origins.map(SourceFileHeader.originKey).filter { !origins.contains($0) }
        addedCapabilities = candidate.capabilities.filter { !current.capabilities.contains($0) }
        addedAuthentication = candidate.authentication.filter { !current.authentication.contains($0) }
    }
}
