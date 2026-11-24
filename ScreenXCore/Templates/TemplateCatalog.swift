import CoreGraphics
import Foundation

/// The built-in device templates (self-drawn, see `DeviceArtwork`).
public enum TemplateCatalog {
    public static let builtins: [DeviceTemplate] = [
        laptop(id: "laptop-silver", name: String(localized: "Laptop, Silber")),
        laptop(id: "laptop-black", name: String(localized: "Laptop, Space-Schwarz")),
        monitor(id: "monitor-silver", name: String(localized: "Monitor, Silber")),
        monitor(id: "monitor-black", name: String(localized: "Monitor, Schwarz")),
        phone(id: "phone-portrait-light", name: String(localized: "Smartphone hoch, hell")),
        phone(id: "phone-portrait-dark", name: String(localized: "Smartphone hoch, dunkel")),
        phone(id: "phone-landscape-light", name: String(localized: "Smartphone quer, hell")).rotatedToLandscape,
        phone(id: "phone-landscape-dark", name: String(localized: "Smartphone quer, dunkel")).rotatedToLandscape,
        tablet(id: "tablet-portrait-light", name: String(localized: "Tablet hoch, hell")),
        tablet(id: "tablet-portrait-dark", name: String(localized: "Tablet hoch, dunkel")),
        tablet(id: "tablet-landscape-light", name: String(localized: "Tablet quer, hell")).rotatedToLandscape,
        tablet(id: "tablet-landscape-dark", name: String(localized: "Tablet quer, dunkel")).rotatedToLandscape,
        browser(id: "browser-light", name: String(localized: "Browserfenster, hell")),
        browser(id: "browser-dark", name: String(localized: "Browserfenster, dunkel")),
    ]

    public static func builtin(id: String) -> DeviceTemplate? {
        builtins.first { $0.id == id }
    }

    private static func make(_ id: String, _ name: String, frame: CGSize, screen: CGRect,
                             radius: Double, aspect: [Int]?) -> DeviceTemplate {
        DeviceTemplate(
            id: id, name: name, frame: .builtin(id), frameSize: frame,
            screenQuad: [CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.maxX, y: screen.minY),
                         CGPoint(x: screen.maxX, y: screen.maxY), CGPoint(x: screen.minX, y: screen.maxY)],
            screenCornerRadius: radius, preferredAspect: aspect)
    }

    private static func laptop(id: String, name: String) -> DeviceTemplate {
        make(id, name, frame: CGSize(width: 3000, height: 1900),
             screen: CGRect(x: 330, y: 120, width: 2340, height: 1462), radius: 18, aspect: [16, 10])
    }

    private static func monitor(id: String, name: String) -> DeviceTemplate {
        make(id, name, frame: CGSize(width: 2800, height: 2300),
             screen: CGRect(x: 100, y: 100, width: 2600, height: 1462), radius: 0, aspect: [16, 9])
    }

    /// Portrait geometry; landscape variants are rotated with `rotatedToLandscape`.
    private static func phone(id: String, name: String) -> DeviceTemplate {
        make(id, name, frame: CGSize(width: 1300, height: 2660),
             screen: CGRect(x: 60, y: 60, width: 1180, height: 2540), radius: 150, aspect: [1179, 2556])
    }

    /// Portrait geometry; landscape variants are rotated with `rotatedToLandscape`.
    private static func tablet(id: String, name: String) -> DeviceTemplate {
        make(id, name, frame: CGSize(width: 1800, height: 2340),
             screen: CGRect(x: 90, y: 90, width: 1620, height: 2160), radius: 40, aspect: [3, 4])
    }

    private static func browser(id: String, name: String) -> DeviceTemplate {
        make(id, name, frame: CGSize(width: 2400, height: 1500),
             screen: CGRect(x: 0, y: 88, width: 2400, height: 1412), radius: 0, aspect: nil)
    }
}

extension DeviceTemplate {
    /// The template rotated 90° clockwise: width and height swap, the quad is transformed and
    /// reordered so it stays top-left, top-right, bottom-right, bottom-left.
    var rotatedToLandscape: DeviceTemplate {
        let h = frameSize.height
        // Clockwise: (x, y) → (H − y, x). The old bottom-left corner becomes the new top-left.
        let rotated = screenQuad.map { CGPoint(x: h - $0.y, y: $0.x) }
        var copy = self
        copy.frameSize = CGSize(width: frameSize.height, height: frameSize.width)
        copy.screenQuad = [rotated[3], rotated[0], rotated[1], rotated[2]]
        copy.preferredAspect = preferredAspect.map { $0.count == 2 ? [$0[1], $0[0]] : $0 }
        return copy
    }
}
