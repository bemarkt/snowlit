import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct SourceInspectionTests {
    @Test func acceptedPreviewPreservesOriginalBytesAndRejectsIncompleteInspection() throws {
        let fixture = try #require(WireCorpusCase.all.first { $0.name == "manifest-anonymous" })
        let bytes = Data(("\u{FEFF}/* @yingxue\r\n" + fixture.json + "\r\n*/\r\nthrow new Error('must not execute during preview');\r\n").utf8)
        let preview = try SourceImportPreview(bytes: bytes)
        let report = Data(#"{"kind":"accepted","exports":["search","book","chapters","chapter"]}"#.utf8)
        let snapshot = try preview.acceptInspection(report, digest: { input in
            #expect(input == bytes)
            return String(repeating: "a", count: 64)
        })
        #expect(snapshot.bytes == bytes)
        #expect(snapshot.metadata.sourceID == preview.header.manifest.sourceID)
        #expect(throws: SourceModuleInspection.Failure.missingExport) {
            try preview.acceptInspection(Data(#"{"kind":"accepted","exports":["search"]}"#.utf8), digest: { _ in
                Issue.record("Hashing must not run for a rejected inspection")
                return String(repeating: "a", count: 64)
            })
        }
    }

    @Test func bundledParserIsAvailableAndAcceptsOnlyCompleteTypedReports() throws {
        let program = try SourceInspectionProgram()
        #expect(program.bootstrap.contains("8.19.0"))
        #expect(program.bootstrap.contains("snowlitInspectSource"))
        let fixture = try #require(WireCorpusCase.all.first { $0.name == "manifest-anonymous" })
        let manifest = try YingxueWireCodec.decode(YingxueWire.Manifest.self, from: Data(fixture.json.utf8))
        #expect(try SourceModuleInspection.accept(Data(#"{"kind":"accepted","exports":["search","book","chapters","chapter"]}"#.utf8), manifest: manifest).count == 4)
        #expect(throws: SourceModuleInspection.Failure.missingExport) {
            try SourceModuleInspection.accept(Data(#"{"kind":"accepted","exports":["search"]}"#.utf8), manifest: manifest)
        }
        #expect(throws: WireViolation.self) {
            try SourceModuleInspection.accept(Data(#"{"kind":"accepted","exports":["search","book","chapters","chapter","readLibrary"]}"#.utf8), manifest: manifest)
        }
    }
}
