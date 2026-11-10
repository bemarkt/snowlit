import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SnowlitCore
import Synchronization
import Testing
@testable import YingxueKit

@Suite(.serialized)
@MainActor
struct SourceHTTPTransportTests {
    @Test func responseAndRedirectsUseRealTransportWithoutExposingSessionHeaders() async throws {
        let fixture = try await Fixture()
        HTTPTransportFixture.reset([
            "/start": .init(status: 302, headers: ["Location": "/done", "Set-Cookie": "private=value; Path=/"]),
            "/done": .init(status: 200, headers: ["Set-Cookie": "private=new; Path=/"], text: "中文")
        ])
        do {
            let value = try await fixture.transport.perform(fixture.request("/start"), policy: fixture.policy,
                gate: fixture.gate, ticket: fixture.ticket, credentials: fixture.credentials)
            #expect(value.status == 200 && value.finalURL == "https://fixture.invalid/done")
            #expect(Data(base64Encoded: value.base64) == Data("中文".utf8))
            #expect(!value.headers.contains { $0.name.lowercased().hasPrefix("set-cookie") })
            #expect(HTTPTransportFixture.requests.map { $0.url?.path } == ["/start", "/done"])
            try await fixture.gate.finish(fixture.ticket)
        } catch { await fixture.transport.close(); throw error }
        await fixture.transport.close()
    }

    @Test func undeclaredRedirectNeverReachesItsDestination() async throws {
        let fixture = try await Fixture()
        HTTPTransportFixture.reset(["/start": .init(status: 302, headers: ["Location": "https://denied.invalid/private"])])
        await #expect(throws: SourceHostFailure.originDenied) {
            try await fixture.transport.perform(fixture.request("/start"), policy: fixture.policy,
                gate: fixture.gate, ticket: fixture.ticket, credentials: fixture.credentials)
        }
        #expect(HTTPTransportFixture.requests.count == 1)
        await fixture.gate.cancel(fixture.ticket)
        await fixture.transport.close()
    }

    @Test func crossOriginRedirectDoesNotResendCredentialBody() async throws {
        let fixture = try await Fixture()
        let stored = StoredCredentialID(installationID: fixture.installation)
        await fixture.credentials.write(.init(utf8: "private"), for: stored)
        let handle = try await fixture.gate.issueCredential(stored, origins: [.init(scheme: .https, host: "fixture.invalid")], for: fixture.ticket)
        HTTPTransportFixture.reset(["/start": .init(status: 307, headers: ["Location": "https://other.invalid/done"])])
        let request = YingxueWire.HTTPRequest(target: .init(url: "https://fixture.invalid/start"), method: .post, headers: [],
            body: .form(.init(kind: .form, fields: [.init(name: "password", value: .credential(.init(kind: .credential, handle: handle, prefix: "", suffix: "")))])))
        // A cross-origin redirect cannot resend a filled credential body even
        // when both origins are declared by the source.
        await #expect(throws: SourceHostFailure.originDenied) {
            try await fixture.transport.perform(request, policy: fixture.policy,
                gate: fixture.gate, ticket: fixture.ticket, credentials: fixture.credentials)
        }
        #expect(HTTPTransportFixture.requests.count == 1)
        await fixture.gate.cancel(fixture.ticket)
        await fixture.transport.close()
    }

    @Test func sameOriginRedirectResolvesCredentialAgainForTheNextHop() async throws {
        let fixture = try await Fixture()
        let stored = StoredCredentialID(installationID: fixture.installation)
        await fixture.credentials.write(.init(utf8: "private"), for: stored)
        let handle = try await fixture.gate.issueCredential(stored, origins: [.init(scheme: .https, host: "fixture.invalid")], for: fixture.ticket)
        HTTPTransportFixture.reset(["/start": .init(status: 307, headers: ["Location": "/done"]), "/done": .init(status: 200)])
        let request = YingxueWire.HTTPRequest(target: .init(url: "https://fixture.invalid/start"), method: .post, headers: [],
            body: .form(.init(kind: .form, fields: [.init(name: "password", value: .credential(.init(kind: .credential, handle: handle, prefix: "", suffix: "")))])))
        do {
            let result = try await fixture.transport.perform(request, policy: fixture.policy,
                gate: fixture.gate, ticket: fixture.ticket, credentials: fixture.credentials)
            #expect(result.status == 200)
            #expect(HTTPTransportFixture.requests.map(\.httpMethod) == ["POST", "POST"])
            #expect(await fixture.credentials.readCount == 2)
            try await fixture.gate.finish(fixture.ticket)
        } catch { await fixture.transport.close(); throw error }
        await fixture.transport.close()
    }

    @Test func revokedOperationCannotDeliverALateNativeResponse() async throws {
        let fixture = try await Fixture()
        HTTPTransportFixture.reset(["/pending": .init(status: 200, text: "late", suspended: true)])
        let task = Task { try await fixture.transport.perform(fixture.request("/pending"), policy: fixture.policy,
            gate: fixture.gate, ticket: fixture.ticket, credentials: fixture.credentials) }
        try await waitForRequest()
        await fixture.gate.cancel(fixture.ticket)
        HTTPTransportFixture.release()
        await #expect(throws: SourceOperationGate.Failure.staleOperation) { try await task.value }
        await fixture.transport.close()
    }

    @Test func closeCancelsPendingIORevokesItsTicketAndRejectsReuse() async throws {
        let fixture = try await Fixture()
        HTTPTransportFixture.reset(["/pending": .init(status: 200, text: "late", suspended: true)])
        let task = Task { try await fixture.transport.perform(fixture.request("/pending"), policy: fixture.policy,
            gate: fixture.gate, ticket: fixture.ticket, credentials: fixture.credentials) }
        try await waitForRequest()
        await fixture.transport.close()
        await #expect(throws: SourceHTTPTransportFailure.closed) { try await task.value }
        #expect(await fixture.gate.pendingCount == 0)
        await #expect(throws: SourceHTTPTransportFailure.closed) {
            try await fixture.transport.perform(fixture.request("/pending"), policy: fixture.policy,
                gate: fixture.gate, ticket: fixture.ticket, credentials: fixture.credentials)
        }
        HTTPTransportFixture.release()
        await fixture.transport.close()
    }

    private func waitForRequest() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while HTTPTransportFixture.requests.isEmpty {
            guard ContinuousClock.now < deadline else { throw SourceHTTPTransportFailure.network }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private struct Fixture {
        let installation = SourceInstallationID()
        let policy: SourceHostPolicy
        let gate: SourceOperationGate
        let ticket: SourceOperationGate.Ticket
        let transport: SourceHTTPTransport
        let credentials = HTTPFixtureCredentials()

        init() async throws {
            let manifest = YingxueWire.Manifest(protocolVersion: 1, sourceID: "org.example.http", name: "HTTP", scriptVersion: "1",
                referenceVersion: 1, stateVersion: 1, capabilities: [.http], origins: [
                    .init(scheme: .https, host: "fixture.invalid"), .init(scheme: .https, host: "other.invalid")],
                authentication: [], publicConfiguration: [])
            let digest = String(repeating: "a", count: 64)
            policy = try .init(installationID: installation, scriptSHA256: digest, manifest: manifest)
            let credentials = try SourceCredentialPolicy(installationID: installation, scriptSHA256: digest, manifest: manifest)
            gate = try .init(installationID: installation, scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0,
                credentialPolicy: credentials)
            ticket = try await gate.begin(.search(.init(kind: .search, input: .init(query: "book", cursor: nil))))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HTTPTransportFixture.self]
            transport = .init(configuration: configuration)
        }

        func request(_ path: String) -> YingxueWire.HTTPRequest {
            .init(target: .init(url: "https://fixture.invalid" + path), method: .get, headers: [], body: .none(.init(kind: .none)))
        }
    }
}

