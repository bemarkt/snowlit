import SwiftUI
#if DEBUG
import UIKit
@_spi(Experiments) import SnowlitReader
#endif

@main
struct SnowlitApp: App {
    @State private var startup = AppComposition.makeStartup()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-snowlit-probe-storage") {
                StorageProcessProbeView()
            } else if ProcessInfo.processInfo.arguments.contains("-snowlit-probe-reader-interaction") {
                ReaderInteractionProbeView()
            } else if ProcessInfo.processInfo.arguments.contains("-snowlit-probe-runtime-lifecycle") {
                RuntimeLifecycleProbeView()
            } else {
                StartupView(model: startup)
            }
            #else
            StartupView(model: startup)
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
