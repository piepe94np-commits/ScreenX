import AppKit
import SwiftUI

/// Erklärt, dass die Freigabe für Bildschirmaufnahme fehlt, und öffnet die Systemeinstellungen.
/// Es gibt höchstens ein Fenster; nach dem Schließen wird dasselbe Fenster wieder gezeigt.
@MainActor
enum PermissionWindow {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: PermissionView()))
        window.title = "ScreenX"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 200))
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(String(localized: "ScreenX braucht die Freigabe für Bildschirmaufnahme."))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(String(localized: "Nach dem Erteilen der Freigabe ScreenX neu starten."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "Systemeinstellungen öffnen")) {
                NSWorkspace.shared.open(PermissionWindow.settingsURL)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 420, height: 200)
    }
}
