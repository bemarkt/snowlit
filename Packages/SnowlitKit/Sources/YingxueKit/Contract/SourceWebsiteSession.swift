#if os(iOS)
import Foundation
import WebKit
import SnowlitCore

public enum SourceWebsiteFailure: Error, Equatable, Sendable { case closed, cleanupIncomplete }

/// One explicitly selected website store. Candidate validation uses a separate
/// nonpersistent store; installed sources supply their own persistent store ID.
/// Only native owners see cookies. This object never changes local book identity.
@MainActor
public final class SourceWebsiteSession {
    public let dataStore: WKWebsiteDataStore
    private struct Request {
        let work: Task<YingxueWire.HTTPResponse, any Error>
        let transport: SourceHTTPTransport
    }
    private struct CookieKey: Hashable {
        let name: String
        let domain: String
        let path: String
        init(_ cookie: HTTPCookie) { name = cookie.name; domain = cookie.domain; path = cookie.path }
    }
    private var requests: [UUID: Request] = [:]
    private var closed = false
    private var closing: Task<Void, Never>?
    private let initialCookies: [HTTPCookie]
    private let onCookies: (@MainActor ([HTTPCookie]) -> Void)?

    public init(dataStore: WKWebsiteDataStore, initialCookies: [HTTPCookie] = [],
                onCookies: (@MainActor ([HTTPCookie]) -> Void)? = nil) {
        self.dataStore = dataStore
        self.initialCookies = initialCookies
        self.onCookies = onCookies
    }

    public func perform(_ request: YingxueWire.HTTPRequest, policy: SourceHostPolicy, gate: SourceOperationGate,
                        ticket: SourceOperationGate.Ticket, credentials: any CredentialStore) async throws -> YingxueWire.HTTPResponse {
        try checkOpen()
        try await gate.check(ticket)
        let before = Self.merge(initialCookies, await dataStore.httpCookieStore.allCookies())
        try checkOpen()
        try await gate.check(ticket)
        // An in-flight request owns its own native jar, including redirects.
        // Another request cannot replace that jar while this one is using it.
        let transport = SourceHTTPTransport(cookies: before)
        let id = UUID()
        // Finite I/O and cookie writes belong to this session. Both perform and
        // close await completion, including a cookie-store call already in flight.
        let work = Task { @MainActor in
            let response = try await transport.perform(request, policy: policy, gate: gate, ticket: ticket, credentials: credentials)
            try checkOpen()
            try await gate.check(ticket)
            try await applyChanges(from: before, to: transport.cookies, gate: gate, ticket: ticket)
            try checkOpen()
            try await gate.check(ticket)
            onCookies?(transport.cookies)
            return response
        }
        requests[id] = .init(work: work, transport: transport)
        do {
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            await transport.close()
            requests.removeValue(forKey: id)
            try checkOpen()
            try await gate.check(ticket)
            return result
        } catch {
            await transport.close()
            requests.removeValue(forKey: id)
            throw error
        }
    }

    /// Stops native I/O without removing the persistent website session. The
    /// owner must close its browser pages too before requesting website erasure.
    public func close() async {
        if let closing { return await closing.value }
        if closed { return }
        closed = true
        let active = Array(requests.values)
        active.forEach { $0.work.cancel() }
        let task = Task { @MainActor in
            for request in active {
                await request.transport.close()
                _ = await request.work.result
            }
        }
        closing = task
        await task.value
        closing = nil
    }

    /// Caller first closes every browser for this exact website-session ID.
    /// A failed verification leaves cleanup pending for the management owner.
    public func erase() async throws {
        await close()
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let cookies = await dataStore.httpCookieStore.allCookies()
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        guard cookies.isEmpty, records.isEmpty else { throw SourceWebsiteFailure.cleanupIncomplete }
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw SourceWebsiteFailure.closed }
    }

    private func applyChanges(from before: [HTTPCookie], to after: [HTTPCookie], gate: SourceOperationGate,
                              ticket: SourceOperationGate.Ticket) async throws {
        let old = Dictionary(uniqueKeysWithValues: before.map { (CookieKey($0), $0) })
        let new = Dictionary(uniqueKeysWithValues: after.map { (CookieKey($0), $0) })
        let store = dataStore.httpCookieStore
        // Apply only the request's delta; unrelated cookies set by a browser or
        // another request since the snapshot are not removed or overwritten.
        for (key, cookie) in new where old[key].map({ !Self.same($0, cookie) }) ?? true {
            try checkOpen(); try await gate.check(ticket)
            await store.setCookie(cookie)
        }
        for (key, cookie) in old where new[key] == nil {
            try checkOpen(); try await gate.check(ticket)
            let current = await store.allCookies().first { CookieKey($0) == key }
            try checkOpen(); try await gate.check(ticket)
            // A deletion of the snapshotted value cannot delete a newer value
            // the website supplied while this request was in flight.
            if let current, Self.same(current, cookie) { await store.deleteCookie(current) }
        }
    }

    private static func merge(_ initial: [HTTPCookie], _ stored: [HTTPCookie]) -> [HTTPCookie] {
        var values: [CookieKey: HTTPCookie] = [:]
        for cookie in initial { values[CookieKey(cookie)] = cookie }
        for cookie in stored { values[CookieKey(cookie)] = cookie }
        return Array(values.values)
    }

    private static func same(_ a: HTTPCookie, _ b: HTTPCookie) -> Bool {
        // Cookie stores may add their own creation bookkeeping on import. Only
        // transferred HTTP attributes determine whether the response changed it.
        a.value == b.value && a.domain == b.domain && a.path == b.path && a.name == b.name &&
        a.expiresDate == b.expiresDate && a.isSecure == b.isSecure && a.isHTTPOnly == b.isHTTPOnly &&
        a.isSessionOnly == b.isSessionOnly && a.version == b.version &&
        (a.properties?[HTTPCookiePropertyKey("SameSite")] as? String) == (b.properties?[HTTPCookiePropertyKey("SameSite")] as? String)
    }
}
#endif
