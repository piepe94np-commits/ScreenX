import Foundation

public enum HotkeyError: Error, Equatable, Sendable {
    case alreadyTaken(KeyCombo)
    case failed(Int32)

    /// Carbon `eventHotKeyExistsErr`.
    static let eventHotKeyExistsStatus: Int32 = -9878

    /// Maps an `OSStatus` from `RegisterEventHotKey` to an error. `noErr` (0) yields `nil`.
    public static func from(status: Int32, combo: KeyCombo) -> HotkeyError? {
        switch status {
        case 0: nil
        case eventHotKeyExistsStatus: .alreadyTaken(combo)
        default: .failed(status)
        }
    }
}

extension HotkeyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyTaken:
            String(localized: "Bereits von einer anderen App belegt")
        case .failed(let status):
            String(localized: "Tastenkürzel konnte nicht registriert werden (Fehler \(status))")
        }
    }
}
