import ScreenXCore
import SwiftUI

@main
struct ScreenXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: appDelegate.coordinator)
        } label: {
            MenuBarLabel(recorder: appDelegate.coordinator.videoRecorder)
        }

        Settings {
            SettingsView(coordinator: appDelegate.coordinator)
        }
    }
}
