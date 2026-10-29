import SwiftUI

@main
struct ClaudeDeckApp: App {
    var body: some Scene {
        WindowGroup("Claude Deck") {
            ContentView()
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified)
    }
}
