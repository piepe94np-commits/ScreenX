import Foundation
import Testing
@testable import ScreenXCore

struct SettingsTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test func defaultsMatchSpec() {
        let s = AppSettings.defaults(home: home)
        #expect(s.hotkeys[.fullscreen] == KeyCombo(keyCode: 20, modifiers: [.option, .shift]))
        #expect(s.hotkeys[.area] == KeyCombo(keyCode: 21, modifiers: [.option, .shift]))
        #expect(s.hotkeys[.window] == KeyCombo(keyCode: 23, modifiers: [.option, .shift]))
        #expect(s.afterCapture == .quickAccess)
        #expect(s.quickAccessDuration == 6)
        #expect(s.saveDirectory == home.appendingPathComponent("Pictures/ScreenX", isDirectory: true))
        #expect(s.exportFormat == .png)
        #expect(s.jpegQuality == 0.9)
        #expect(s.windowShadow == false)
    }

    @Test func displayStringOrder() {
        let combo = KeyCombo(keyCode: 21, modifiers: [.command, .shift, .option, .control])
        #expect(combo.displayString == "⌃⌥⇧⌘4")
    }

    @Test func displayStringKeyNames() {
        #expect(KeyCombo(keyCode: 0, modifiers: []).displayString == "A")
        #expect(KeyCombo(keyCode: 122, modifiers: [.command]).displayString == "⌘F1")
        #expect(KeyCombo(keyCode: 999, modifiers: []).displayString == "#999")
    }

    @Test func storeRoundTrip() {
        let name = "test-\(UUID())"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        var settings = AppSettings.defaults(home: home)
        settings.exportFormat = .jpeg
        settings.jpegQuality = 0.5
        settings.windowShadow = true
        settings.afterCapture = .openEditor
        settings.hotkeys[.area] = KeyCombo(keyCode: 0, modifiers: [.command, .control])
        SettingsStore(defaults: suite, home: home).save(settings)
        let loaded = SettingsStore(defaults: suite, home: home).load()
        #expect(loaded == settings)
    }

    @Test func corruptDataFallsBackToDefaults() {
        let name = "test-\(UUID())"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        suite.set(Data("not json {{{".utf8), forKey: "settings.v1")
        #expect(SettingsStore(defaults: suite, home: home).load() == .defaults(home: home))
    }

    @Test func emptyStoreReturnsDefaults() {
        let name = "test-\(UUID())"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        #expect(SettingsStore(defaults: suite, home: home).load() == .defaults(home: home))
    }

    @Test func decodesM1SettingsWithoutNewFields() throws {
        let json = """
        {"hotkeys":{"area":{"keyCode":21,"modifiers":6},"window":{"keyCode":23,"modifiers":6},"fullscreen":{"keyCode":20,"modifiers":6}},
         "afterCapture":"openEditor","quickAccessDuration":12,"saveDirectory":"file:///Users/tester/Pictures/ScreenX/",
         "exportFormat":"jpeg","jpegQuality":0.8,"windowShadow":true}
        """
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.quickAccessDuration == 12)
        #expect(s.afterCapture == .openEditor)
        #expect(s.exportFormat == .jpeg)
        #expect(s.exportScale == .original)
        #expect(s.applyLastStyle == true)
    }

    @Test func missingHotkeyModeStaysEmpty() throws {
        let json = #"{"hotkeys":{"area":{"keyCode":21,"modifiers":6}}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.hotkeys[.area] == KeyCombo(keyCode: 21, modifiers: [.option, .shift]))
        #expect(s.hotkeys[.window] == nil)
        #expect(s.hotkeys[.fullscreen] == nil)
    }

    @Test func missingHotkeysUseDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s.hotkeys.count == 3)
    }

    @Test func newFieldsRoundTrip() {
        let name = "test-\(UUID())"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        var settings = AppSettings.defaults(home: home)
        settings.exportScale = .x2
        settings.applyLastStyle = false
        SettingsStore(defaults: suite, home: home).save(settings)
        #expect(SettingsStore(defaults: suite, home: home).load() == settings)
    }
}
