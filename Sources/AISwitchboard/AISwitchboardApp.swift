import SwiftUI

@main
struct AISwitchboardApp: App {
    var body: some Scene {
        WindowGroup("AI Switchboard") {
            ContentView()
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Controlla aggiornamenti…") {
                    Task { await Updater.shared.check() }
                }
                Button("Configurazione guidata…") {
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
            }
        }
    }
}
