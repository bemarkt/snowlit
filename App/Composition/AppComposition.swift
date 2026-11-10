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
    let management: SourceManagementModel
    let candidateValidator: SourceCandidateValidator
    let runtime: SourceRuntime
    let authentication: SourceAuthenticationModel

    init() {
        let storage = LibraryBootstrap()
        let files = SourceFileReader()
        let validator = SourceCandidateValidator()
        let runtime = SourceRuntime(openLibrary: { try await storage.open() },
            digest: { bytes in SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() })
        self.runtime = runtime
        candidateValidator = validator
        let management = SourceManagementModel(openLibrary: { try await storage.open() },
            digest: { bytes in SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() },
            validate: { try await validator.validate($0) },
            invalidate: { try await runtime.invalidate($0); try await validator.invalidate($0) },
            cleanup: { try await validator.cleanup($0, token: $1) })
        self.management = management
        authentication = SourceAuthenticationModel { expected in
            guard let signedOut = await management.perform(.signOut, expected: expected) else {
                throw SourceAuthenticationModel.Failure.resetFailed
            }
            try Task.checkCancellation()
            let reply = try await runtime.invoke(.authenticate(.init(kind: .authenticate, input: .init(reason: .signIn))), expected: signedOut)
            return (signedOut, reply)
        }
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
