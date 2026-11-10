import Foundation

/// Trusted parser resources. The module being inspected is supplied as a string
/// argument; it must never be concatenated into or evaluated as the bootstrap.
public struct SourceInspectionProgram: Sendable {
    public enum Failure: Error, Equatable, Sendable { case missingResource }
    public let bootstrap: String
    public let evaluationBody = "return JSON.stringify(globalThis.snowlitInspectSource(source, requirements));"

    public init() throws {
        let names = ["acorn", "module-policy", "inspect-source"]
        bootstrap = try names.map { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "SourceInspection") else {
                throw Failure.missingResource
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n;\n")
    }
}

public enum SourceModuleInspection {
    public enum Failure: Error, Equatable, Sendable {
        case rejected(YingxueWire.ModuleRejected)
        case missingExport
    }

    public static func requirements(for manifest: YingxueWire.Manifest) -> [String] {
        manifest.authentication.isEmpty ? [] : ["authenticate"]
    }

    /// A parser report is consumed only from the trusted host invocation. A source
    /// cannot install itself by supplying this JSON as its own operation result.
    public static func accept(_ bytes: Data, manifest: YingxueWire.Manifest) throws -> [YingxueWire.ExportName] {
        switch try YingxueWireCodec.decode(YingxueWire.ModuleInspection.self, from: bytes) {
        case .rejected(let report): throw Failure.rejected(report)
        case .accepted(let report):
            let names = Set(report.exports.map(\.rawValue))
            guard Set(GeneratedModulePolicy.requiredExports + requirements(for: manifest)).isSubset(of: names) else {
                throw Failure.missingExport
            }
            return report.exports
        }
    }
}
