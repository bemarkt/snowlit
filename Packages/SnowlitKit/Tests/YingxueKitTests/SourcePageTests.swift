import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct SourcePageTests {
    private let digest = String(repeating: "a", count: 64)
    private let url = URL(string: "https://fixture.invalid/dynamic")!
    private var input: YingxueWire.OperationInput { .search(.init(kind: .search, input: .init(query: "book", cursor: nil))) }

    @Test func onlyTheOwningOperationCanUseOrCloseAReadyPage() async throws {
        let (gate, policy) = try environment()
        let first = try await gate.begin(input), second = try await gate.begin(input)
        let page = try await gate.createPage(for: first, policy: policy)
        let navigation = try await gate.beginNavigation(.init(url: url.absoluteString), page: page)
        let opened = try await gate.finishNavigation(navigation, finalURL: url)
        try await gate.checkPage(opened.page, for: first)
        await #expect(throws: SourcePageFailure.missingPage) { try await gate.checkPage(opened.page, for: second) }
        #expect(try await !gate.closePage(.init(id: page.id), for: second).closed)
        #expect(await gate.pageIDs(for: first) == [page.id])
        #expect(try await gate.closePage(.init(id: page.id), for: first).closed)
        #expect(try await !gate.closePage(.init(id: page.id), for: first).closed)
        await #expect(throws: SourcePageFailure.missingPage) { try await gate.checkPage(opened.page, for: first) }
        await #expect(throws: SourcePageFailure.missingPage) { try await gate.finishNavigation(navigation, finalURL: url) }
    }

    @Test func navigationInvalidatesOldExtractionAndRejectsAnOutOfOrderLoad() async throws {
        let (gate, policy) = try environment()
        let operation = try await gate.begin(input)
        let page = try await gate.createPage(for: operation, policy: policy)
        let first = try await gate.beginNavigation(.init(url: url.absoluteString), page: page)
        let opened = try await gate.finishNavigation(first, finalURL: url)
        let reply = try YingxueWireCodec.encode(YingxueWire.PageEvaluation(json: "{\"text\":\"old\"}"))
        let next = try await gate.beginNavigation(.init(url: "/next", baseURL: url.absoluteString), page: page)
        await #expect(throws: SourcePageFailure.staleNavigation) {
            try await gate.acceptPageEvaluation(reply, page: opened.page, for: operation)
        }
        await #expect(throws: SourcePageFailure.staleNavigation) { try await gate.finishNavigation(first, finalURL: url) }
        let pending = YingxueWire.PageHandle(id: page.id, navigationID: next.id.uuidString.lowercased())
        await #expect(throws: SourcePageFailure.notReady) { try await gate.checkPage(pending, for: operation) }
        let ready = try await gate.finishNavigation(next, finalURL: next.url)
        #expect(ready.page != opened.page)
        #expect(try await gate.acceptPageEvaluation(reply, page: ready.page, for: operation).json == "{\"text\":\"old\"}")
    }

    @Test func originsAreCheckedAtStartAndFinishWithoutLosingThePreviousRegistration() async throws {
        let (gate, policy) = try environment()
        let operation = try await gate.begin(input)
        let page = try await gate.createPage(for: operation, policy: policy)
        let navigation = try await gate.beginNavigation(.init(url: url.absoluteString), page: page)
        let opened = try await gate.finishNavigation(navigation, finalURL: url)
        await #expect(throws: SourceHostFailure.originDenied) {
            try await gate.beginNavigation(.init(url: "https://outside.invalid/"), page: page)
        }
        try await gate.checkPage(opened.page, for: operation)
        let next = try await gate.beginNavigation(.init(url: url.absoluteString), page: page)
        await #expect(throws: SourceHostFailure.originDenied) {
            try await gate.finishNavigation(next, finalURL: URL(string: "https://outside.invalid/")!)
        }
        let pending = YingxueWire.PageHandle(id: page.id, navigationID: next.id.uuidString.lowercased())
        await #expect(throws: SourcePageFailure.notReady) { try await gate.checkPage(pending, for: operation) }
        #expect(try await gate.closePage(.init(id: opened.page.id), for: operation).closed)
    }

    @Test func pageCapabilityAndInstallationAreCheckedBeforeRegistration() async throws {
        let (gate, _) = try environment()
        let operation = try await gate.begin(input)
        let installation = SourceInstallationID(UUID(uuidString: operation.call.context.installationID)!)
        let denied = try SourceHostPolicy(installationID: installation, scriptSHA256: digest, manifest: manifest(capabilities: []))
        await #expect(throws: SourceHostFailure.undeclaredCapability) { try await gate.createPage(for: operation, policy: denied) }
        let wrong = try SourceHostPolicy(installationID: .init(), scriptSHA256: digest, manifest: manifest())
        await #expect(throws: SourceHostFailure.wrongContext) { try await gate.createPage(for: operation, policy: wrong) }
        #expect(await gate.pageIDs(for: operation).isEmpty)
    }

    @Test func cancellationFinishReplacementAndCloseRejectLatePages() async throws {
        for action in 0..<4 {
            let (gate, policy) = try environment()
            let operation = try await gate.begin(input), other = try await gate.begin(input)
            let page = try await gate.createPage(for: operation, policy: policy)
            let survivor = try await gate.createPage(for: other, policy: policy)
            let navigation = try await gate.beginNavigation(.init(url: url.absoluteString), page: page)
            let opened = try await gate.finishNavigation(navigation, finalURL: url)
            switch action {
            case 0: #expect(await gate.cancel(operation))
            case 1: try await gate.finish(operation)
            case 2: try await gate.replace(scriptSHA256: digest, configurationRevision: 0, sessionRevision: 1, enabled: true)
            default: await gate.close()
            }
            #expect(await gate.pageIDs(for: operation).isEmpty)
            if action < 2 { #expect(await gate.pageIDs(for: other) == [survivor.id]) }
            else { #expect(await gate.pageIDs(for: other).isEmpty) }
            await #expect(throws: (any Error).self) { try await gate.finishNavigation(navigation, finalURL: url) }
            await #expect(throws: (any Error).self) { try await gate.checkPage(opened.page, for: operation) }
        }
    }

    @Test func extractionValidatesNestedJSONAndRedactsItsOutput() async throws {
        let (gate, policy) = try environment()
        let operation = try await gate.begin(input)
        let page = try await gate.createPage(for: operation, policy: policy)
        let navigation = try await gate.beginNavigation(.init(url: url.absoluteString), page: page)
        let ready = try await gate.finishNavigation(navigation, finalURL: url)
        for json in ["null", "true", "42", "\"中文\"", "[]", "{\"text\":\"private-content\"}"] {
            let request = YingxueWire.EvaluatePage(page: ready.page, script: "return input;", inputJSON: json)
            try await gate.preparePageEvaluation(request, for: operation)
            let result = try await gate.acceptPageEvaluation(YingxueWireCodec.encode(YingxueWire.PageEvaluation(json: json)), page: ready.page, for: operation)
            #expect(result.json == json)
            #expect(!String(reflecting: result).contains("private-content"))
        }
        for json in ["undefined", "NaN", "{", "{\"x\":1,\"x\":2}", "[{\"x\":1,\"\\u0078\":2}]"] {
            await #expect(throws: WireViolation.self) {
                try await gate.preparePageEvaluation(.init(page: ready.page, script: "return input;", inputJSON: json), for: operation)
            }
            await #expect(throws: WireViolation.self) {
                try await gate.acceptPageEvaluation(YingxueWireCodec.encode(YingxueWire.PageEvaluation(json: json)), page: ready.page, for: operation)
            }
        }
    }

    private func manifest(capabilities: [YingxueWire.Capability] = [.browser]) -> YingxueWire.Manifest {
        .init(protocolVersion: 1, sourceID: "org.example.pages", name: "Fixture", scriptVersion: "1", referenceVersion: 1,
              stateVersion: 1, capabilities: capabilities, origins: [.init(scheme: .https, host: "fixture.invalid")], authentication: [], publicConfiguration: [])
    }
    private func environment() throws -> (SourceOperationGate, SourceHostPolicy) {
        let installation = SourceInstallationID()
        return (try .init(installationID: installation, scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0),
                try .init(installationID: installation, scriptSHA256: digest, manifest: manifest()))
    }
}
