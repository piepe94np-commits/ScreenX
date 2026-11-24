import Foundation
import Testing
@testable import ScreenXCore

struct StylePresetTests {
    private func suite() -> (UserDefaults, () -> Void) {
        let name = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func presetCRUD() {
        let (defaults, cleanup) = suite()
        defer { cleanup() }
        let store = StylePresetStore(defaults: defaults)
        #expect(store.presets().isEmpty)

        let a = StylePreset(name: "A", style: .default)
        var wide = Style.default
        wide.padding = 120
        let b = StylePreset(name: "B", style: wide)
        store.save(a)
        store.save(b)
        #expect(store.presets() == [a, b])

        var renamed = a
        renamed.name = "A2"
        renamed.style.cornerRadius = 30
        store.save(renamed)
        #expect(store.presets() == [renamed, b])

        store.delete(id: a.id)
        #expect(store.presets() == [b])
    }

    @Test func lastStyleRoundTrip() {
        let (defaults, cleanup) = suite()
        defer { cleanup() }
        let store = StylePresetStore(defaults: defaults)
        #expect(store.lastStyle() == nil)
        var style = Style.default
        style.padding = 200
        style.aspect = .r16x9
        store.setLastStyle(style)
        #expect(store.lastStyle() == style)
    }

    @Test func corruptPresetsEmpty() {
        let (defaults, cleanup) = suite()
        defer { cleanup() }
        defaults.set(Data("garbage".utf8), forKey: "stylePresets.v1")
        defaults.set(Data("garbage".utf8), forKey: "lastStyle.v1")
        let store = StylePresetStore(defaults: defaults)
        #expect(store.presets().isEmpty)
        #expect(store.lastStyle() == nil)
    }

    @Test func badPresetDoesNotWipeOthers() throws {
        let (defaults, cleanup) = suite()
        defer { cleanup() }
        let good = StylePreset(name: "Gut", style: .default)
        let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let raw = try JSONSerialization.data(withJSONObject: [goodJSON, ["garbage": true]])
        defaults.set(raw, forKey: "stylePresets.v1")
        let store = StylePresetStore(defaults: defaults)
        #expect(store.presets() == [good])

        let added = StylePreset(name: "Neu", style: .default)
        store.save(added)
        #expect(store.presets() == [good, added])
        #expect(defaults.data(forKey: "stylePresets.v1.backup") == raw)
    }
}
