#if canImport(CoreFoundation)
import CoreFoundation
import Foundation

public enum SourceTextDecoder {
    /// Explicit, non-lossy decoding. Response bytes are preserved until an
    /// encoding is chosen; no automatic UTF-8 fallback can silently alter text.
    public static func decode(_ request: YingxueWire.DecodeTextRequest) throws -> YingxueWire.DecodeTextResult {
        _ = try YingxueWireCodec.encode(request)
        guard let bytes = Data(base64Encoded: request.base64) else { throw SourceHostFailure.invalidEncoding }
        let iana: String
        switch request.encoding {
        case .utf8: iana = "UTF-8"
        case .utf16LE: iana = "UTF-16LE"
        case .utf16BE: iana = "UTF-16BE"
        case .windows1252: iana = "windows-1252"
        case .latin1: iana = "ISO-8859-1"
        case .gb18030: iana = "GB18030"
        case .big5: iana = "Big5"
        }
        let name = iana.withCString { CFStringCreateWithCString(nil, $0, CFStringBuiltInEncodings.UTF8.rawValue) }
        guard let name else { throw SourceHostFailure.invalidEncoding }
        let encoding = CFStringConvertIANACharSetNameToEncoding(name)
        guard encoding != kCFStringEncodingInvalidId,
              let text = String(data: bytes, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) else {
            throw SourceHostFailure.invalidEncoding
        }
        return .init(text: text)
    }
}
#endif
