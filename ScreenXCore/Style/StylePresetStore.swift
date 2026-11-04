import Foundation

public struct StylePreset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var style: Style

    public init(id: UUID = UUID(), name: String, style: Style) {
        self.id = id
        self.name = name
        self.style = style
    }
}

public final class StylePresetStore: @unchecked Sendable {
    static let presetsKey = "stylePresets.v1"
    static let lastStyleKey = "lastStyle.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func presets() -> [StylePreset] {
        guard let data = defaults.data(forKey: Self.presetsKey),
              let list = try? JSONDecoder().decode([StylePreset].self, from: data)
        else { return [] }
        return list
    }

    /// Replaces the preset with the same `id`, or appends.
    public func save(_ p: StylePreset) {
        var list = presets()
        if let index = list.firstIndex(where: { $0.id == p.id }) {
            list[index] = p
        } else {
            list.append(p)
        }
        store(list)
    }

    public func delete(id: UUID) {
        store(presets().filter { $0.id != id })
    }

    public func lastStyle() -> Style? {
        guard let data = defaults.data(forKey: Self.lastStyleKey) else { return nil }
        return try? JSONDecoder().decode(Style.self, from: data)
    }

    public func setLastStyle(_ s: Style) {
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: Self.lastStyleKey)
        }
    }

    private func store(_ list: [StylePreset]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.presetsKey)
        }
    }
}
