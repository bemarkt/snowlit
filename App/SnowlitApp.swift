import SwiftUI

@main
struct SnowlitApp: App {
    @State private var startup = AppComposition.makeStartup()

    var body: some Scene {
        WindowGroup {
            StartupView(model: startup)
        }
    }
}
