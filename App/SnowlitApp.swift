import SwiftUI

@main
struct SnowlitApp: App {
    var body: some Scene {
        WindowGroup {
            ContentUnavailableView(
                "Snowlit",
                systemImage: "book.closed",
                description: Text("从一本好书开始")
            )
        }
    }
}
