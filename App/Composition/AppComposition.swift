import Foundation
import SnowlitCore
import SnowlitReader
import SnowlitStorage
import YingxueKit

@MainActor
enum AppComposition {
    static func makeStartup() -> StartupModel {
        let storage = StorageBootstrap()

        #if DEBUG
        // Only debug UI tests can request this deterministic first-attempt failure.
        if ProcessInfo.processInfo.arguments.contains("-snowlit-test-startup-failure") {
            let fault = StartupTestFault()
            return StartupModel {
                try await fault.failOnce()
                try await storage.prepare()
            }
        }
        #endif

        return StartupModel {
            try await storage.prepare()
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
