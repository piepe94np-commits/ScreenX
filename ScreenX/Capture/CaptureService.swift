import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ScreenXCore

enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case displayNotFound
    case windowNotFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            String(localized: "Keine Berechtigung für Bildschirmaufnahme.")
        case .displayNotFound:
            String(localized: "Bildschirm nicht gefunden.")
        case .windowNotFound:
            String(localized: "Fenster nicht gefunden.")
        case .failed(let reason):
            String(localized: "Aufnahme fehlgeschlagen: \(reason)")
        }
    }
}

/// Bildschirm- und Fensteraufnahmen über ScreenCaptureKit. SCK-Objekte bleiben im Actor,
/// nach außen gehen nur Sendable-Werte.
actor CaptureService {
    /// Alle angeschlossenen Monitore. `frame` (AppKit-global) und `scale` stammen aus `NSScreen`.
    func displays() async throws -> [DisplayInfo] {
        let content = try await shareableContent()
        let available = Set(content.displays.map(\.displayID))
        return await Self.currentDisplays().filter { available.contains($0.id) }
    }

    /// Ganzer Monitor in voller nativer Auflösung, ohne Cursor.
    func captureDisplay(_ id: UInt32) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return try await captureImage(filter: filter, configuration: config)
    }

    /// Sichtbare Fenster, von vorne nach hinten. Gefiltert nach Ebene/Größe wird erst im `WindowHitTester`.
    func windows() async throws -> [WindowInfo] {
        let content = try await shareableContent()
        let order = Self.frontToBackOrder()
        let onScreen = content.windows.filter(\.isOnScreen)
        let sorted = onScreen.enumerated().sorted { lhs, rhs in
            let l = order[lhs.element.windowID] ?? Int.max
            let r = order[rhs.element.windowID] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }
        return sorted.map { _, window in
            WindowInfo(
                id: window.windowID,
                frame: window.frame,
                layer: window.windowLayer,
                ownerPID: window.owningApplication?.processID ?? 0,
                title: window.title
            )
        }
    }

    /// Einzelnes Fenster, unabhängig vom Desktop, optional mit Schatten.
    func captureWindow(_ id: UInt32, shadow: Bool) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = !shadow
        return try await captureImage(filter: filter, configuration: config)
    }

    // MARK: - Hilfen

    /// Monitore laut `NSScreen` (nur auf dem Main Actor verfügbar).
    @MainActor
    static func currentDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
            return DisplayInfo(id: number.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor)
        }
    }

    /// Fenster-ID → Position in der Reihenfolge von vorne nach hinten (laut Window Server).
    private static func frontToBackOrder() -> [UInt32: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return [:] }
        var order: [UInt32: Int] = [:]
        for (index, info) in list.enumerated() {
            if let number = info[kCGWindowNumber as String] as? NSNumber, order[number.uint32Value] == nil {
                order[number.uint32Value] = index
            }
        }
        return order
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }
    }

    private func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ error: any Error) -> CaptureError {
        if let error = error as? CaptureError { return error }
        if let error = error as? SCStreamError, error.code == .userDeclined { return .permissionDenied }
        return .failed(error.localizedDescription)
    }
}
