import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct WireContractTests {
    @Test(arguments: WireCorpusCase.all)
    func sharedCorpus(_ fixture: WireCorpusCase) throws {
        let bytes = Data(fixture.json.utf8)
        if fixture.valid {
            try YingxueWireCodec.validate(bytes, as: fixture.type)
            switch fixture.type {
            case "Manifest": _ = try YingxueWireCodec.decode(YingxueWire.Manifest.self, from: bytes)
            case "SearchPage": _ = try YingxueWireCodec.decode(YingxueWire.SearchPage.self, from: bytes)
            case "ChaptersPage": _ = try YingxueWireCodec.decode(YingxueWire.ChaptersPage.self, from: bytes)
            case "ChapterResult": _ = try YingxueWireCodec.decode(YingxueWire.ChapterResult.self, from: bytes)
            case "BookReference": _ = try YingxueWireCodec.decode(YingxueWire.BookReference.self, from: bytes)
            case "OperationCall": _ = try YingxueWireCodec.decode(YingxueWire.OperationCall.self, from: bytes)
            case "OperationReply": _ = try YingxueWireCodec.decode(YingxueWire.OperationReply.self, from: bytes)
            case "CredentialHandle": _ = try YingxueWireCodec.decode(YingxueWire.CredentialHandle.self, from: bytes)
            case "CredentialReadRequest": _ = try YingxueWireCodec.decode(YingxueWire.CredentialReadRequest.self, from: bytes)
            case "CredentialReadResult": _ = try YingxueWireCodec.decode(YingxueWire.CredentialReadResult.self, from: bytes)
            case "HTTPRequest": _ = try YingxueWireCodec.decode(YingxueWire.HTTPRequest.self, from: bytes)
            case "HTTPResponse": _ = try YingxueWireCodec.decode(YingxueWire.HTTPResponse.self, from: bytes)
            case "DecodeTextRequest": _ = try YingxueWireCodec.decode(YingxueWire.DecodeTextRequest.self, from: bytes)
            case "DOMQuery": _ = try YingxueWireCodec.decode(YingxueWire.DOMQuery.self, from: bytes)
            case "DOMResult": _ = try YingxueWireCodec.decode(YingxueWire.DOMResult.self, from: bytes)
            case "InteractionRequest": _ = try YingxueWireCodec.decode(YingxueWire.InteractionRequest.self, from: bytes)
            case "InteractionResult": _ = try YingxueWireCodec.decode(YingxueWire.InteractionResult.self, from: bytes)
            case "AuthenticationResult": _ = try YingxueWireCodec.decode(YingxueWire.AuthenticationResult.self, from: bytes)
            case "ReferenceMigrationInput": _ = try YingxueWireCodec.decode(YingxueWire.ReferenceMigrationInput.self, from: bytes)
            case "ReferenceMigrationResult": _ = try YingxueWireCodec.decode(YingxueWire.ReferenceMigrationResult.self, from: bytes)
            case "PublicStateSnapshot": _ = try YingxueWireCodec.decode(YingxueWire.PublicStateSnapshot.self, from: bytes)
            case "WritePublicState": _ = try YingxueWireCodec.decode(YingxueWire.WritePublicState.self, from: bytes)
            case "PublicStateWriteResult": _ = try YingxueWireCodec.decode(YingxueWire.PublicStateWriteResult.self, from: bytes)
            case "StateMigrationInput": _ = try YingxueWireCodec.decode(YingxueWire.StateMigrationInput.self, from: bytes)
            case "StateMigrationResult": _ = try YingxueWireCodec.decode(YingxueWire.StateMigrationResult.self, from: bytes)
            case "OpenPage": _ = try YingxueWireCodec.decode(YingxueWire.OpenPage.self, from: bytes)
            case "OpenedPage": _ = try YingxueWireCodec.decode(YingxueWire.OpenedPage.self, from: bytes)
            case "EvaluatePage": _ = try YingxueWireCodec.decode(YingxueWire.EvaluatePage.self, from: bytes)
            case "PageEvaluation": _ = try YingxueWireCodec.decode(YingxueWire.PageEvaluation.self, from: bytes)
            case "ClosePage": _ = try YingxueWireCodec.decode(YingxueWire.ClosePage.self, from: bytes)
            case "ClosedPage": _ = try YingxueWireCodec.decode(YingxueWire.ClosedPage.self, from: bytes)
            default: Issue.record("Add typed decoding for this valid corpus model")
            }
        } else {
            #expect(throws: (any Error).self, "Unexpected acceptance: \(fixture.name)") {
                try YingxueWireCodec.validate(bytes, as: fixture.type)
            }
        }
    }

    @Test func nullablePageEndIsEncodedAsExplicitNullAndRoundTrips() throws {
        let page = YingxueWire.SearchPage(items: [], nextCursor: nil)
        let bytes = try YingxueWireCodec.encode(page)
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"items":[],"nextCursor":null}"#)
        #expect(try YingxueWireCodec.decode(YingxueWire.SearchPage.self, from: bytes) == page)
        #expect(throws: WireViolation.self) { try YingxueWireCodec.decode(YingxueWire.SearchPage.self, from: Data(#"{"items":[]}"#.utf8)) }
        #expect(throws: WireViolation.self) { try YingxueWireCodec.encode(YingxueWire.SearchPage(items: [], nextCursor: "")) }
    }

    @Test func typedVariantsRoundTripAndForeignChapterIsRejectedBeforeNormalization() async throws {
        let expected = try SnowlitCore.ChapterReference(book: SourceBookReference(installationID: SourceInstallationID(), referenceVersion: 1, key: "b"), key: "c")
        for name in ["chapter-text", "chapter-html-with-comment-and-image", "chapter-structured"] {
            let fixture = try #require(WireCorpusCase.all.first { $0.name == name })
            let result = try YingxueWireCodec.decode(YingxueWire.ChapterResult.self, from: Data(fixture.json.utf8))
            let encoded = try YingxueWireCodec.encode(result)
            #expect(try YingxueWireCodec.decode(YingxueWire.ChapterResult.self, from: encoded) == result)
            let normalized = try await ChapterWireAdapter.normalize(encoded, expected: expected, using: ChapterNormalizer())
            #expect(normalized.content.chapter == expected)
            #expect(!normalized.content.text.isEmpty)
            let wrong = try SnowlitCore.ChapterReference(book: expected.book, key: "another")
            await #expect(throws: ChapterWireAdapter.Failure.differentReference) {
                try await ChapterWireAdapter.normalize(encoded, expected: wrong, using: ChapterNormalizer())
            }
        }
    }

    @Test func headerInspectionNeverEvaluatesTheModuleAndRejectsInvalidMetadata() throws {
        let manifest = try manifestBytes()
        let module = "throw new Error('must not execute during header inspection');"
        let file = Data(("/* @yingxue\n" + String(decoding: manifest, as: UTF8.self) + "\n*/\n" + module).utf8)
        let header = try SourceFileHeader(bytes: file)
        #expect(header.manifest.sourceID == "org.example.reader")
        #expect(header.source.hasSuffix(module))
        let crlf = "\u{FEFF}" + String(decoding: file, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try SourceFileHeader(bytes: Data(crlf.utf8)).manifest == header.manifest)
        #expect(throws: SourceFileHeader.Failure.missingHeader) { try SourceFileHeader(bytes: Data(module.utf8)) }
        #expect(throws: SourceFileHeader.Failure.invalidUTF8) { try SourceFileHeader(bytes: Data([0xff])) }
        #expect(throws: (any Error).self) {
            try SourceFileHeader(bytes: Data("/* @yingxue\n{\"protocolVersion\":999}\n*/\nexport {};".utf8))
        }
    }

    @Test func upgradeSeparatesPermissionsAndReferenceStateMigrationsWithoutChangingInstallationIdentity() throws {
        let old = try YingxueWireCodec.decode(YingxueWire.Manifest.self, from: manifestBytes())
        let candidate = YingxueWire.Manifest(protocolVersion: 1, sourceID: old.sourceID, name: old.name,
            scriptVersion: "2.0", referenceVersion: 2, stateVersion: 3,
            capabilities: old.capabilities + [.browser], origins: old.origins + [.init(scheme: .https, host: "login.invalid")],
            authentication: [.web], publicConfiguration: old.publicConfiguration)
        let assessment = try SourceUpgradeAssessment(current: old, candidate: candidate)
        #expect(assessment.referenceMigrationRequired && assessment.publicStateMigrationRequired && assessment.permissionsExpanded)
        #expect(assessment.addedOrigins == ["https://login.invalid:443"])
        #expect(assessment.addedCapabilities == [.browser] && assessment.addedAuthentication == [.web])
        let unchanged = try SourceUpgradeAssessment(current: old, candidate: old)
        #expect(!unchanged.referenceMigrationRequired && !unchanged.publicStateMigrationRequired && !unchanged.permissionsExpanded)
    }

    @Test func originAliasesAndInvalidPublicConfigurationAreRejected() throws {
        let old = try YingxueWireCodec.decode(YingxueWire.Manifest.self, from: manifestBytes())
        func replacing(origins: [YingxueWire.Origin], settings: [YingxueWire.PublicSetting]) -> YingxueWire.Manifest {
            .init(protocolVersion: 1, sourceID: old.sourceID, name: old.name, scriptVersion: old.scriptVersion,
                  referenceVersion: old.referenceVersion, stateVersion: old.stateVersion, capabilities: old.capabilities,
                  origins: origins, authentication: old.authentication, publicConfiguration: settings)
        }
        #expect(throws: SourceFileHeader.Failure.duplicateOrigin) {
            try SourceFileHeader.validate(replacing(origins: old.origins + [.init(scheme: .https, host: "fixture.invalid", port: 443)], settings: []))
        }
        #expect(throws: SourceFileHeader.Failure.invalidChoice) {
            try SourceFileHeader.validate(replacing(origins: old.origins, settings: [.choice(.init(kind: .choice, key: "category", label: "分类", initial: "missing", choices: [.init(value: "all", label: "全部")]))]))
        }
        #expect(throws: SourceFileHeader.Failure.duplicateSetting) {
            try SourceFileHeader.validate(replacing(origins: old.origins, settings: old.publicConfiguration + old.publicConfiguration))
        }
    }

    @Test func violationsDoNotEchoPrivatePayloadsOrUnknownKeys() throws {
        do {
            try YingxueWireCodec.validate(Data(#"{"key":"book","private-cookie":"synthetic-secret"}"#.utf8), as: "BookReference")
            Issue.record("Unknown field was accepted")
        } catch let error as WireViolation {
            #expect(error == WireViolation(path: "$", reason: .unknownField))
        }
    }

    private func manifestBytes() throws -> Data {
        Data(try #require(WireCorpusCase.all.first { $0.name == "manifest-anonymous" }).json.utf8)
    }
}
