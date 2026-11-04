import Foundation
import os

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
    static let backupKey = "stylePresets.v1.backup"
    static let lastStyleKey = "lastStyle.v1"

    private static let logger = Logger(subsystem: "com.screenx.app", category: "presets")

    /// Decodes an element or yields `nil`, so one bad preset doesn't hide the others.
    private struct Lossy: Decodable {
        let preset: StylePreset?
        init(from decoder: Decoder) throws {
            preset = try? StylePreset(from: decoder)
        }
    }

    private let defaults: UserDefaults
    /// Serializes read-modify-write cycles; `UserDefaults` itself is thread-safe.
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func presets() -> [StylePreset] {
        lock.lock()
        defer { lock.unlock() }
        return load().presets
    }

    /// Replaces the preset with the same `id`, or appends.
    public func save(_ p: StylePreset) {
        lock.lock()
        defer { lock.unlock() }
        var list = load().presets
        if let index = list.firstIndex(where: { $0.id == p.id }) {
            list[index] = p
        } else {
            list.append(p)
        }
        store(list)
    }

    public func delete(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        store(load().presets.filter { $0.id != id })
    }

    public func lastStyle() -> Style? {
        guard let data = defaults.data(forKey: Self.lastStyleKey) else { return nil }
        return try? JSONDecoder().decode(Style.self, from: data)
    }

    public func setLastStyle(_ s: Style) {
        do {
            defaults.set(try JSONEncoder().encode(s), forKey: Self.lastStyleKey)
        } catch {
            Self.logger.error("Failed to encode last style: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() -> (presets: [StylePreset], damaged: Bool) {
        guard let data = defaults.data(forKey: Self.presetsKey) else { return ([], false) }
        guard let elements = try? JSONDecoder().decode([Lossy].self, from: data) else { return ([], true) }
        let list = elements.compactMap(\.preset)
        return (list, list.count != elements.count)
    }

    /// Keeps the original blob once under the backup key if it had undecodable content,
    /// because the write below would otherwise destroy it.
    private func store(_ list: [StylePreset]) {
        if load().damaged, defaults.data(forKey: Self.backupKey) == nil,
           let raw = defaults.data(forKey: Self.presetsKey) {
            defaults.set(raw, forKey: Self.backupKey)
        }
        do {
            defaults.set(try JSONEncoder().encode(list), forKey: Self.presetsKey)
        } catch {
            Self.logger.error("Failed to encode presets: \(error.localizedDescription, privacy: .public)")
        }
    }
}
