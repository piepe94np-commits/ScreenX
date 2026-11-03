import CoreGraphics

/// Freigabe für Bildschirmaufnahme (TCC „Bildschirm- und Systemaudioaufnahme“).
enum ScreenPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Fragt die Freigabe an. Ist sie danach nicht erteilt, erklärt ein Fenster den Weg
    /// in die Systemeinstellungen.
    @MainActor
    static func requestOrExplain() {
        if CGRequestScreenCaptureAccess() { return }
        PermissionWindow.show()
    }
}
