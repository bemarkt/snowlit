import Foundation

/// File-provider access and copying run outside the main actor. The security
/// scope ends after the bytes have been copied; no bookmark or external path is saved.
actor SourceFileReader {
    func read(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bytes = try Data(contentsOf: url)
        try Task.checkCancellation()
        return bytes
    }
}
