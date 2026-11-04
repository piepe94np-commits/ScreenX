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
    public var exportScale: ExportScale
    public var applyLastStyle: Bool

    public init(
        hotkeys: [CaptureMode: KeyCombo],
        afterCapture: AfterCaptureAction,
        quickAccessDuration: TimeInterval,
        saveDirectory: URL,
        exportFormat: ExportFormat,
        jpegQuality: Double,
        windowShadow: Bool,
        exportScale: ExportScale = .original,
        applyLastStyle: Bool = true
    ) {
        self.hotkeys = hotkeys
        self.afterCapture = afterCapture
        self.quickAccessDuration = quickAccessDuration
        self.saveDirectory = saveDirectory
        self.exportFormat = exportFormat
        self.jpegQuality = jpegQuality
        self.windowShadow = windowShadow
        self.exportScale = exportScale
        self.applyLastStyle = applyLastStyle
    }

    /// `userInfo` key carrying the home directory (`URL`) used for default values while decoding.
    public static let homeUserInfoKey = CodingUserInfoKey(rawValue: "com.screenx.settings.home")!

    private enum CodingKeys: String, CodingKey {
        case hotkeys, afterCapture, quickAccessDuration, saveDirectory, exportFormat
        case jpegQuality, windowShadow, exportScale, applyLastStyle
    }

    /// Tolerant decoding: every field falls back to its default when missing or unreadable.
    /// A `hotkeys` dictionary that is present is kept as stored (a mode the user cleared stays
    /// empty); only a missing dictionary yields the default shortcuts.
    public init(from decoder: Decoder) throws {
        let home = decoder.userInfo[Self.homeUserInfoKey] as? URL
            ?? FileManager.default.homeDirectoryForCurrentUser
        let d = Self.defaults(home: home)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkeys = (try? c.decodeIfPresent([CaptureMode: KeyCombo].self, forKey: .hotkeys)) ?? d.hotkeys
        afterCapture = (try? c.decodeIfPresent(AfterCaptureAction.self, forKey: .afterCapture)) ?? d.afterCapture
        quickAccessDuration = (try? c.decodeIfPresent(TimeInterval.self, forKey: .quickAccessDuration)) ?? d.quickAccessDuration
        saveDirectory = (try? c.decodeIfPresent(URL.self, forKey: .saveDirectory)) ?? d.saveDirectory
        exportFormat = (try? c.decodeIfPresent(ExportFormat.self, forKey: .exportFormat)) ?? d.exportFormat
        jpegQuality = (try? c.decodeIfPresent(Double.self, forKey: .jpegQuality)) ?? d.jpegQuality
        windowShadow = (try? c.decodeIfPresent(Bool.self, forKey: .windowShadow)) ?? d.windowShadow
        exportScale = (try? c.decodeIfPresent(ExportScale.self, forKey: .exportScale)) ?? d.exportScale
        applyLastStyle = (try? c.decodeIfPresent(Bool.self, forKey: .applyLastStyle)) ?? d.applyLastStyle
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
            windowShadow: false,
            exportScale: .original,
            applyLastStyle: true
        )
    }
}
