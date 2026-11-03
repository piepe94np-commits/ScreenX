import Foundation

public final class SettingsStore: @unchecked Sendable {
    static let key = "settings.v1"

    private let defaults: UserDefaults
    private let home: URL

    public init(defaults: UserDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .defaults(home: home)
        }
        return settings
    }

    public func save(_ s: AppSettings) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