private actor HTTPFixtureCredentials: CredentialStore {
    private var values: [StoredCredentialID: CredentialSecret] = [:]
    private(set) var readCount = 0
    func read(_ id: StoredCredentialID) -> CredentialSecret? { readCount += 1; return values[id] }
    func write(_ value: CredentialSecret, for id: StoredCredentialID) { values[id] = value }
    func remove(_ id: StoredCredentialID) { values.removeValue(forKey: id) }
    func removeAll(for installationID: SourceInstallationID) { values = values.filter { $0.key.installationID != installationID } }
}

/// URLProtocol's callbacks arrive on Foundation threads. All shared fixture
/// records are protected by Mutex; instances add no unprotected mutable state.
private final class HTTPTransportFixture: URLProtocol {
    struct Response: Sendable {
        let status: Int
        var headers: [String: String] = [:]
        var text = ""
        var suspended = false
    }
    private struct State {
        var routes: [String: Response] = [:]
        var requests: [URLRequest] = []
        var suspended: [(HTTPProtocolDelivery, Response)] = []
        var deliveries: [ObjectIdentifier: HTTPProtocolDelivery] = [:]
    }
    private static let state = Mutex(State())
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func reset(_ routes: [String: Response]) { state.withLock { $0 = .init(routes: routes) } }
    static func release() {
        let waiting = state.withLock { state in let values = state.suspended; state.suspended = []; return values }
        for (delivery, response) in waiting { delivery.deliver(response) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delivery = HTTPProtocolDelivery(self)
        let identity = ObjectIdentifier(self)
        let response = Self.state.withLock { state -> Response? in
            state.requests.append(request)
            state.deliveries[identity] = delivery
            guard let response = state.routes[request.url?.path ?? ""] else { return nil }
            if response.suspended { state.suspended.append((delivery, response)); return nil }
            return response
        }
        if let response { delivery.deliver(response) }
    }
    override func stopLoading() {
        let identity = ObjectIdentifier(self)
        Self.state.withLock { $0.deliveries[identity] }?.stop()
    }
}

/// URLProtocol explicitly cannot be Sendable on some Foundation platforms.
/// This test-only box serializes stop and delivery with a recursive lock and
/// never exposes its retained instance outside these two protected operations.
private final class HTTPProtocolDelivery: @unchecked Sendable {
    private let instance: HTTPTransportFixture
    private let lock = NSRecursiveLock()
    private var stopped = false
    init(_ instance: HTTPTransportFixture) { self.instance = instance }
    func stop() { lock.lock(); defer { lock.unlock() }; stopped = true }
    func deliver(_ response: HTTPTransportFixture.Response) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, let url = instance.request.url,
              let native = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else { return }
        instance.client?.urlProtocol(instance, didReceive: native, cacheStoragePolicy: .notAllowed)
        instance.client?.urlProtocol(instance, didLoad: Data(response.text.utf8))
        instance.client?.urlProtocolDidFinishLoading(instance)
    }
}
