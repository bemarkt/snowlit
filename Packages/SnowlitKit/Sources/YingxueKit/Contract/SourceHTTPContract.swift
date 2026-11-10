import Foundation
import SnowlitCore

/// Native transport input, not a wire result. It may contain credentials.
public struct PreparedSourceHTTPRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public var description: String { "[redacted HTTP request]" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum SourceHTTPContract {
    /// Prepares one hop. Transport must disable automatic redirect forwarding,
    /// prepare the redirected request separately, and recheck the ticket before
    /// sending or delivering a response. This function does not perform I/O.
    public static func prepare(_ request: YingxueWire.HTTPRequest, policy: SourceHostPolicy,
                               gate: SourceOperationGate, ticket: SourceOperationGate.Ticket,
                               credentials: any CredentialStore) async throws -> PreparedSourceHTTPRequest {
        try await gate.check(ticket)
        try policy.check(ticket.call.context, capability: .http)
        _ = try YingxueWireCodec.encode(request)
        let url = try policy.resolve(request.target)
        var headers: [String: String] = [:]
        for header in request.headers {
            let name = header.name.lowercased()
            guard !forbiddenHeaders.contains(name), !name.hasPrefix("proxy-"), !name.hasPrefix("sec-"),
                  headers[name] == nil else { throw SourceHostFailure.invalidHeader }
            let value = try await resolve(header.value, url: url, gate: gate, ticket: ticket, store: credentials)
            try await gate.check(ticket)
            guard validHeaderValue(value) else { throw SourceHostFailure.invalidHeader }
            headers[name] = value
        }
        let body: Data?
        switch request.body {
        case .none: body = nil
        case .bytes(let bytes):
            guard request.method != .get, request.method != .head, headers["content-type"] == nil,
                  !bytes.contentType.isEmpty, validHeaderValue(bytes.contentType),
                  let value = Data(base64Encoded: bytes.base64) else { throw SourceHostFailure.invalidBody }
            headers["content-type"] = bytes.contentType
            body = value
        case .form(let form):
            guard request.method != .get, request.method != .head, headers["content-type"] == nil else { throw SourceHostFailure.invalidBody }
            var fields: [String] = []
            for field in form.fields {
                let value = try await resolve(field.value, url: url, gate: gate, ticket: ticket, store: credentials)
                try await gate.check(ticket)
                fields.append(formEscape(field.name) + "=" + formEscape(value))
            }
            headers["content-type"] = "application/x-www-form-urlencoded; charset=utf-8"
            body = Data(fields.joined(separator: "&").utf8)
        }
        try await gate.check(ticket)
        return .init(url: url, method: request.method.rawValue.uppercased(), headers: headers, body: body)
    }

    /// Preserve repeated response headers except host-owned session secrets.
    /// Set-Cookie must first be handled by the native session's cookie store.
    public static func response(status: Int, finalURL: URL, headers: [YingxueWire.HTTPResponseHeader], body: Data,
                                policy: SourceHostPolicy) throws -> YingxueWire.HTTPResponse {
        _ = try policy.resolve(.init(url: finalURL.absoluteString))
        let result = YingxueWire.HTTPResponse(status: status, finalURL: finalURL.absoluteString,
            headers: headers.filter { !["set-cookie", "set-cookie2"].contains($0.name.lowercased()) }, base64: body.base64EncodedString())
        _ = try YingxueWireCodec.encode(result)
        return result
    }

    private static let forbiddenHeaders: Set<String> = ["host", "cookie", "cookie2", "set-cookie", "set-cookie2", "content-length",
        "transfer-encoding", "connection", "upgrade", "trailer", "te", "keep-alive"]

    private static func validHeaderValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { ($0.value < 32 && $0.value != 9) || $0.value == 127 }
    }

    private static func resolve(_ value: YingxueWire.HTTPValue, url: URL, gate: SourceOperationGate,
                                ticket: SourceOperationGate.Ticket, store: any CredentialStore) async throws -> String {
        switch value {
        case .literal(let literal): return literal.value
        case .credential(let credential):
            let secret = try await gate.credentialForHost(credential.handle, destination: url, for: ticket, store: store)
            try await gate.check(ticket)
            guard let value = String(data: secret.bytes, encoding: .utf8) else { throw SourceCredentialFailure.invalidUTF8 }
            return credential.prefix + value + credential.suffix
        }
    }

    private static func formEscape(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 42, 45, 46, 95: String(UnicodeScalar(byte))
            case 32: "+"
            default: String(format: "%%%02X", byte)
            }
        }.joined()
    }
}
