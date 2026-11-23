import Foundation

public enum CountdownSetting: Int, Codable, CaseIterable, Sendable {
    case off = 0, three = 3, five = 5
}

public struct RecordingSetup: Codable, Hashable, Sendable {
    public var mode: CaptureMode
    public var profileID: String
    public var systemAudio: Bool
    public var microphone: Bool

    public init(mode: CaptureMode, profileID: String, systemAudio: Bool, microphone: Bool) {
        self.mode = mode
        self.profileID = profileID
        self.systemAudio = systemAudio
        self.microphone = microphone
    }
}
