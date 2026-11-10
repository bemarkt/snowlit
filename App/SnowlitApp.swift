import SwiftUI
#if DEBUG
import UIKit
@_spi(Experiments) import SnowlitReader
#endif

@main
struct SnowlitApp: App {
    @State private var composition = AppComposition()
    #if DEBUG
    @UIApplicationDelegateAdaptor(StorageProcessProbeDelegate.self) private var storageProbe
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-snowlit-probe-storage") {
                StorageProcessProbeView(probe: storageProbe)
            } else if ProcessInfo.processInfo.arguments.contains("-snowlit-probe-reader-interaction") {
                ReaderInteractionProbeView()
            } else if ProcessInfo.processInfo.arguments.contains("-snowlit-probe-runtime-lifecycle") {
                RuntimeLifecycleProbeView()
            } else {
                StartupView(model: composition.startup, sources: composition.sources,
                    management: composition.management, candidateValidator: composition.candidateValidator,
                    runtime: composition.runtime, authentication: composition.authentication,
                    search: composition.search, shelf: composition.shelf, backup: composition.backup, makeBook: composition.makeBook)
            }
            #else
            StartupView(model: composition.startup, sources: composition.sources,
                management: composition.management, candidateValidator: composition.candidateValidator,
                runtime: composition.runtime, authentication: composition.authentication,
                search: composition.search, shelf: composition.shelf, backup: composition.backup, makeBook: composition.makeBook)
            #endif
        }
    }
}

#if DEBUG
private struct ReaderInteractionProbeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { makeReaderInteractionProbe() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

#endif
