import Foundation
import Testing
@testable import ScreenXCore

struct VideoSettingsTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private func decode(_ json: String) throws -> AppSettings {
        let decoder = JSONDecoder()
        decoder.userInfo[AppSettings.homeUserInfoKey] = home
        return try decoder.decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func decodesPreM5Settings() throws {
        let s = try decode(#"{"afterCapture":"openEditor","quickAccessDuration":10,"jpegQuality":0.5,"windowShadow":true,"exportFormat":"jpeg","hotkeys":{"area":{"keyCode":0,"modifiers":2}}}"#)
        #expect(s.afterCapture == .openEditor)
        #expect(s.quickAccessDuration == 10)
        #expect(s.exportFormat == .jpeg)
        #expect(s.windowShadow)
        #expect(s.hotkeys == [.area: KeyCombo(keyCode: 0, modifiers: [.option])])
        #expect(s.videoHotkey == KeyCombo(keyCode: 22, modifiers: [.option, .shift]))
        #expect(s.recordingProfiles == RecordingProfile.builtins)
        #expect(s.defaultProfileID == "meeting")
        #expect(s.countdown == .three)
        #expect(s.hideNotifications)
        #expect(s.microphoneDeviceID == nil)
        #expect(s.lastRecordingSetup == nil)
    }

    @Test func videoSettingsRoundTrip() throws {
        var s = AppSettings.defaults(home: home)
        s.videoHotkey = nil
        s.recordingProfiles.append(RecordingProfile(id: "custom", name: "Eigen", resolution: .p720, fps: 30))
        s.defaultProfileID = "custom"
        s.countdown = .five
        s.hideNotifications = false
        s.microphoneDeviceID = "mic-1"
        s.lastRecordingSetup = RecordingSetup(mode: .window, profileID: "custom", systemAudio: true, microphone: false)
        let data = try JSONEncoder().encode(s)
        let decoder = JSONDecoder()
        decoder.userInfo[AppSettings.homeUserInfoKey] = home
        #expect(try decoder.decode(AppSettings.self, from: data) == s)
    }

    @Test func profileLookupFallsBack() {
        var s = AppSettings.defaults(home: home)
        #expect(s.profile(id: "demo").id == "demo")
        #expect(s.profile(id: "unknown").id == "meeting")
        s.defaultProfileID = "presentation"
        #expect(s.profile(id: "unknown").id == "presentation")
        s.recordingProfiles = []
        #expect(s.profile(id: "unknown") == RecordingProfile.builtins[0])
    }

    @Test func lossyProfileList() throws {
        let s = try decode(#"{"recordingProfiles":[{"id":"a","name":"A"},"kaputt",{"id":"b","name":"B","fps":10}]}"#)
        #expect(s.recordingProfiles.map(\.id) == ["a", "b"])
        #expect(s.recordingProfiles[1].fps == 10)
    }

    @Test func profileSwitchResetsAudioToggles() {
        let s = AppSettings.defaults(home: home)
        let demo = s.profile(id: "demo")
        let setup = s.setup(applying: demo, mode: .area)
        #expect(setup == RecordingSetup(mode: .area, profileID: "demo", systemAudio: false, microphone: false))
        let meeting = s.setup(applying: s.profile(id: "meeting"), mode: .fullscreen)
        #expect(meeting.systemAudio && meeting.microphone && meeting.mode == .fullscreen)
    }
}
