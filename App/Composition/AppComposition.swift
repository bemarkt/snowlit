import Foundation
import CryptoKit
import SnowlitCore
import SnowlitReader
import SnowlitStorage
import YingxueKit

@MainActor
struct AppComposition {
    let startup: StartupModel
    let sources: SourceLibraryModel

    init() {
        let storage = LibraryBootstrap()
        let files = SourceFileReader()
        sources = SourceLibraryModel(openLibrary: { try await storage.open() },
            inspect: { source, requirements in try await SourceFileInspector.inspect(source, requirements: requirements) },
            digest: { bytes in SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() },
            readFile: { url in try await files.read(url) })

        #if DEBUG
        // Only debug UI tests can request this deterministic first-attempt failure.
        if ProcessInfo.processInfo.arguments.contains("-snowlit-test-startup-failure") {
            let fault = StartupTestFault()
            startup = StartupModel {
                try await fault.failOnce()
                _ = try await storage.open()
            }
            return
        }
        #endif

        startup = StartupModel {
            _ = try await storage.open()
        }
    }
}

#if DEBUG
private actor StartupTestFault {
    private var hasFailed = false

    func failOnce() throws {
        if !hasFailed {
            hasFailed = true
            throw Failure.requested
        }
    }

    private enum Failure: Error { case requested }
}
#endif
