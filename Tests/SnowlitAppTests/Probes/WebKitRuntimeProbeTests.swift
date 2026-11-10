#if os(iOS)
import Foundation
import Testing
import WebKit
@testable import YingxueKit

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct WebKitRuntimeProbeTests {
    @Test func esModuleFetchAndDOMPreserveParagraphAndImageSemantics() async throws {
        try await FixtureScenario.withScenario { fixture in
            let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe.close() }
            try await probe.load(fixture.url("page"))
            let json = try await probe.evaluate("""
                const module = await import(moduleURL);
                return JSON.stringify(await module.probe(baseURL));
                """, arguments: ["moduleURL": fixture.url("module.mjs").absoluteString,
                                 "baseURL": fixture.base.absoluteString])
            let result = try JSONDecoder().decode(Chapter.self, from: Data(json.utf8))
            #expect(result.title == "合成章节")
            #expect(result.paragraphs.map(\.id) == ["p1", "p2", "p3"])
            #expect(result.paragraphs.map(\.text) == ["重复段落", "重复段落", "中文 👩🏽‍💻 é & text"])
            #expect(result.images.map(\.role) == ["illustration", "comment", nil])
            #expect(result.images[1].paragraph == "p2")
        }
    }

    @Test func dynamicPageHasObservableReadyContent() async throws {
        try await FixtureScenario.withScenario { fixture in
            let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe.close() }
            try await probe.load(fixture.url("dynamic"))
            try await FixtureScenario.eventually {
                try await probe.evaluate("return document.querySelector('#content').dataset.ready ?? '';") == "true"
            }
            #expect(try await probe.evaluate("return document.querySelector('#content').textContent;") == "动态合成正文")
        }
    }

    @Test func browserSelectsSameNameCookiesByPathAndHonorsHttpOnly() async throws {
        try await FixtureScenario.withScenario { fixture in
            let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe.close() }
            try await probe.load(fixture.url("page"))
            _ = try await probe.evaluate("await fetch(url); return 'issued';",
                                         arguments: ["url": fixture.url("cookies/issue").absoluteString])
            let ordinary = try await cookies(probe, at: fixture.url("cookies"))
            let nested = try await cookies(probe, at: fixture.url("nested/cookies"))
            #expect(Set(ordinary) == ["probeCookie=root", "probeCookie=scenario"])
            #expect(Set(nested) == ["probeCookie=root", "probeCookie=scenario", "probeCookie=nested"])
            try await probe.load(fixture.url("nested/cookies"))
            let visible = try await probe.evaluate("return document.cookie;")
            #expect(!visible.contains("probeCookie=nested"))
            let stored = await probe.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let sameName = stored.filter { $0.name == "probeCookie" }
            #expect(sameName.count == 3)
            #expect(Set(sameName.map(\.path)).count == 3)
        }
    }

    @Test func formSubmissionAuthenticatesSharedContextsAndLogoutRevokesTheSession() async throws {
        try await FixtureScenario.withScenario { fixture in
            let sharedStore = WKWebsiteDataStore.nonPersistent()
            let login = WebKitRuntimeProbe(dataStore: sharedStore)
            let runtime = WebKitRuntimeProbe(dataStore: sharedStore)
            let otherSource = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { login.close(); runtime.close(); otherSource.close() }
            try await login.load(fixture.url("login"))
            try await runtime.load(fixture.url("page"))
            try await otherSource.load(fixture.url("page"))
            #expect(try await responseCode(runtime, at: fixture.url("protected")) == "401")
            submitLoginForm(in: login.webView)
            // Navigation may destroy the submitting JS context before its callback.
            // The protected HTTP response is the observable success condition below.
            try await FixtureScenario.eventually {
                try await responseCode(runtime, at: fixture.url("protected")) == "200"
            }
            #expect(try await responseCode(otherSource, at: fixture.url("protected")) == "401")
            let oldCookies = await sharedStore.httpCookieStore.allCookies()
            let previousSID = try #require(oldCookies.first { $0.name == "sid" }?.value)
            #expect(try await responseCode(runtime, at: fixture.url("auth/rotate"), method: "POST") == "200")
            let newCookies = await sharedStore.httpCookieStore.allCookies()
            let currentSID = try #require(newCookies.first { $0.name == "sid" }?.value)
            #expect(currentSID != previousSID)
            #expect(try await responseCode(runtime, at: fixture.url("auth/logout"), method: "POST") == "200")
            #expect(try await responseCode(runtime, at: fixture.url("protected")) == "401")
            let afterLogout = await sharedStore.httpCookieStore.allCookies()
            #expect(!afterLogout.contains { $0.name == "sid" })
        }
    }

    @Test func explicitCookieTransferPreservesPathsAndHTTPOnlyWithoutSharingNativeSessions() async throws {
        try await FixtureScenario.withScenario { fixture in
            let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
            let native = nativeSession()
            let isolated = nativeSession()
            defer { probe.close(); native.invalidateAndCancel(); isolated.invalidateAndCancel() }
            let nativeStore = try #require(native.configuration.httpCookieStorage)
            try await probe.load(fixture.url("page"))
            #expect(try await responseCode(probe, at: fixture.url("cookies/issue")) == "200")
            #expect(try await nativeCookies(native, at: fixture.url("nested/cookies")).isEmpty)
            let exported = await probe.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            #expect(exported.count == 3)
            for cookie in exported { nativeStore.setCookie(cookie) }
            for cookie in exported {
                let copied = try #require(nativeStore.cookies?.first {
                    $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path
                })
                #expect(copied.value == cookie.value && copied.isHTTPOnly == cookie.isHTTPOnly)
            }
            #expect(Set(try await nativeCookies(native, at: fixture.url("cookies"))) ==
                    ["probeCookie=root", "probeCookie=scenario"])
            #expect(Set(try await nativeCookies(native, at: fixture.url("nested/cookies"))) ==
                    ["probeCookie=root", "probeCookie=scenario", "probeCookie=nested"])
            #expect(try await nativeCookies(isolated, at: fixture.url("nested/cookies")).isEmpty)
        }
    }

    @Test func explicitCookieTransferPropagatesSessionRotationAndLogout() async throws {
        try await FixtureScenario.withScenario { fixture in
            let dataStore = WKWebsiteDataStore.nonPersistent()
            let probe = WebKitRuntimeProbe(dataStore: dataStore)
            let native = nativeSession()
            defer { probe.close(); native.invalidateAndCancel() }
            let nativeStore = try #require(native.configuration.httpCookieStorage)
            let browserStore = dataStore.httpCookieStore
            try await probe.load(fixture.url("page"))
            #expect(try await probe.evaluate("""
                return String((await fetch(url, {method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({password: 'fixture-password'})})).status);
                """, arguments: ["url": fixture.url("auth/login").absoluteString]) == "200")
            let loggedInCookies = await browserStore.allCookies()
            let original = try #require(loggedInCookies.first { $0.name == "sid" })
            #expect(original.isHTTPOnly)
            #expect(try await nativeResponse(native, at: fixture.url("protected")).0 == 401)
            nativeStore.setCookie(original)
            #expect(try await nativeResponse(native, at: fixture.url("protected")).0 == 200)
            #expect(try await nativeResponse(native, at: fixture.url("auth/rotate"), method: "POST").0 == 200)
            let rotated = try #require(nativeStore.cookies?.first { $0.name == "sid" })
            #expect(rotated.value != original.value && rotated.isHTTPOnly)
            // Stores require explicit transfer; the browser still presents its revoked cookie.
            #expect(try await responseCode(probe, at: fixture.url("protected")) == "401")
            await browserStore.setCookie(rotated)
            #expect(try await responseCode(probe, at: fixture.url("protected")) == "200")
            #expect(try await probe.evaluate("return String(document.cookie.includes('sid='));") == "false")
            #expect(try await nativeResponse(native, at: fixture.url("auth/logout"), method: "POST").0 == 200)
            #expect(!(nativeStore.cookies ?? []).contains { $0.name == "sid" })
            #expect(try await nativeResponse(native, at: fixture.url("protected")).0 == 401)
            #expect(try await responseCode(probe, at: fixture.url("protected")) == "401")
            let revokedCookies = await browserStore.allCookies()
            #expect(revokedCookies.contains { $0.name == "sid" && $0.value == rotated.value })
            await browserStore.deleteCookie(rotated)
            let clearedCookies = await browserStore.allCookies()
            #expect(!clearedCookies.contains { $0.name == "sid" })
            // This tests explicit transfer/deletion, not a production synchronization policy.
        }
    }

    @Test(arguments: [false, true])
    func replacingSourceOrSessionRejectsLateJavaScript(sourceChanged: Bool) async throws {
        try await FixtureScenario.withScenario { fixture in
            let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe.close() }
            try await probe.load(fixture.url("page"))
            let pending = Task { try await probe.evaluate("return await (await fetch(url)).text();",
                arguments: ["url": fixture.url("wait/old").absoluteString]) }
            defer { pending.cancel() }
            try await FixtureScenario.eventually { try await fixture.status()["pending"] as? Int == 1 }
            if sourceChanged { probe.invalidateSource() } else { probe.invalidateSession() }
            let expected: ProbeResultRegistry<String>.Interruption = sourceChanged ? .sourceChanged : .sessionChanged
            await #expect(throws: expected) { try await pending.value }
            #expect(probe.results.pendingCount == 0)
            // Waiting has ended, but the server still observes the underlying fetch.
            // This explicitly prevents claiming that invalidation cancelled HTTP or JS.
            #expect(try await fixture.status()["pending"] as? Int == 1)
            _ = try await fixture.request("release/old", method: "POST")
            try await FixtureScenario.eventually { probe.results.discardedResults == 1 }
            #expect(try await probe.evaluate("return 'new operation';") == "new operation")
        }
    }

    @Test func aNeverResolvingPromiseTimesOutTheWaiterAndStillAllowsNewEvaluation() async throws {
        try await FixtureScenario.withScenario { fixture in
            let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe.close() }
            try await probe.load(fixture.url("page"))
            await #expect(throws: ProbeResultRegistry<String>.Interruption.timedOut) {
                try await probe.evaluate("return await new Promise(() => {});", timeout: .milliseconds(100))
            }
            #expect(probe.results.pendingCount == 0)
            #expect(try await probe.evaluate("return 'still responsive';") == "still responsive")
            // No assertion here claims that the old promise was collected or terminated.
        }
    }

    @Test func nativeHTTPTaskCancellationClosesTheServerRequest() async throws {
        try await FixtureScenario.withScenario { fixture in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let pending = Task { try await session.data(from: fixture.url("wait/native")) }
            defer { pending.cancel() }
            try await FixtureScenario.eventually { try await fixture.status()["pending"] as? Int == 1 }
            pending.cancel()
            do {
                _ = try await pending.value
                Issue.record("A cancelled HTTP task returned success")
            } catch {
                #expect((error as? URLError)?.code == .cancelled || error is CancellationError)
            }
            try await FixtureScenario.eventually { try await fixture.status()["aborted"] as? Int == 1 }
            let (_, response) = try await session.data(from: fixture.url("content"))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
    }

    private func responseCode(_ probe: WebKitRuntimeProbe, at url: URL,
                              method: String = "GET") async throws -> String {
        try await probe.evaluate("return String((await fetch(url, {method})).status);",
                                 arguments: ["url": url.absoluteString, "method": method])
    }

    /// Synchronous initiation: navigation may destroy the JS context before a callback.
    /// The caller awaits a protected HTTP response to establish actual authentication.
    private func submitLoginForm(in webView: WKWebView) {
        webView.evaluateJavaScript("""
            document.querySelector('input').value = 'fixture-password';
            document.querySelector('form').requestSubmit();
            """, completionHandler: nil)
    }

    private func nativeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }

    private func nativeResponse(_ session: URLSession, at url: URL,
                                method: String = "GET") async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, data)
    }

    private func nativeCookies(_ session: URLSession, at url: URL) async throws -> [String] {
        let (code, data) = try await nativeResponse(session, at: url)
        #expect(code == 200)
        return try JSONDecoder().decode(CookieEcho.self, from: data).cookies
    }

    private func cookies(_ probe: WebKitRuntimeProbe, at url: URL) async throws -> [String] {
        let result = try await probe.evaluate("return await (await fetch(url)).text();",
                                             arguments: ["url": url.absoluteString])
        return try JSONDecoder().decode(CookieEcho.self, from: Data(result.utf8)).cookies
    }

    private struct Chapter: Decodable {
        struct Paragraph: Decodable { let id: String; let text: String }
        struct Image: Decodable { let role: String?; let paragraph: String? }
        let title: String
        let paragraphs: [Paragraph]
        let images: [Image]
    }

    private struct CookieEcho: Decodable { let cookies: [String] }
}
#endif
