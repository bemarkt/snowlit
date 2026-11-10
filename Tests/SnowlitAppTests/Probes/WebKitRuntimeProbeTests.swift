#if os(iOS)
import Foundation
import SnowlitCore
import Testing
import WebKit
import UIKit
@testable import YingxueKit

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct WebKitRuntimeProbeTests {
    @Test func sourceWorkerCannotExecuteAnotherScriptOrInstallationTicket() async throws {
        try await withSourceWorker { worker in
            let (gate, policy) = try sourceWorkerContext()
            let manifest = String(decoding: try YingxueWireCodec.encode(policy.manifest), as: UTF8.self)
            let source = "/* @yingxue\n" + manifest + "\n*/\n" + """
                export async function search(ctx, input) { return {items: [], nextCursor: null}; }
                export async function book(ctx, input) {}
                export async function chapters(ctx, input) {}
                export async function chapter(ctx, input) {}
                """
            let snapshot = try SourceScriptSnapshot(bytes: Data(source.utf8), metadata: .init(sourceID: "org.example.worker",
                name: "Worker", scriptVersion: "2", protocolVersion: 1, referenceVersion: 2, stateVersion: 2),
                digest: { _ in String(repeating: "b", count: 64) })
            try await worker.prepare(script: snapshot)
            let input = YingxueWire.OperationInput.search(.init(kind: .search, input: .init(query: "book", cursor: nil)))
            let (wrongGate, wrongPolicy) = try sourceWorkerContext(digest: String(repeating: "c", count: 64))
            let wrong = try await wrongGate.begin(input)
            await #expect(throws: SourceHostFailure.wrongContext) {
                try await worker.invoke(wrong, gate: wrongGate, policy: wrongPolicy, host: workerConfigurationReply)
            }
            await wrongGate.cancel(wrong)
            let ticket = try await gate.begin(input)
            let reply = try await worker.invoke(ticket, gate: gate, policy: policy, host: workerConfigurationReply)
            guard case .search = reply else { throw SourceWorkerFailure.invalidResult }
            try await gate.finish(ticket)
            let (otherGate, otherPolicy) = try sourceWorkerContext()
            let other = try await otherGate.begin(input)
            await #expect(throws: SourceHostFailure.wrongContext) {
                try await worker.invoke(other, gate: otherGate, policy: otherPolicy, host: workerConfigurationReply)
            }
            await otherGate.cancel(other)
        }
    }

    @Test(arguments: ["spin", "never"])
    func sourceWorkerCancellationRevokesEnteredWorkAndFinishesCleanup(fault: String) async throws {
        try await withSourceWorker { worker in
            let (gate, policy) = try sourceWorkerContext()
            try await worker.prepare(source: """
                export async function search(ctx, input) {
                  ctx.readConfiguration({});
                  if (input.query === 'spin') { while (true) {} }
                  return await new Promise(resolve => { globalThis.pendingResolve = resolve; });
                }
                """, requiredExports: ["search"])
            var calls = 0
            let ticket = try await gate.begin(.search(.init(kind: .search, input: .init(query: fault, cursor: nil))))
            let work = Task {
                try await worker.invoke(ticket, gate: gate, policy: policy) { host in
                    calls += 1
                    return workerConfigurationReply(host)
                }
            }
            defer { work.cancel() }
            // Preflight is call one. Call two was sent by the author immediately
            // before entering its non-returning operation body.
            try await FixtureScenario.eventually { calls == 2 }
            let started = ContinuousClock.now
            work.cancel()
            await #expect(throws: CancellationError.self) { try await work.value }
            #expect(started.duration(to: .now) < .seconds(3))
            #expect(await gate.pendingCount == 0)
            try await worker.close()
        }
    }

    @Test func sourceWorkerRejectsInvalidWireResultsAndGlobalReadySpoofing() async throws {
        try await withSourceWorker { worker in
            await #expect(throws: SourceWorkerFailure.invalidResult) {
                try await worker.prepare(source: "postMessage({kind: 'ready'}); throw new Error('private'); export async function search(ctx, input) {}",
                    requiredExports: ["search"])
            }
        }
        try await withSourceWorker { worker in
            let (gate, policy) = try sourceWorkerContext()
            try await worker.prepare(source: "export async function search(ctx, input) { return {items: [], nextCursor: ''}; }",
                requiredExports: ["search"])
            let ticket = try await gate.begin(.search(.init(kind: .search, input: .init(query: "bad", cursor: nil))))
            await #expect(throws: WireViolation.self) {
                try await worker.invoke(ticket, gate: gate, policy: policy, host: workerConfigurationReply)
            }
            #expect(await gate.pendingCount == 0)
        }
    }

    @Test(arguments: [false, true])
    func sourceWorkerExecutesCandidateMigrationsAndRejectsOmissions(omitMapping: Bool) async throws {
        try await withSourceWorker { worker in
            let installation = SourceInstallationID()
            let oldMetadata = try SourceScriptMetadata(sourceID: "org.example.worker", name: "Worker", scriptVersion: "1",
                protocolVersion: 1, referenceVersion: 1, stateVersion: 1)
            let metadata = try SourceScriptMetadata(sourceID: "org.example.worker", name: "Worker", scriptVersion: "2",
                protocolVersion: 1, referenceVersion: 2, stateVersion: 2)
            let installed = try SourceInstallationSnapshot(id: installation, importID: UUID(), scriptSHA256: String(repeating: "a", count: 64),
                metadata: oldMetadata, revision: 1, state: .enabled, configuration: [], allowsCredentialRead: false,
                websiteSessionID: UUID(), pendingCleanup: nil)
            let candidate = try SourceImportRecord(scriptSHA256: String(repeating: "b", count: 64),
                inspectionContractSHA256: YingxueWire.schemaSHA256, fileName: "worker.js", importedAt: Date())
            let reference = try SourceBookReference(installationID: installation, referenceVersion: 1, key: "book")
            let chapter = try ChapterReference(book: reference, key: "chapter")
            let snapshot = try SourceUpdateSnapshot(installation: installed, candidate: candidate, candidateMetadata: metadata,
                inventoryRevision: 0, books: [.init(book: .init(id: LocalBookID(), reference: reference, title: "Book", author: nil),
                    references: [reference], chapterReferences: [chapter], catalog: nil, checkpoint: nil)],
                currentState: .init(stateVersion: 1, revision: 4, entries: [.init(key: "public", value: "old")]),
                targetState: .init(stateVersion: 2, revision: 0, entries: []), referenceHistory: [])
            let plan = try SourceUpdateMigrationPlan(prepared: snapshot)
            let (gate, policy) = try sourceWorkerContext(installation: installation, digest: candidate.scriptSHA256)
            try await worker.prepare(source: """
                export async function migrateReferences(ctx, input) {
                  return {fromVersion: input.fromVersion, toVersion: input.toVersion,
                    books: \(omitMapping ? "[]" : "input.books.map(book => ({kind: 'mapped', old: book.book, new: {key: 'new-book'}, chapters: book.chapters.map(key => ({kind: 'mapped', oldKey: key, newKey: 'new-' + key}))}))")};
                }
                export async function migrateState(ctx, input) {
                  return {fromVersion: input.fromVersion, toVersion: input.toVersion,
                    expectedRevision: input.snapshot.revision, entries: [{key: 'public', value: 'new'}]};
                }
                """, requiredExports: ["migrateReferences", "migrateState"])
            if omitMapping {
                await #expect(throws: SourceMigrationFailure.incompleteMapping) {
                    try await worker.migrate(plan, gate: gate, policy: policy, host: workerConfigurationReply)
                }
            } else {
                let values = try await worker.migrate(plan, gate: gate, policy: policy, host: workerConfigurationReply)
                #expect(values.references?.books.count == 1)
                #expect(values.state?.stateVersion == 2 && values.state?.revision == 0)
                #expect(values.state?.entries.first?.value == "new")
            }
            #expect(await gate.pendingCount == 0)
        }
    }

    @Test func isolatedModuleWorkerPreservesDataAndCannotFetchOutsideItsNativeHost() async throws {
        try await FixtureScenario.withScenario { fixture in
            let (status, bytes) = try await fixture.request("worker-source.mjs")
            try #require(status == 200)
            try await WorkerExperiment.withExperiment { worker in
            try await worker.start(source: String(decoding: bytes, as: UTF8.self))
            try await worker.send(["mode": "normal", "text": "中文 🧪", "token": "normal"])
            try await FixtureScenario.eventually { try await worker.value("returned") == "true" }
            #expect(try await worker.value("result.echo") == "中文 🧪")
            #expect(try await worker.value("result.sum") == "6")
            #expect(try await worker.value("workerConstructors") == "undefined/undefined")
            try await worker.stop()

            try await worker.start(source: String(decoding: bytes, as: UTF8.self))
            try await worker.send(["mode": "network", "url": fixture.url("worker-forbidden").absoluteString, "token": "network"])
            try await FixtureScenario.eventually { try await worker.value("returned") == "true" }
            #expect(try await worker.value("result.blocked") == "true")
            let observation = try await fixture.status()
            let requests = try #require(observation["requests"] as? [[String: String]])
            #expect(!requests.contains { $0["path"] == "worker-forbidden" })
            try await worker.stop()
            }
        }
    }

    @Test func workerTerminationEndsEnteredSpinAndNeverWorkAndAllowsFreshModules() async throws {
        try await FixtureScenario.withScenario { fixture in
            let (status, bytes) = try await fixture.request("worker-source.mjs")
            try #require(status == 200)
            let source = String(decoding: bytes, as: UTF8.self)
            try await WorkerExperiment.withExperiment { worker in
            for mode in ["spin", "never"] {
                for repetition in 1...3 {
                    let token = "\(mode)-\(repetition)"
                    try await worker.start(source: source)
                    try await worker.send(["mode": mode, "token": token])
                    try await FixtureScenario.eventually { try await worker.value("entered") == token }
                    if mode == "spin" {
                        try await FixtureScenario.eventually { try await worker.value("pulses > 0") == "true" }
                    }
                    #expect(try await worker.value("returned") == "false")
                    let started = ContinuousClock.now
                    try await worker.stop()
                    let stopDuration = started.duration(to: .now)
                    #expect(stopDuration < .seconds(1))
                    // Already queued parent messages may precede termination.
                    // Observe a settled count, then require continued quiescence.
                    try await Task.sleep(for: .milliseconds(100))
                    let settled = try await worker.value("pulses")
                    try await Task.sleep(for: .milliseconds(500))
                    #expect(try await worker.value("pulses") == settled)
                    #expect(try await worker.value("returned") == "false")
                    try await worker.start(source: source)
                    try await worker.send(["mode": "normal", "text": token, "token": "replacement"])
                    try await FixtureScenario.eventually { try await worker.value("returned") == "true" }
                    #expect(try await worker.value("result.echo") == token)
                    try await worker.stop()
                    print("WorkerTerminationObservation fault=\(mode) repetition=\(repetition) stopDuration=\(stopDuration) latePulses=0 replacement=true")
                }
            }
            }
        }
    }

    @Test func moduleInspectionParsesSharedCorpusWithoutExecutingSource() async throws {
        try await FixtureScenario.withScenario { fixture in
            let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe.close() }
            try await probe.load(fixture.url("page"))
            let program = try SourceInspectionProgram()
            #expect(try await probe.evaluate(program.bootstrap + "\nreturn 'parser-ready';") == "parser-ready")
            for sample in ModuleCorpusCase.all {
                let json = try await probe.evaluate(program.evaluationBody,
                    arguments: ["source": sample.source, "requirements": sample.requirements])
                let report = try YingxueWireCodec.decode(YingxueWire.ModuleInspection.self, from: Data(json.utf8))
                switch report {
                case .accepted:
                    #expect(sample.reason == nil, "Unexpected acceptance: \(sample.name)")
                case .rejected(let failure):
                    #expect(failure.reason.rawValue == sample.reason, "Unexpected rejection: \(sample.name)")
                }
            }
        }
    }

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
            #expect(probe.webView.window == nil)
            #expect(probe.webView.configuration.preferences.inactiveSchedulingPolicy == .none)
            try await probe.load(fixture.url("dynamic"))
            try await FixtureScenario.eventually {
                try await probe.evaluate("return document.querySelector('#content').dataset.ready ?? '';") == "true"
            }
            #expect(try await probe.evaluate("return document.querySelector('#content').textContent;") == "动态合成正文")
        }
    }

    @Test func pageContractExtractsInAnIsolatedWorldAndRejectsOldNavigationCallbacks() async throws {
        try await FixtureScenario.withScenario { fixture in
            let (gate, policy) = try pageEnvironment()
            let operation = try await gate.begin(.search(.init(kind: .search, input: .init(query: "fixture", cursor: nil))))
            let page = try await gate.createPage(for: operation, policy: policy)
            let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe.close() }
            let first = try await gate.beginNavigation(.init(url: fixture.url("dynamic").absoluteString), page: page)
            try await probe.load(first.url)
            let opened = try await gate.finishNavigation(first, finalURL: #require(probe.webView.url))
            try await FixtureScenario.eventually {
                try await probe.evaluate("return document.querySelector('#content').dataset.ready ?? '';") == "true"
            }
            _ = try await probe.evaluate("globalThis.siteOnlyValue = 'site'; return 'set';")
            let input = "\"; throw new Error('data-is-not-code'); //"
            let request = YingxueWire.EvaluatePage(page: opened.page,
                script: "return {text: document.querySelector('#content').textContent, echo: input, siteGlobal: typeof siteOnlyValue};",
                inputJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self))
            let json = try await evaluatePage(request, probe: probe, gate: gate, operation: operation)
            let content = try JSONDecoder().decode([String: String].self, from: Data(json.json.utf8))
            #expect(content == ["text": "动态合成正文", "echo": input, "siteGlobal": "undefined"])

            let delayed = YingxueWire.EvaluatePage(page: opened.page, script: "await fetch(input); return {text: 'old'};",
                inputJSON: String(decoding: try JSONEncoder().encode(fixture.url("wait/page-old").absoluteString), as: UTF8.self))
            let pending = Task { try await evaluatePage(delayed, probe: probe, gate: gate, operation: operation) }
            defer { pending.cancel() }
            try await FixtureScenario.eventually { try await (fixture.status()["pending"] as? Int) == 1 }
            let next = try await gate.beginNavigation(.init(url: fixture.url("page").absoluteString), page: page)
            #expect(try await fixture.request("release/page-old", method: "POST").0 == 200)
            await #expect(throws: SourcePageFailure.staleNavigation) { try await pending.value }
            try await probe.load(next.url)
            let renewed = try await gate.finishNavigation(next, finalURL: #require(probe.webView.url))
            let fresh = try await evaluatePage(.init(page: renewed.page, script: "return document.querySelector('main').textContent;", inputJSON: "null"),
                probe: probe, gate: gate, operation: operation)
            #expect(fresh.json == "\"Ready\"")
            #expect(try await gate.closePage(.init(id: page.id), for: operation).closed)
            try await gate.finish(operation)
        }
    }

    @Test func pageContractRejectsNonJSONAndCancelledNativeExtraction() async throws {
        try await FixtureScenario.withScenario { fixture in
            let (gate, policy) = try pageEnvironment()
            let operation = try await gate.begin(.search(.init(kind: .search, input: .init(query: "fixture", cursor: nil))))
            let page = try await gate.createPage(for: operation, policy: policy)
            let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
            defer { probe.close() }
            let navigation = try await gate.beginNavigation(.init(url: fixture.url("page").absoluteString), page: page)
            try await probe.load(navigation.url)
            let opened = try await gate.finishNavigation(navigation, finalURL: #require(probe.webView.url))
            for script in ["return undefined;", "return {value: NaN};", "return [() => 1];", "const a = {}; a.self = a; return a;"] {
                await #expect(throws: (any Error).self) {
                    try await evaluatePage(.init(page: opened.page, script: script, inputJSON: "null"), probe: probe, gate: gate, operation: operation)
                }
            }
            let request = YingxueWire.EvaluatePage(page: opened.page, script: "await fetch(input); return 'late';",
                inputJSON: String(decoding: try JSONEncoder().encode(fixture.url("wait/page-cancel").absoluteString), as: UTF8.self))
            let pending = Task { try await evaluatePage(request, probe: probe, gate: gate, operation: operation) }
            defer { pending.cancel() }
            try await FixtureScenario.eventually { try await (fixture.status()["pending"] as? Int) == 1 }
            #expect(await gate.cancel(operation))
            #expect(try await fixture.request("release/page-cancel", method: "POST").0 == 200)
            await #expect(throws: SourceOperationGate.Failure.staleOperation) { try await pending.value }
            #expect(await gate.pageIDs(for: operation).isEmpty)
            // The owner still closes WebKit; registry cancellation is not JS termination.
        }
    }

    private func pageEnvironment() throws -> (SourceOperationGate, SourceHostPolicy) {
        let installation = SourceInstallationID(), digest = String(repeating: "a", count: 64)
        let manifest = YingxueWire.Manifest(protocolVersion: 1, sourceID: "org.example.pages", name: "Fixture", scriptVersion: "1", referenceVersion: 1,
            stateVersion: 1, capabilities: [.browser], origins: [.init(scheme: .http, host: "127.0.0.1", port: 18731)], authentication: [], publicConfiguration: [])
        return (try .init(installationID: installation, scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0),
                try .init(installationID: installation, scriptSHA256: digest, manifest: manifest))
    }

    private func evaluatePage(_ request: YingxueWire.EvaluatePage, probe: WebKitRuntimeProbe,
                              gate: SourceOperationGate, operation: SourceOperationGate.Ticket) async throws -> YingxueWire.PageEvaluation {
        try await gate.preparePageEvaluation(request, for: operation)
        let json = try await probe.evaluate(SourcePageProgram.body(for: request), arguments: ["inputJSON": request.inputJSON],
            contentWorld: .world(name: "Snowlit.PageProbe"))
        return try await gate.acceptPageEvaluation(YingxueWireCodec.encode(YingxueWire.PageEvaluation(json: json)), page: request.page, for: operation)
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

    @Test func hostOnlyCookiesStayOnTheirOriginAndRejectAnUnmatchedDomain() async throws {
        try await FixtureScenario.withScenario { fixture in
            var components = try #require(URLComponents(url: fixture.base, resolvingAgainstBaseURL: false))
            components.host = "localhost"
            let namedBase = try #require(components.url)
            let store = WKWebsiteDataStore.nonPersistent()
            let address = WebKitRuntimeProbe(dataStore: store)
            let named = WebKitRuntimeProbe(dataStore: store)
            let native = nativeSession()
            defer { address.close(); named.close(); native.invalidateAndCancel() }
            try await address.load(fixture.url("page"))
            try await named.load(namedBase.appendingPathComponent("page"))
            #expect(try await responseCode(address, at: fixture.url("cookies/host-issue")) == "200")
            #expect(try await cookies(named, at: namedBase.appendingPathComponent("cookies")).isEmpty)
            #expect(try await responseCode(named, at: namedBase.appendingPathComponent("cookies/host-issue")) == "200")
            #expect(try await cookies(address, at: fixture.url("cookies")) == ["probeHost=127.0.0.1"])
            #expect(try await cookies(named, at: namedBase.appendingPathComponent("cookies")) == ["probeHost=localhost"])
            let exported = await store.httpCookieStore.allCookies()
            #expect(exported.count == 2)
            #expect(exported.allSatisfy { $0.name == "probeHost" && $0.isHTTPOnly })
            #expect(Set(exported.map(\.domain)).count == 2)
            let nativeStore = try #require(native.configuration.httpCookieStorage)
            for cookie in exported { nativeStore.setCookie(cookie) }
            #expect(try await nativeCookies(native, at: fixture.url("cookies")) == ["probeHost=127.0.0.1"])
            #expect(try await nativeCookies(native, at: namedBase.appendingPathComponent("cookies")) == ["probeHost=localhost"])
            #expect(try await responseCode(address, at: fixture.url("cookies/host-clear")) == "200")
            #expect(try await cookies(address, at: fixture.url("cookies")).isEmpty)
            #expect(try await cookies(named, at: namedBase.appendingPathComponent("cookies")) == ["probeHost=localhost"])
            let remaining = await store.httpCookieStore.allCookies()
            #expect(remaining.count == 1 && remaining.first?.value == "localhost")
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

/// A dedicated Worker inside a window-attached WebKit document. It is isolated
/// feasibility code, with no product credentials, database or host capabilities.
@MainActor
private final class WorkerExperiment {
    private let probe = WebKitRuntimeProbe(dataStore: .nonPersistent())
    private let window: UIWindow
    private weak var previousWindow: UIWindow?
    private var prepared = false

    private init() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first { $0.isKeyWindow }
        window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        probe.webView.frame = window.bounds
        probe.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(probe.webView)
        window.makeKeyAndVisible()
    }

    static func withExperiment(_ body: @MainActor (WorkerExperiment) async throws -> Void) async throws {
        let experiment = try WorkerExperiment()
        defer {
            experiment.probe.close()
            experiment.window.isHidden = true
            experiment.previousWindow?.makeKeyAndVisible()
        }
        do {
            try await experiment.probe.loadHTML("""
                <!doctype html><meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; script-src blob:; worker-src blob:; connect-src 'none'">
                <title>Isolated worker experiment</title>
                """)
            experiment.prepared = true
            try await body(experiment)
            try await experiment.stop()
        } catch {
            if experiment.prepared {
                do { try await experiment.stop() }
                catch { Issue.record(error, "Worker experiment cleanup failed") }
            }
            throw error
        }
    }

    func start(source: String) async throws {
        _ = try await probe.evaluate("""
            const moduleURL = URL.createObjectURL(new Blob([source], {type: 'text/javascript'}));
            const bootstrap = `
              for (const name of ['Worker', 'SharedWorker']) {
                Object.defineProperty(globalThis, name, {value: undefined, writable: false, configurable: false});
              }
              const {execute, constructorsAtLoad} = await import(${JSON.stringify(moduleURL)});
              const send = postMessage.bind(globalThis);
              onmessage = async ({data}) => {
                send({kind: 'entered', token: data.token});
                try { send({kind: 'result', value: await execute(data, send)}); }
                catch { send({kind: 'failed'}); }
              };
              send({kind: 'ready', constructors: constructorsAtLoad});
            `;
            const workerURL = URL.createObjectURL(new Blob([bootstrap], {type: 'text/javascript'}));
            const state = {worker: new Worker(workerURL, {type: 'module'}), moduleURL, workerURL,
              ready: false, entered: '', pulses: 0, returned: false, result: null, error: false};
            state.worker.onmessage = ({data}) => {
              if (data.kind === 'ready') { state.ready = true; state.workerConstructors = data.constructors; }
              else if (data.kind === 'entered') state.entered = data.token;
              else if (data.kind === 'pulse') state.pulses++;
              else if (data.kind === 'result') { state.result = data.value; state.returned = true; }
              else state.error = true;
            };
            state.worker.onerror = event => { event.preventDefault(); state.error = true; };
            globalThis.workerExperiment = state;
            return 'started';
            """, arguments: ["source": source])
        try await FixtureScenario.eventually { try await value("ready") == "true" }
    }

    func send(_ input: [String: String]) async throws {
        let json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        _ = try await probe.evaluate("workerExperiment.worker.postMessage(JSON.parse(input)); return 'sent';",
            arguments: ["input": json])
    }

    // Expressions are fixed test observations, never supplied by source modules.
    func value(_ expression: String) async throws -> String {
        try await probe.evaluate("if (workerExperiment.error) throw new Error('Worker failed'); return String(workerExperiment.\(expression));")
    }

    func stop() async throws {
        _ = try await probe.evaluate("""
            const state = globalThis.workerExperiment;
            if (state?.worker) {
              state.worker.terminate(); state.worker = null;
              URL.revokeObjectURL(state.workerURL); URL.revokeObjectURL(state.moduleURL);
            }
            return 'terminated';
            """, timeout: .seconds(1))
    }
}
@MainActor
private func withSourceWorker(_ body: @MainActor (SourceWorkerSession) async throws -> Void) async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    let worker = SourceWorkerSession(program: try .init())
    window.rootViewController = controller
    worker.webView.frame = window.bounds
    worker.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    controller.view.addSubview(worker.webView)
    window.makeKeyAndVisible()
    defer { window.isHidden = true; previous?.makeKeyAndVisible() }
    do { try await body(worker); try await worker.close() }
    catch {
        do { try await worker.close() } catch { Issue.record(error, "Source worker cleanup failed") }
        throw error
    }
}

@MainActor
private func sourceWorkerContext(installation: SourceInstallationID = .init(), digest: String = String(repeating: "b", count: 64)) throws -> (SourceOperationGate, SourceHostPolicy) {
    let manifest = YingxueWire.Manifest(protocolVersion: 1, sourceID: "org.example.worker", name: "Worker", scriptVersion: "2",
        referenceVersion: 2, stateVersion: 2, capabilities: [], origins: [], authentication: [], publicConfiguration: [])
    return (try .init(installationID: installation, scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0),
            try .init(installationID: installation, scriptSHA256: digest, manifest: manifest))
}

@MainActor
private func workerConfigurationReply(_ host: SourceOperationGate.HostTicket) -> YingxueWire.HostReply {
    .readConfiguration(.init(kind: .readConfiguration, id: host.call.id, context: host.call.context,
        value: .init(revision: host.call.context.configurationRevision, values: [])))
}

#endif
