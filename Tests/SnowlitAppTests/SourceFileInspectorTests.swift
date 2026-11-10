import Foundation
import Testing
import YingxueKit
@testable import Snowlit

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct SourceFileInspectorTests {
    @Test func bundledParserInspectsWithoutExecutingSourceBodiesOrTopLevelCode() async throws {
        let module = """
            export async function search(ctx, input) { throw new Error('must not execute'); }
            export async function book(ctx, input) { return {}; }
            export async function chapters(ctx, input) { return {}; }
            export async function chapter(ctx, input) { while (true) {} }
            """
        let report = try await SourceFileInspector.inspect(module, requirements: [])
        guard case .accepted(let accepted) = try YingxueWireCodec.decode(YingxueWire.ModuleInspection.self, from: report) else {
            Issue.record("Valid module structure must be accepted without executing function bodies")
            return
        }
        #expect(Set(accepted.exports.map(\.rawValue)) == ["search", "book", "chapters", "chapter"])
        let topLevel = "throw new Error('SOURCE_EXECUTED');\n" + module
        let checked = try await SourceFileInspector.inspect(topLevel, requirements: [])
        // A parser policy may reject the statement, but evaluating it would
        // throw instead of returning a structured inspection report.
        _ = try YingxueWireCodec.decode(YingxueWire.ModuleInspection.self, from: checked)
    }

    @Test func sourceTextIsPassedAsAnArgumentAndMalformedSyntaxIsRejected() async throws {
        let report = try await SourceFileInspector.inspect("'}); throw new Error('injected'); /*", requirements: [])
        guard case .rejected = try YingxueWireCodec.decode(YingxueWire.ModuleInspection.self, from: report) else {
            Issue.record("Malformed source must be rejected as data")
            return
        }
    }
}
