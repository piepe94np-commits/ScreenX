import ScreenXCore
import SwiftUI

@main
struct ScreenXApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra("ScreenX", systemImage: "camera.viewfinder") {
            MenuBarContent(coordinator: coordinator)
        }

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}
