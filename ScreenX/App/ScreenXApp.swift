import SwiftUI
import ScreenXCore

@main
struct ScreenXApp: App {
    var body: some Scene {
        MenuBarExtra("ScreenX", systemImage: "camera.viewfinder") {
            Button(String(localized: "Beenden")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
