import Foundation

/// Transport follows this chain one response at a time. It never reuses a
/// prepared request's secrets or automatically retries a website write.
public struct SourceHTTPRedirects: Sendable {
    public private(set) var request: YingxueWire.HTTPRequest
    public private(set) var url: URL
    private let policy: SourceHostPolicy
    private let maximum: Int
    private var count = 0
    private var visited: Set<String>

    public init(request: YingxueWire.HTTPRequest, policy: SourceHostPolicy, maximum: Int) throws {
        guard maximum > 0 else { throw SourceHostFailure.invalidRedirect }
        _ = try YingxueWireCodec.encode(request)
        let url = try policy.resolve(request.target)
        self.request = request; self.url = url; self.policy = policy; self.maximum = maximum
        visited = [Self.key(url, method: request.method)]
    }

    /// The caller supplies the received Location once, not an arbitrary replacement
    /// URL from a native automatic-redirect delegate with credentials already filled.
    public mutating func follow(status: Int, location: String) throws -> YingxueWire.HTTPRequest {
        guard [301, 302, 303, 307, 308].contains(status) else { throw SourceHostFailure.invalidRedirect }
        guard count < maximum else { throw SourceHostFailure.redirectLimit }
        let nextURL = try policy.resolve(.init(url: location, baseURL: url.absoluteString))
        let becomesGET = (status == 303 && request.method != .head) || ([301, 302].contains(status) && request.method == .post)
        let method: YingxueWire.HTTPMethod = becomesGET ? .get : request.method
        let body: YingxueWire.HTTPBody = becomesGET ? .none(.init(kind: .none)) : request.body
        let sameOrigin = SourceOrigin.key(for: url) == SourceOrigin.key(for: nextURL)
        if !sameOrigin {
            guard case .none = body else { throw SourceHostFailure.originDenied }
        }
        let headers = sameOrigin ? request.headers.filter { !becomesGET || !["content-type", "content-encoding"].contains($0.name.lowercased()) } : []
        let key = Self.key(nextURL, method: method)
        guard !visited.contains(key) else { throw SourceHostFailure.redirectLoop }
        let next = YingxueWire.HTTPRequest(target: .init(url: nextURL.absoluteString), method: method, headers: headers, body: body)
        // Mutate only after all validation succeeds, preserving the prior hop on failure.
        visited.insert(key); count += 1; url = nextURL; request = next
        return next
    }

    private static func key(_ url: URL, method: YingxueWire.HTTPMethod) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        parts?.fragment = nil
        return method.rawValue + " " + (parts?.string ?? url.absoluteString)
    }
}
