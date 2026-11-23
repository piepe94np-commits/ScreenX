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
    public var videoHotkey: KeyCombo?
    public var recordingProfiles: [RecordingProfile]
    public var defaultProfileID: String
    public var countdown: CountdownSetting
    public var hideNotifications: Bool
    public var microphoneDeviceID: String?
    public var lastRecordingSetup: RecordingSetup?

    public init(
        hotkeys: [CaptureMode: KeyCombo],
        afterCapture: AfterCaptureAction,
        quickAccessDuration: TimeInterval,
        saveDirectory: URL,
        exportFormat: ExportFormat,
        jpegQuality: Double,
        windowShadow: Bool,
        exportScale: ExportScale = .original,
        applyLastStyle: Bool = true,
        videoHotkey: KeyCombo? = AppSettings.defaultVideoHotkey,
        recordingProfiles: [RecordingProfile] = RecordingProfile.builtins,
        defaultProfileID: String = RecordingProfile.defaultID,
        countdown: CountdownSetting = .three,
        hideNotifications: Bool = true,
        microphoneDeviceID: String? = nil,
        lastRecordingSetup: RecordingSetup? = nil
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
        self.videoHotkey = videoHotkey
        self.recordingProfiles = recordingProfiles
        self.defaultProfileID = defaultProfileID
        self.countdown = countdown
        self.hideNotifications = hideNotifications
        self.microphoneDeviceID = microphoneDeviceID
        self.lastRecordingSetup = lastRecordingSetup
    }

    /// ⌥⇧6 (key code 22).
    public static let defaultVideoHotkey = KeyCombo(keyCode: 22, modifiers: [.option, .shift])

    /// `userInfo` key carrying the home directory (`URL`) used for default values while decoding.
    public static let homeUserInfoKey = CodingUserInfoKey(rawValue: "com.screenx.settings.home")!

    private enum CodingKeys: String, CodingKey {
        case hotkeys, afterCapture, quickAccessDuration, saveDirectory, exportFormat
        case jpegQuality, windowShadow, exportScale, applyLastStyle
        case videoHotkey, recordingProfiles, defaultProfileID, countdown, hideNotifications
        case microphoneDeviceID, lastRecordingSetup
    }

    /// Tolerant decoding: every field falls back to its default when missing or unreadable.
    /// A `hotkeys` dictionary that is present is kept as stored (a mode the user cleared stays
    /// empty); only a missing dictionary yields the default shortcuts.
    public init(from decoder: Decoder) throws {
        let home = decoder.userInfo[Self.homeUserInfoKey] as? URL
            ?? FileManager.default.homeDirectoryForCurrentUser
        let d = Self.defaults(home: home)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try? c.decodeIfPresent([String: KeyCombo].self, forKey: .hotkeys) {
            // Unknown modes (e.g. from a future version) are ignored instead of resetting everything.
            hotkeys = Dictionary(uniqueKeysWithValues: raw.compactMap { key, combo in
                CaptureMode(rawValue: key).map { ($0, combo) }
            })
        } else {
            hotkeys = d.hotkeys
        }
        afterCapture = (try? c.decodeIfPresent(AfterCaptureAction.self, forKey: .afterCapture)) ?? d.afterCapture
        quickAccessDuration = min(30, max(3, (try? c.decodeIfPresent(TimeInterval.self, forKey: .quickAccessDuration)) ?? d.quickAccessDuration))
        saveDirectory = (try? c.decodeIfPresent(URL.self, forKey: .saveDirectory)) ?? d.saveDirectory
        exportFormat = (try? c.decodeIfPresent(ExportFormat.self, forKey: .exportFormat)) ?? d.exportFormat
        jpegQuality = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .jpegQuality)) ?? d.jpegQuality))
        windowShadow = (try? c.decodeIfPresent(Bool.self, forKey: .windowShadow)) ?? d.windowShadow
        exportScale = (try? c.decodeIfPresent(ExportScale.self, forKey: .exportScale)) ?? d.exportScale
        applyLastStyle = (try? c.decodeIfPresent(Bool.self, forKey: .applyLastStyle)) ?? d.applyLastStyle
        // A stored-but-null videoHotkey means the user cleared it; only a missing key yields the default.
        if c.contains(.videoHotkey) {
            videoHotkey = (try? c.decodeIfPresent(KeyCombo.self, forKey: .videoHotkey)) ?? nil
        } else {
            videoHotkey = d.videoHotkey
        }
        if let lossy = try? c.decodeIfPresent([LossyProfile].self, forKey: .recordingProfiles) {
            recordingProfiles = lossy.compactMap(\.value)
        } else {
            recordingProfiles = d.recordingProfiles
        }
        defaultProfileID = (try? c.decodeIfPresent(String.self, forKey: .defaultProfileID)) ?? d.defaultProfileID
        countdown = (try? c.decodeIfPresent(CountdownSetting.self, forKey: .countdown)) ?? d.countdown
        hideNotifications = (try? c.decodeIfPresent(Bool.self, forKey: .hideNotifications)) ?? d.hideNotifications
        microphoneDeviceID = (try? c.decodeIfPresent(String.self, forKey: .microphoneDeviceID)) ?? nil
        lastRecordingSetup = (try? c.decodeIfPresent(RecordingSetup.self, forKey: .lastRecordingSetup)) ?? nil
    }

    /// Explicit encoding so a cleared `videoHotkey` is stored as `null` (the synthesized encoder
    /// would omit the key, which decoding reads as "use the default").
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hotkeys, forKey: .hotkeys)
        try c.encode(afterCapture, forKey: .afterCapture)
        try c.encode(quickAccessDuration, forKey: .quickAccessDuration)
        try c.encode(saveDirectory, forKey: .saveDirectory)
        try c.encode(exportFormat, forKey: .exportFormat)
        try c.encode(jpegQuality, forKey: .jpegQuality)
        try c.encode(windowShadow, forKey: .windowShadow)
        try c.encode(exportScale, forKey: .exportScale)
        try c.encode(applyLastStyle, forKey: .applyLastStyle)
        try c.encode(videoHotkey, forKey: .videoHotkey)
        try c.encode(recordingProfiles, forKey: .recordingProfiles)
        try c.encode(defaultProfileID, forKey: .defaultProfileID)
        try c.encode(countdown, forKey: .countdown)
        try c.encode(hideNotifications, forKey: .hideNotifications)
        try c.encodeIfPresent(microphoneDeviceID, forKey: .microphoneDeviceID)
        try c.encodeIfPresent(lastRecordingSetup, forKey: .lastRecordingSetup)
    }

    /// Decodes one profile, turning an unreadable element into `nil` instead of failing the list.
    private struct LossyProfile: Decodable {
        let value: RecordingProfile?
        init(from decoder: Decoder) throws {
            value = try? RecordingProfile(from: decoder)
        }
    }

    /// The profile with `id`, else the default profile, else the first built-in.
    public func profile(id: String) -> RecordingProfile {
        recordingProfiles.first { $0.id == id }
            ?? recordingProfiles.first { $0.id == defaultProfileID }
            ?? RecordingProfile.builtins[0]
    }

    /// Switching profile: the audio toggles follow the profile.
    public func setup(applying profile: RecordingProfile, mode: CaptureMode) -> RecordingSetup {
        RecordingSetup(mode: mode, profileID: profile.id,
                       systemAudio: profile.systemAudio, microphone: profile.microphone)
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
            applyLastStyle: true,
            videoHotkey: defaultVideoHotkey,
            recordingProfiles: RecordingProfile.builtins,
            defaultProfileID: RecordingProfile.defaultID,
            countdown: .three,
            hideNotifications: true,
            microphoneDeviceID: nil,
            lastRecordingSetup: nil
        )
    }
}
