import Foundation
import SnowlitCore

public enum SourceConfigurationFailure: Error, Equatable, Sendable {
    case duplicateKey, unknownKey, invalidValue, staleRevision
}

/// Immutable public settings captured by the native owner at operation start.
/// This is distinct from mutable source state and from stored credentials.
public struct SourceConfiguration: Sendable {
    private let policy: SourceHostPolicy
    private let snapshot: YingxueWire.ConfigurationSnapshot

    public init(policy: SourceHostPolicy, revision: Int, saved: [SourceSettingValue]) throws {
        try SourceSettingValue.validate(saved)
        try self.init(policy: policy, revision: revision, overrides: saved.map {
            switch $0 {
            case .text(let key, let value): .text(.init(kind: .text, key: key, value: value))
            case .boolean(let key, let value): .boolean(.init(kind: .boolean, key: key, value: value))
            }
        })
    }

    /// Save only values that passed the current manifest, including defaults.
    public var storedValues: [SourceSettingValue] {
        snapshot.values.map {
            switch $0 {
            case .text(let value): .text(key: value.key, value: value.value)
            case .boolean(let value): .boolean(key: value.key, value: value.value)
            }
        }
    }

    public init(policy: SourceHostPolicy, revision: Int, overrides: [YingxueWire.ConfigurationValue] = []) throws {
        try YingxueWireCodec.validate(JSONEncoder().encode(revision), as: "Revision")
        var supplied: [Data: YingxueWire.ConfigurationValue] = [:]
        for value in overrides {
            _ = try YingxueWireCodec.encode(value)
            guard supplied.updateValue(value, forKey: Data(value.key.utf8)) == nil else { throw SourceConfigurationFailure.duplicateKey }
        }
        let values: [YingxueWire.ConfigurationValue] = try policy.manifest.publicConfiguration.map { setting in
            switch setting {
            case .text(let field):
                let value = supplied.removeValue(forKey: Data(field.key.utf8)) ?? .text(.init(kind: .text, key: field.key, value: field.initial))
                guard case .text = value else { throw SourceConfigurationFailure.invalidValue }
                return value
            case .boolean(let field):
                let value = supplied.removeValue(forKey: Data(field.key.utf8)) ?? .boolean(.init(kind: .boolean, key: field.key, value: field.initial))
                guard case .boolean = value else { throw SourceConfigurationFailure.invalidValue }
                return value
            case .choice(let field):
                let value = supplied.removeValue(forKey: Data(field.key.utf8)) ?? .text(.init(kind: .text, key: field.key, value: field.initial))
                guard case .text(let choice) = value, field.choices.contains(where: { $0.value.utf8.elementsEqual(choice.value.utf8) }) else {
                    throw SourceConfigurationFailure.invalidValue
                }
                return value
            }
        }
        guard supplied.isEmpty else { throw SourceConfigurationFailure.unknownKey }
        self.policy = policy
        snapshot = .init(revision: revision, values: values)
    }

    /// The dispatcher also checks the gate immediately before delivering this value.
    public func read(for context: YingxueWire.OperationContext) throws -> YingxueWire.ConfigurationSnapshot {
        try policy.check(context)
        guard snapshot.revision == context.configurationRevision else { throw SourceConfigurationFailure.staleRevision }
        return snapshot
    }
}

private extension YingxueWire.ConfigurationValue {
    var key: String {
        switch self {
        case .text(let value): value.key
        case .boolean(let value): value.key
        }
    }
}
