import Foundation
import os

public final class SettingsStore: @unchecked Sendable {
    static let key = "settings.v1"

    private static let logger = Logger(subsystem: "com.screenx.app", category: "settings")

    private let defaults: UserDefaults
    private let home: URL

    public init(defaults: UserDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
    }

    public func load() -> AppSettings {
        let decoder = JSONDecoder()
        decoder.userInfo[AppSettings.homeUserInfoKey] = home
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? decoder.decode(AppSettings.self, from: data)
        else {
            return .defaults(home: home)
        }
        return settings
    }

    public func save(_ s: AppSettings) {
        do {
            defaults.set(try JSONEncoder().encode(s), forKey: Self.key)
        } catch {
            Self.logger.error("Failed to encode settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
