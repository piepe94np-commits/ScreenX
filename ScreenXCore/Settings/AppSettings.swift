import Foundation

public enum AfterCaptureAction: String, Codable, Sendable {
    case quickAccess
    case openEditor
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var hotkeys: [CaptureMode: KeyCombo]
    public var afterCapture: AfterCaptureAction
    public var quickAccessDuration: TimeInterval
    public var saveDirectory: URL
    public var exportFormat: ExportFormat
    public var jpegQuality: Double
    public var windowShadow: Bool

    public init(
        hotkeys: [CaptureMode: KeyCombo],
        afterCapture: AfterCaptureAction,
        quickAccessDuration: TimeInterval,
        saveDirectory: URL,
        exportFormat: ExportFormat,
        jpegQuality: Double,
        windowShadow: Bool
    ) {
        self.hotkeys = hotkeys
        self.afterCapture = afterCapture
        self.quickAccessDuration = quickAccessDuration
        self.saveDirectory = saveDirectory
        self.exportFormat = exportFormat
        self.jpegQuality = jpegQuality
        self.windowShadow = windowShadow
    }

    public static func defaults(home: URL) -> AppSettings {
        let optionShift: KeyModifiers = [.option, .shift]
        return AppSettings(
            hotkeys: [
                .fullscreen: KeyCombo(keyCode: 20, modifiers: optionShift),
                .area: KeyCombo(keyCode: 21, modifiers: optionShift),
                .window: KeyCombo(keyCode: 23, modifiers: optionShift),
            ],
            afterCapture: .quickAccess,
            quickAccessDuration: 6,
            saveDirectory: home.appendingPathComponent("Pictures/ScreenX", isDirectory: true),
            exportFormat: .png,
            jpegQuality: 0.9,
            windowShadow: false
        )
    }
}
