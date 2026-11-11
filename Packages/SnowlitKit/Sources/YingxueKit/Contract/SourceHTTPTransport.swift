import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SnowlitCore

public enum SourceHTTPTransportFailure: Error, Equatable, Sendable { case closed, invalidResponse, network }

/// One native HTTP session per website session. Redirects are handled one hop at
/// a time so filled credentials are never forwarded by URLSession implicitly.
@MainActor
public final class SourceHTTPTransport {
    private struct Pending {
        let work: Task<(Data, URLResponse), any Error>
        let gate: SourceOperationGate
        let ticket: SourceOperationGate.Ticket
    }
    private let session: URLSession
    private var pending: [UUID: Pending] = [:]
    private var cookieJar: [HTTPCookie]
    private var closed = false
    private var closing: Task<Void, Never>?

    public convenience init() { self.init(cookies: []) }

    /// Native website-session transfer only. Cookies are never exposed on Wire.
    /// URLSession's own cookie storage is deliberately disabled: a new transport
    /// is created per request, so the jar must live in this object and match
    /// paths/hosts explicitly.
    init(cookies: [HTTPCookie]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: SourceRedirectDelegate(), delegateQueue: nil)
        cookieJar = cookies
    }

    var cookies: [HTTPCookie] { cookieJar }

    // A local test can inject an isolated URLProtocol without changing production
    // session behavior or replacing the redirect/credential/gate implementation.
    init(configuration: URLSessionConfiguration) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: SourceRedirectDelegate(), delegateQueue: nil)
        cookieJar = []
    }

    public func perform(_ request: YingxueWire.HTTPRequest, policy: SourceHostPolicy, gate: SourceOperationGate,
                        ticket: SourceOperationGate.Ticket, credentials: any CredentialStore) async throws -> YingxueWire.HTTPResponse {
        guard !closed else { throw SourceHTTPTransportFailure.closed }
        var redirects = try SourceHTTPRedirects(request: request, policy: policy, maximum: 8)
        while true {
            let prepared = try await SourceHTTPContract.prepare(redirects.request, policy: policy, gate: gate,
                ticket: ticket, credentials: credentials)
            try Task.checkCancellation()
            guard !closed else { throw SourceHTTPTransportFailure.closed }
            var native = URLRequest(url: prepared.url)
            native.httpMethod = prepared.method; native.httpBody = prepared.body
            native.allHTTPHeaderFields = prepared.headers
            if let cookie = cookieHeader(for: prepared.url) {
                native.addValue(cookie, forHTTPHeaderField: "Cookie")
            }
            let id = UUID()
            // Finite native I/O owned by this request and by close(). Parent
            // cancellation forwards to data(for:) and awaits its termination.
            let work = Task { [session] in try await session.data(for: native) }
            pending[id] = .init(work: work, gate: gate, ticket: ticket)
            let bytes: Data
            let response: URLResponse
            do {
                (bytes, response) = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: { work.cancel() }
            } catch {
                pending.removeValue(forKey: id)
                if Task.isCancelled { throw CancellationError() }
                guard !closed else { throw SourceHTTPTransportFailure.closed }
                try await gate.check(ticket)
                throw SourceHTTPTransportFailure.network
            }
            pending.removeValue(forKey: id)
            try Task.checkCancellation()
            try await gate.check(ticket)
            guard !closed else { throw SourceHTTPTransportFailure.closed }
            guard let response = response as? HTTPURLResponse, let url = response.url,
                  url == prepared.url else { throw SourceHTTPTransportFailure.invalidResponse }
            acceptCookies(from: response, for: url)
            if [301, 302, 303, 307, 308].contains(response.statusCode),
               let location = response.value(forHTTPHeaderField: "Location") {
                _ = try redirects.follow(status: response.statusCode, location: location)
                continue
            }
            let headers = response.allHeaderFields.map {
                YingxueWire.HTTPResponseHeader(name: String(describing: $0.key), value: String(describing: $0.value))
            }
            return try SourceHTTPContract.response(status: response.statusCode, finalURL: url,
                headers: headers, body: bytes, policy: policy)
        }
    }

    private func cookieHeader(for url: URL) -> String? {
        let now = Date()
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let matching = cookieJar.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
            let domain = cookie.domain.lowercased().hasPrefix(".")
                ? String(cookie.domain.lowercased().dropFirst()) : cookie.domain.lowercased()
            guard !domain.isEmpty, host == domain || host.hasSuffix("." + domain) else { return false }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            return path.hasPrefix(cookiePath)
        }.sorted { $0.path.count > $1.path.count }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func acceptCookies(from response: HTTPURLResponse, for url: URL) {
        let values = response.allHeaderFields.compactMap { key, value -> String? in
            guard let name = key as? String, name.caseInsensitiveCompare("Set-Cookie") == .orderedSame else { return nil }
            return value as? String
        }
        guard !values.isEmpty else { return }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": values.joined(separator: ", ")], for: url)
        let now = Date()
        for cookie in parsed {
            cookieJar.removeAll { sameCookieIdentity($0, cookie) }
            if let expires = cookie.expiresDate, expires <= now { continue }
            cookieJar.append(cookie)
        }
    }

    private func sameCookieIdentity(_ a: HTTPCookie, _ b: HTTPCookie) -> Bool {
        a.name == b.name && a.domain.caseInsensitiveCompare(b.domain) == .orderedSame && a.path == b.path
    }

    /// Idempotent awaited shutdown. A new login/source generation gets a new
    /// transport; old callbacks cannot change or deliver into that session.
    public func close() async {
        if let closing { return await closing.value }
        if closed { return }
        closed = true
        let requests = Array(pending.values)
        requests.forEach { $0.work.cancel() }
        session.invalidateAndCancel()
        // This finite cleanup outlives a cancelled caller but is always awaited.
        let task = Task {
            for request in requests {
                await request.gate.cancel(request.ticket)
                _ = await request.work.result
            }
        }
        closing = task
        await task.value
        closing = nil
    }
}

private final class SourceRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
