import Foundation
import Testing
@testable import YingxueKit

struct SourceInspectionTests {
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
