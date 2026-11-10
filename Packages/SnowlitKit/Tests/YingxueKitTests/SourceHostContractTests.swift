import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct SourceHostContractTests {
    private let digest = String(repeating: "a", count: 64)
    private let origins: [YingxueWire.Origin] = [.init(scheme: .https, host: "fixture.invalid"), .init(scheme: .https, host: "next.invalid")]
    private var input: YingxueWire.OperationInput { .authenticate(.init(kind: .authenticate, input: .init(reason: .signIn))) }

    @Test func httpFillsScopedSecretsWithoutExposingThemToSourceOrDiagnostics() async throws {
        let (installation, policy, gate) = try environment()
        let ticket = try await gate.begin(input)
        let handle = try await gate.issueCredential(.init(installationID: installation), origins: [origins[0]], for: ticket)
        let secret = YingxueWire.HTTPValue.credential(.init(kind: .credential, handle: handle, prefix: "", suffix: ""))
        let request = YingxueWire.HTTPRequest(target: .init(url: "../login", baseURL: "https://fixture.invalid/books/"), method: .post,
            headers: [.init(name: "X-Token", value: secret)],
            body: .form(.init(kind: .form, fields: [.init(name: "password", value: secret), .init(name: "名字", value: literal("中 文+&"))])))
        let prepared = try await SourceHTTPContract.prepare(request, policy: policy, gate: gate, ticket: ticket, credentials: HostSecretStore())
        #expect(prepared.url.absoluteString == "https://fixture.invalid/login")
        #expect(prepared.method == "POST" && prepared.headers["x-token"] == "synthetic-secret")
        #expect(prepared.headers["content-type"] == "application/x-www-form-urlencoded; charset=utf-8")
        #expect(prepared.body == Data("password=synthetic-secret&%E5%90%8D%E5%AD%97=%E4%B8%AD+%E6%96%87%2B%26".utf8))
        #expect(!String(reflecting: prepared).contains("synthetic-secret"))
        #expect(Mirror(reflecting: prepared).children.isEmpty)
        await #expect(throws: SourceCredentialFailure.permissionDenied) { try await gate.credentialForSource(handle, for: ticket, store: HostSecretStore()) }
    }

    @Test func httpRejectsOriginAndHeaderSmugglingBeforeNativeSend() async throws {
        let (_, policy, gate) = try environment()
        let ticket = try await gate.begin(input)
        for url in ["https://outside.invalid/", "https://fixture.invalid:444/", "https://user:pass@fixture.invalid/", "https://fixture.invalid\\@outside.invalid/", "file:///tmp/private", "https://fixture.invalid/ bad"] {
            #expect(throws: (any Error).self) { try policy.resolve(.init(url: url)) }
        }
        for name in ["Cookie", "HOST", "Content-Length", "Transfer-Encoding", "Proxy-Authorization", "Sec-Fetch-Site"] {
            await #expect(throws: SourceHostFailure.invalidHeader) {
                try await SourceHTTPContract.prepare(request(headers: [.init(name: name, value: literal("x"))]), policy: policy, gate: gate, ticket: ticket, credentials: HostSecretStore())
            }
        }
        await #expect(throws: SourceHostFailure.invalidHeader) {
            try await SourceHTTPContract.prepare(request(headers: [.init(name: "X-Test", value: literal("x")), .init(name: "x-test", value: literal("y"))]), policy: policy, gate: gate, ticket: ticket, credentials: HostSecretStore())
        }
        await #expect(throws: SourceHostFailure.invalidHeader) {
            try await SourceHTTPContract.prepare(request(headers: [.init(name: "X-Test", value: literal("x\r\nOther: y"))]), policy: policy, gate: gate, ticket: ticket, credentials: HostSecretStore())
        }
        await #expect(throws: SourceHostFailure.invalidBody) {
            try await SourceHTTPContract.prepare(.init(target: .init(url: "https://fixture.invalid/"), method: .get, headers: [], body: .bytes(.init(kind: .bytes, base64: "eA==", contentType: "text/plain"))), policy: policy, gate: gate, ticket: ticket, credentials: HostSecretStore())
        }
    }

    @Test func redirectChangesAreExplicitAndFailuresPreserveCurrentHop() throws {
        let (_, policy, _) = try environment()
        var chain = try SourceHTTPRedirects(request: request(headers: [.init(name: "X-API-Token", value: literal("synthetic-secret"))]), policy: policy, maximum: 3)
        let next = try chain.follow(status: 302, location: "https://next.invalid/next")
        #expect(next.headers.isEmpty)
        #expect(throws: SourceHostFailure.originDenied) { try chain.follow(status: 302, location: "https://outside.invalid/") }
        #expect(chain.url.absoluteString == "https://next.invalid/next")
        #expect(throws: SourceHostFailure.redirectLoop) { try chain.follow(status: 301, location: "#section") }
        _ = try chain.follow(status: 302, location: "/last")
        _ = try chain.follow(status: 302, location: "/limit")
        #expect(throws: SourceHostFailure.redirectLimit) { try chain.follow(status: 302, location: "/beyond") }

        let post = YingxueWire.HTTPRequest(target: .init(url: "https://fixture.invalid/login"), method: .post, headers: [],
            body: .form(.init(kind: .form, fields: [.init(name: "x", value: literal("y"))])))
        var writing = try SourceHTTPRedirects(request: post, policy: policy, maximum: 4)
        #expect(throws: SourceHostFailure.originDenied) { try writing.follow(status: 307, location: "https://next.invalid/") }
        let preserved = try writing.follow(status: 307, location: "./other")
        #expect(preserved.method == .post && preserved.body == post.body)
        let get = try writing.follow(status: 303, location: "./other")
        #expect(get.method == .get && get.body == .none(.init(kind: .none)))
    }

    @Test func responsePreservesBytesAndRepeatedHeadersWhileCookiesRemainHostOwned() throws {
        let (_, policy, _) = try environment()
        let result = try SourceHTTPContract.response(status: 401, finalURL: URL(string: "https://fixture.invalid/content")!,
            headers: [.init(name: "Set-Cookie", value: "sid=synthetic-secret"), .init(name: "X-Part", value: "a"), .init(name: "X-Part", value: "b")],
            body: Data([0xd6, 0xd0, 0xce, 0xc4]), policy: policy)
        #expect(result.status == 401 && result.headers.map(\.value) == ["a", "b"])
        #expect(result.base64 == "1tDOxA==")
        #expect(!String(decoding: try YingxueWireCodec.encode(result), as: UTF8.self).contains("synthetic-secret"))
    }

    @Test func domQueriesPreserveOrderEntitiesAndMissingVersusEmptyAttributes() throws {
        let result = try SourceDOMContract.query(.init(html: "<p>重<strong>复</strong> &amp; 中文</p><p>重复</p><a href='/a'>A</a><a>B</a><a href=''>C</a><script>throw 'must not execute'</script>", selections: [
            .text(.init(kind: .text, key: "text", selector: "p")),
            .html(.init(kind: .html, key: "html", selector: "p:first-of-type")),
            .attribute(.init(kind: .attribute, key: "urls", selector: "a", attribute: "href")),
            .text(.init(kind: .text, key: "missing", selector: "h9"))]))
        #expect(result.selections[0].values == ["重复 & 中文", "重复"])
        #expect(result.selections[1].values.first??.contains("<strong>复</strong>") == true)
        #expect(result.selections[2].values == ["/a", nil, ""])
        #expect(result.selections[3].values.isEmpty)
        let bytes = try YingxueWireCodec.encode(result)
        #expect(try YingxueWireCodec.decode(YingxueWire.DOMResult.self, from: bytes) == result)
        #expect(throws: SourceHostFailure.invalidSelector) {
            try SourceDOMContract.query(.init(html: "<p/>", selections: [.text(.init(kind: .text, key: "x", selector: "["))]))
        }
        #expect(throws: SourceHostFailure.duplicateKey) {
            try SourceDOMContract.query(.init(html: "<p/>", selections: [.text(.init(kind: .text, key: "same", selector: "p")), .text(.init(kind: .text, key: "same", selector: "p"))]))
        }
    }

    @Test func formAcceptsOnlyMatchingFieldsAndCurrentCredentialHandles() async throws {
        let (installation, policy, gate) = try environment()
        let ticket = try await gate.begin(input)
        let presentation = try await gate.beginInteraction(form(), for: ticket, policy: policy)
        let plainPassword: YingxueWire.InteractionResult = .submitted(.init(kind: .submitted,
            fields: [.publicText(.init(kind: .publicText, key: "password", value: "synthetic-secret"))]))
        await #expect(throws: SourceHostFailure.mismatchedInteraction) {
            try await gate.completeInteraction(.init(id: presentation.id, result: plainPassword), for: ticket)
        }
        let handle = try await gate.issueCredential(.init(installationID: installation), origins: [origins[0]], for: ticket)
        let accepted: YingxueWire.InteractionResult = .submitted(.init(kind: .submitted,
            fields: [.credential(.init(kind: .credential, key: "password", handle: handle))]))
        #expect(try await gate.completeInteraction(.init(id: presentation.id, result: accepted), for: ticket) == accepted)
        await #expect(throws: SourceHostFailure.missingInteraction) {
            try await gate.completeInteraction(.init(id: presentation.id, result: accepted), for: ticket)
        }
    }

    @Test func cancellingAndReplacingAnOperationRejectsLateNativeUIReplies() async throws {
        let (_, policy, gate) = try environment()
        let ticket = try await gate.begin(input)
        let display = try await gate.beginInteraction(form(), for: ticket, policy: policy)
        let second = try await gate.begin(input)
        await #expect(throws: SourceHostFailure.missingInteraction) {
            try await gate.completeInteraction(.init(id: display.id, result: .cancelled(.init(kind: .cancelled))), for: second)
        }
        _ = await gate.cancel(ticket)
        await #expect(throws: SourceOperationGate.Failure.staleOperation) {
            try await gate.completeInteraction(.init(id: display.id, result: .cancelled(.init(kind: .cancelled))), for: ticket)
        }
        let nextDisplay = try await gate.beginInteraction(form(), for: second, policy: policy)
        try await gate.replace(scriptSHA256: digest, configurationRevision: 0, sessionRevision: 1, enabled: true)
        await #expect(throws: SourceOperationGate.Failure.staleOperation) {
            try await gate.completeInteraction(.init(id: nextDisplay.id, result: .cancelled(.init(kind: .cancelled))), for: second)
        }
    }

    @Test func browserCompletionIsNotAuthenticationAndCancelledFormCanBeHandled() async throws {
        let (_, policy, gate) = try environment()
        let ticket = try await gate.begin(input)
        let presentation = try await gate.beginInteraction(.web(.init(kind: .web, title: "Login", target: .init(url: "https://fixture.invalid/login"), purpose: .signIn)), for: ticket, policy: policy)
        let done = try await gate.completeInteraction(.init(id: presentation.id, result: .completed(.init(kind: .completed))), for: ticket)
        #expect(done == .completed(.init(kind: .completed)))
        try await gate.check(ticket)
        let next = try await gate.beginInteraction(form(), for: ticket, policy: policy)
        #expect(try await gate.completeInteraction(.init(id: next.id, result: .cancelled(.init(kind: .cancelled))), for: ticket) == .cancelled(.init(kind: .cancelled)))
        let failure = YingxueWire.OperationReply.failure(.init(kind: .failure, context: ticket.call.context, operation: .authenticate,
            error: .init(code: .needsAuthentication, stage: .interaction, retryable: false)))
        #expect(try await gate.validateReply(YingxueWireCodec.encode(failure), for: ticket) == failure)
    }

    @Test func undeclaredOrWrongInstallationCannotUseHostCapabilities() async throws {
        let (installation, _, gate) = try environment()
        let ticket = try await gate.begin(input)
        let denied = try SourceHostPolicy(installationID: installation, scriptSHA256: digest, manifest: manifest(capabilities: []))
        await #expect(throws: SourceHostFailure.undeclaredCapability) {
            try await SourceHTTPContract.prepare(request(), policy: denied, gate: gate, ticket: ticket, credentials: HostSecretStore())
        }
        let wrong = try SourceHostPolicy(installationID: SourceInstallationID(), scriptSHA256: digest, manifest: manifest())
        await #expect(throws: SourceHostFailure.wrongContext) {
            try await gate.beginInteraction(form(), for: ticket, policy: wrong)
        }
    }

    @Test func hostEnvelopeRejectsReplayWrongRepliesAndLateResults() async throws {
        let (_, policy, gate) = try environment()
        let operation = try await gate.begin(input)
        let call = YingxueWire.HostCall(id: UUID().uuidString.lowercased(), context: operation.call.context,
            request: .http(.init(kind: .http, input: request())))
        let bytes = try YingxueWireCodec.encode(call)
        let host = try await gate.acceptHostCall(bytes, for: operation, policy: policy)
        await #expect(throws: SourceHostFailure.duplicateHostCall) { try await gate.acceptHostCall(bytes, for: operation, policy: policy) }
        let value = YingxueWire.HTTPResponse(status: 200, finalURL: "https://fixture.invalid/", headers: [], base64: "eA==")
        let wrong = YingxueWire.HostReply.http(.init(kind: .http, id: UUID().uuidString.lowercased(), context: operation.call.context, value: value))
        await #expect(throws: SourceHostFailure.wrongContext) { try await gate.validateHostReply(YingxueWireCodec.encode(wrong), for: host) }
        let reply = YingxueWire.HostReply.http(.init(kind: .http, id: call.id, context: operation.call.context, value: value))
        _ = try await gate.validateHostReply(YingxueWireCodec.encode(reply), for: host)
        try await gate.finish(host)
        await #expect(throws: SourceHostFailure.staleHostCall) { try await gate.validateHostReply(YingxueWireCodec.encode(reply), for: host) }
        await #expect(throws: SourceHostFailure.duplicateHostCall) { try await gate.acceptHostCall(bytes, for: operation, policy: policy) }
        let later = YingxueWire.HostCall(id: UUID().uuidString.lowercased(), context: operation.call.context, request: call.request)
        let pending = try await gate.acceptHostCall(YingxueWireCodec.encode(later), for: operation, policy: policy)
        _ = await gate.cancel(operation)
        await #expect(throws: SourceOperationGate.Failure.staleOperation) { try await gate.check(pending) }
    }

    @Test func nestedHostRepliesRedactSensitiveCredentialAndFormResults() async throws {
        let (_, _, gate) = try environment()
        let ticket = try await gate.begin(input)
        let reply = YingxueWire.HostReply.readCredential(.init(kind: .readCredential, id: UUID().uuidString.lowercased(),
            context: ticket.call.context, value: .init(value: "synthetic-secret")))
        #expect(String(reflecting: reply) == "[redacted]")
        #expect(Mirror(reflecting: reply).children.isEmpty)
        let bytes = try YingxueWireCodec.encode(reply)
        #expect(try YingxueWireCodec.decode(YingxueWire.HostReply.self, from: bytes) == reply)
        let completion = YingxueWire.InteractionCompletion(id: UUID().uuidString.lowercased(), result: .submitted(.init(kind: .submitted,
            fields: [.publicText(.init(kind: .publicText, key: "user", value: "synthetic-private-name"))])))
        #expect(String(reflecting: completion) == "[redacted]")
        #expect(Mirror(reflecting: completion).children.isEmpty)
    }

    private func literal(_ value: String) -> YingxueWire.HTTPValue { .literal(.init(kind: .literal, value: value)) }
    private func request(headers: [YingxueWire.HTTPRequestHeader] = []) -> YingxueWire.HTTPRequest {
        .init(target: .init(url: "https://fixture.invalid/"), method: .get, headers: headers, body: .none(.init(kind: .none)))
    }
    private func form() -> YingxueWire.InteractionRequest {
        .form(.init(kind: .form, title: "Sign in", fields: [.secret(.init(kind: .secret, key: "password", label: "Password", required: true))], credentialOrigins: [origins[0]]))
    }
    private func manifest(capabilities: [YingxueWire.Capability] = [.http, .dom, .browser]) -> YingxueWire.Manifest {
        .init(protocolVersion: 1, sourceID: "org.example.reader", name: "Fixture", scriptVersion: "1", referenceVersion: 1,
              stateVersion: 1, capabilities: capabilities, origins: origins, authentication: [.form, .web], publicConfiguration: [])
    }
    private func environment() throws -> (SourceInstallationID, SourceHostPolicy, SourceOperationGate) {
        let installation = SourceInstallationID()
        let policy = try SourceHostPolicy(installationID: installation, scriptSHA256: digest, manifest: manifest())
        let credentials = try SourceCredentialPolicy(installationID: installation, scriptSHA256: digest, manifest: manifest())
        let gate = try SourceOperationGate(installationID: installation, scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0, credentialPolicy: credentials)
        return (installation, policy, gate)
    }
}

private struct HostSecretStore: CredentialStore {
    func read(_ id: StoredCredentialID) async throws -> CredentialSecret? { .init(utf8: "synthetic-secret") }
    func write(_ value: CredentialSecret, for id: StoredCredentialID) async throws { throw CredentialStoreFailure.unavailable }
    func remove(_ id: StoredCredentialID) async throws { throw CredentialStoreFailure.unavailable }
    func removeAll(for installationID: SourceInstallationID) async throws { throw CredentialStoreFailure.unavailable }
}
