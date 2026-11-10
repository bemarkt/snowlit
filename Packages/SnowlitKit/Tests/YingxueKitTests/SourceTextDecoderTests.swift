#if canImport(CoreFoundation)
import Foundation
import Testing
@testable import YingxueKit

struct SourceTextDecoderTests {
    @Test func explicitChineseAndWesternEncodingsPreserveTextWithoutGuessing() throws {
        let cases: [(YingxueWire.TextEncoding, [UInt8], String)] = [
            (.gb18030, [0xd6, 0xd0, 0xce, 0xc4], "中文"),
            (.big5, [0xa4, 0xa4, 0xa4, 0xe5], "中文"),
            (.windows1252, [0x80], "€"), (.latin1, [0xe9], "é"),
            (.utf16LE, [0x2d, 0x4e], "中"), (.utf16BE, [0x4e, 0x2d], "中"),
            (.utf8, Array("中文👩🏽‍💻".utf8), "中文👩🏽‍💻")
        ]
        for (encoding, bytes, expected) in cases {
            #expect(try SourceTextDecoder.decode(.init(base64: Data(bytes).base64EncodedString(), encoding: encoding)).text == expected)
        }
        #expect(throws: SourceHostFailure.invalidEncoding) {
            try SourceTextDecoder.decode(.init(base64: Data([0xd6, 0xd0]).base64EncodedString(), encoding: .utf8))
        }
        #expect(throws: SourceHostFailure.invalidEncoding) {
            try SourceTextDecoder.decode(.init(base64: Data([0xd6]).base64EncodedString(), encoding: .gb18030))
        }
    }
}
#endif
