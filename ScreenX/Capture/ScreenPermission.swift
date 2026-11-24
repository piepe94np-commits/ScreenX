import Foundation
import CoreGraphics

/// Freigabe für Bildschirmaufnahme (TCC „Bildschirm- und Systemaudioaufnahme“).
enum ScreenPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static let requestedKey = "permissionRequested"

    /// Beim Start: löst nur die Systemabfrage aus, ohne Hinweisfenster.
    @MainActor
    static func requestAtLaunch(defaults: UserDefaults = .standard) {
        guard !isGranted else { return }
        request(defaults: defaults)
    }

    /// Vor einer Aufnahme: Wurde schon einmal angefragt, erklärt ein Fenster den Weg in die
    /// Systemeinstellungen. Sonst erscheint nur die Systemabfrage, nie beides zugleich.
    @MainActor
    static func requestOrExplain(defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: requestedKey) {
            PermissionWindow.show()
        } else {
            request(defaults: defaults)
        }
    }

    @MainActor
    private static func request(defaults: UserDefaults) {
        defaults.set(true, forKey: requestedKey)
        _ = CGRequestScreenCaptureAccess()
    }
}
