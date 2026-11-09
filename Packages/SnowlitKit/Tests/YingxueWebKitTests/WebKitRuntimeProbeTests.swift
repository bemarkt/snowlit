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
            // Exercises an HTML form and cookie navigation, not a human touch/verification UI.
            _ = try await login.evaluate("""
                document.querySelector('input').value = 'fixture-password';
                setTimeout(() => document.querySelector('form').requestSubmit(), 0);
                return 'submitted';
                """)
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
