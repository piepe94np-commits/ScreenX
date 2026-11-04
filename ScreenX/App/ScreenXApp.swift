import ScreenXCore
import SwiftUI

@main
struct ScreenXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ScreenX", systemImage: "camera.viewfinder") {
            MenuBarContent(coordinator: appDelegate.coordinator)
        }

        Settings {
            SettingsView(coordinator: appDelegate.coordinator)
        }
    }
}
