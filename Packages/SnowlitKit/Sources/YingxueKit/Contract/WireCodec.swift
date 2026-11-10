import Foundation

/// Only this codec is a wire boundary. Codable alone does not enforce the schema.
public protocol YingxueWireModel: Codable, Sendable {
    static var wireType: String { get }
}

public struct WireViolation: Error, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case malformedJSON, duplicateField, unknownType, wrongType, missingField, unknownField, invalidValue, duplicateItem, unknownVariant
    }
    /// Schema paths and categories only. A failed value may contain private site data.
    public let path: String
    public let reason: Reason
    public init(path: String, reason: Reason) { self.path = path; self.reason = reason }
}

public enum YingxueWireCodec {
    public static func decode<T: YingxueWireModel>(_ type: T.Type, from bytes: Data) throws -> T {
        try validate(bytes, as: type.wireType)
        return try JSONDecoder().decode(type, from: bytes)
    }

    public static func encode<T: YingxueWireModel>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        try validate(bytes, as: T.wireType)
        return bytes
    }

    public static func validate(_ bytes: Data, as type: String) throws {
        let value = try jsonValue(bytes)
        try validate(value, as: type, path: "$")
    }

    /// Arbitrary serialized page input/output still rejects malformed JSON and
    /// duplicate keys. JavaScript values that cannot serialize are not results.
    public static func validateJSON(_ bytes: Data) throws { _ = try jsonValue(bytes) }

    private static func jsonValue(_ bytes: Data) throws -> WireValue {
        let value: WireValue
        do { value = try JSONDecoder().decode(WireValue.self, from: bytes) }
        catch { throw WireViolation(path: "$", reason: .malformedJSON) }
        var keys = WireJSONKeys(bytes: Array(bytes))
        try keys.check()
        return value
    }

    private static func validate(_ value: WireValue, as type: String, path: String) throws {
        func reject(_ reason: WireViolation.Reason) throws -> Never { throw WireViolation(path: path, reason: reason) }
        guard let rule = GeneratedWireSchema.rules[type] else { try reject(.unknownType) }
        switch rule {
        case .string(let nullable, let minimum, let pattern, let choices):
            if nullable, case .null = value { return }
            guard case .string(let string) = value else { try reject(.wrongType) }
            guard string.unicodeScalars.count >= minimum else { try reject(.invalidValue) }
            if let pattern {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(string.startIndex..., in: string)
                guard regex.firstMatch(in: string, range: range) != nil else { try reject(.invalidValue) }
            }
            if !choices.isEmpty, !choices.contains(where: { $0.utf8.elementsEqual(string.utf8) }) { try reject(.invalidValue) }
        case .integer(let minimum, let maximum):
            guard case .number(let number) = value else { try reject(.wrongType) }
            guard number.isFinite, number.rounded(.towardZero) == number,
                  number >= Double(minimum), number <= Double(maximum) else { try reject(.invalidValue) }
        case .boolean:
            guard case .boolean = value else { try reject(.wrongType) }
        case .array(let item, let unique):
            guard case .array(let items) = value else { try reject(.wrongType) }
            for (index, itemValue) in items.enumerated() {
                try validate(itemValue, as: item, path: "\(path)[\(index)]")
                if unique, items[..<index].contains(itemValue) { try reject(.duplicateItem) }
            }
        case .object(let fields):
            guard case .object(let object) = value else { try reject(.wrongType) }
            // Unknown field names are intentionally absent from the diagnostic.
            guard object.keys.allSatisfy({ fields[$0] != nil }) else { try reject(.unknownField) }
            for name in fields.keys.sorted() {
                guard let field = fields[name] else { continue }
                if let nested = object[name] {
                    try validate(nested, as: field.type, path: path + "." + name)
                } else if field.required {
                    throw WireViolation(path: path + "." + name, reason: .missingField)
                }
            }
        case .tagged(let alternatives):
            guard case .object(let object) = value, case .string(let tag) = object["kind"] else { try reject(.wrongType) }
            guard let target = alternatives[tag] else { try reject(.unknownVariant) }
            try validate(value, as: target, path: path)
        }
    }
}

/// Foundation and JavaScript may choose different values for repeated JSON keys.
/// Syntax is checked by JSONDecoder first; this pass rejects every repeated key,
/// including escaped spellings, before any model or manifest is accepted.
private struct WireJSONKeys {
    let bytes: [UInt8]
    private var cursor = 0
    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func check() throws { try value() }
    private mutating func space() { while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 } }
    private mutating func take(_ byte: UInt8) throws {
        space()
        guard cursor < bytes.count, bytes[cursor] == byte else { throw WireViolation(path: "$", reason: .malformedJSON) }
        cursor += 1
    }
    private mutating func string() throws -> Data {
        space()
        let start = cursor
        try take(34)
        while cursor < bytes.count {
            let byte = bytes[cursor]
            cursor += 1
            if byte == 34 {
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<cursor]))
                return Data(key.utf8)
            }
            if byte == 92 { cursor += 1 }
        }
        throw WireViolation(path: "$", reason: .malformedJSON)
    }
    private mutating func value() throws {
        space()
        guard cursor < bytes.count else { throw WireViolation(path: "$", reason: .malformedJSON) }
        switch bytes[cursor] {
        case 123:
            cursor += 1; space()
            var names = Set<Data>()
            if cursor < bytes.count, bytes[cursor] == 125 { cursor += 1; return }
            while true {
                let name = try string()
                guard names.insert(name).inserted else { throw WireViolation(path: "$", reason: .duplicateField) }
                try take(58); try value(); space()
                if cursor < bytes.count, bytes[cursor] == 125 { cursor += 1; return }
                try take(44)
            }
        case 91:
            cursor += 1; space()
            if cursor < bytes.count, bytes[cursor] == 93 { cursor += 1; return }
            while true {
                try value(); space()
                if cursor < bytes.count, bytes[cursor] == 93 { cursor += 1; return }
                try take(44)
            }
        case 34: _ = try string()
        default:
            while cursor < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[cursor]) { cursor += 1 }
        }
    }
}

enum WireDiscriminator: String, CodingKey { case kind }

enum WireRule: Sendable {
    struct Field: Sendable { let type: String; let required: Bool }
    case string(nullable: Bool, minimum: Int, pattern: String?, choices: [String])
    case integer(minimum: Int, maximum: Int)
    case boolean
    case array(item: String, unique: Bool)
    case object([String: Field])
    case tagged([String: String])
}

private enum WireValue: Decodable, Equatable {
    case null, boolean(Bool), number(Double), string(String), array([WireValue]), object([String: WireValue])

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let array = try? value.decode([WireValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: WireValue].self)) }
    }
}
