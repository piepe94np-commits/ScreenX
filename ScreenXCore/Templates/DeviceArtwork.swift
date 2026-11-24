import CoreGraphics
import CoreText
import Foundation

/// Self-drawn vector artwork of the built-in device frames (ruling R1). No logos, no brand marks.
///
/// Every frame is drawn in the coordinates of its template's `frameSize` (origin top-left, y down).
/// The screen area (`screenQuad`, rounded by `screenCornerRadius`) stays transparent: each layer that
/// covers it is filled through an even-odd path with the screen as a hole. Only the phone's camera
/// island is drawn on top of the screen area on purpose.
public enum DeviceArtwork {
    /// URL shown in the browser frame when no text is given.
    public static let defaultURLText = "example.com"

    /// Largest pixel side `image(builtin:scale:urlText:)` renders.
    public static let maxPixelSide = 16384

    /// The color space of all fills and of `image(builtin:scale:urlText:)`.
    static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Draws the frame of the built-in template `id` into `ctx`, scaled from `frameSize` to `size`.
    ///
    /// The current user space of `ctx` must have its origin at the top-left with y pointing down
    /// (as in `Renderer`); the frame fills `CGRect(origin: .zero, size: size)`. Unknown ids draw nothing.
    public static func draw(builtin id: String, in ctx: CGContext, size: CGSize, urlText: String?) {
        guard let template = TemplateCatalog.builtin(id: id),
              template.frameSize.width > 0, template.frameSize.height > 0,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              let variant = Variant(id: id) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: size.width / template.frameSize.width, y: size.height / template.frameSize.height)

        // Landscape variants: the portrait artwork, rotated exactly like `rotatedToLandscape`
        // ((x, y) → (H − y, x), H = portrait height = landscape width), so artwork and quad agree.
        var geometry = template
        if id.contains("-landscape-") {
            guard let portrait = TemplateCatalog.builtin(id: id.replacingOccurrences(of: "-landscape-",
                                                                                     with: "-portrait-"))
            else { return }
            ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: portrait.frameSize.height, ty: 0))
            geometry = portrait
        }

        let palette = Palette(variant)
        switch id.prefix(while: { $0 != "-" }) {
        case "laptop": drawLaptop(geometry, palette: palette, in: ctx)
        case "monitor": drawMonitor(geometry, palette: palette, in: ctx)
        case "phone": drawPhone(geometry, palette: palette, in: ctx)
        case "tablet": drawTablet(geometry, palette: palette, in: ctx)
        case "browser": drawBrowser(geometry, palette: palette, urlText: urlText ?? defaultURLText, in: ctx)
        default: break
        }
    }

    /// The frame of the built-in template `id` as an sRGB image with premultiplied alpha,
    /// `frameSize × scale` pixels (rounded). `nil` for unknown ids, an invalid scale, or when a side
    /// would exceed `maxPixelSide`.
    public static func image(builtin id: String, scale: CGFloat, urlText: String?) -> CGImage? {
        guard let template = TemplateCatalog.builtin(id: id), scale.isFinite, scale > 0 else { return nil }
        let limit = CGFloat(maxPixelSide)
        let w = (template.frameSize.width * scale).rounded(), h = (template.frameSize.height * scale).rounded()
        guard w <= limit, h <= limit else { return nil }
        let width = max(1, Int(w)), height = max(1, Int(h))
        guard let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(builtin: id, in: ctx, size: CGSize(width: width, height: height), urlText: urlText)
        return ctx.makeImage()
    }
}

// MARK: - Colors

extension DeviceArtwork {
    enum Variant {
        case silver, black, light, dark

        init?(id: String) {
            if id.hasSuffix("-silver") { self = .silver }
            else if id.hasSuffix("-black") { self = .black }
            else if id.hasSuffix("-light") { self = .light }
            else if id.hasSuffix("-dark") { self = .dark }
            else { return nil }
        }
    }

    /// An sRGB color with simple mixing, for deriving gradient stops.
    struct RGB {
        var r: CGFloat, g: CGFloat, b: CGFloat

        init(_ hex: UInt32) {
            r = CGFloat((hex >> 16) & 0xFF) / 255
            g = CGFloat((hex >> 8) & 0xFF) / 255
            b = CGFloat(hex & 0xFF) / 255
        }

        init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = r
            self.g = g
            self.b = b
        }

        func mixed(with other: RGB, _ t: CGFloat) -> RGB {
            RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
        }

        func lighter(_ t: CGFloat) -> RGB { mixed(with: RGB(0xFFFFFF), t) }
        func darker(_ t: CGFloat) -> RGB { mixed(with: RGB(0x000000), t) }
        func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    }

    /// Housing, outer edge and inner screen border of one color variant.
    struct Palette {
        var housing: RGB
        var edge: RGB
        var inner: RGB
        var isDark: Bool

        init(_ variant: Variant) {
            switch variant {
            case .silver:
                housing = RGB(0xE3E4E6); edge = RGB(0xC9CACD); inner = RGB(0x111111); isDark = false
            case .black:
                housing = RGB(0x2B2C2F); edge = RGB(0x1A1B1D); inner = RGB(0x000000); isDark = true
            case .light:
                housing = RGB(0xF5F5F7); edge = RGB(0xD2D2D7); inner = RGB(0x111111); isDark = false
            case .dark:
                housing = RGB(0x1D1D1F); edge = RGB(0x0E0E0F); inner = RGB(0x000000); isDark = true
            }
        }

        /// Top-to-bottom stops for a housing face: soft highlight on top, slightly deeper at the bottom.
        var faceStops: [CGColor] {
            isDark
                ? [housing.lighter(0.09).cg(), housing.cg(), housing.darker(0.18).cg()]
                : [housing.lighter(0.55).cg(), housing.cg(), housing.darker(0.05).cg()]
        }

        /// Thin bevel highlight along the inside of the outer edge.
        var highlight: CGColor { isDark ? CGColor(gray: 1, alpha: 0.10) : CGColor(gray: 1, alpha: 0.75) }
    }
}
