import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenXCore

struct RendererTests {
    private struct RGBA: Equatable, CustomStringConvertible {
        var r, g, b, a: Int
        var description: String { "(\(r), \(g), \(b), \(a))" }

        func isClose(to other: RGBA, tolerance: Int = 3) -> Bool {
            abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance
                && abs(b - other.b) <= tolerance && abs(a - other.a) <= tolerance
        }
    }

    private static var srgb: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }
    private static let blue = RGBA(r: 0x20, g: 0x50, b: 0xFF, a: 255)
    private static let red = RGBA(r: 255, g: 0, b: 0, a: 255)

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// 200×100 image in `#2050FF` (sRGB).
    private static func blueImage() -> CGImage {
        let ctx = makeContext(width: 200, height: 100)
        ctx.setFillColor(CGColor(srgbRed: 0x20 / 255, green: 0x50 / 255, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return ctx.makeImage()!
    }

    /// 200×100, left half red, right half blue.
    private static func redBlueImage() -> CGImage {
        let ctx = makeContext(width: 200, height: 100)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0x20 / 255, green: 0x50 / 255, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        return ctx.makeImage()!
    }

    /// Reads a pixel, origin top-left, as straight (unpremultiplied) sRGB bytes.
    private static func pixel(_ image: CGImage, at x: Int, _ y: Int) -> RGBA {
        let ctx = makeContext(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * ctx.bytesPerRow + x * 4
        let a = Int(bytes[i + 3])
        func unpremultiply(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, (Int(v) * 255 + a / 2) / a) }
        return RGBA(r: unpremultiply(bytes[i]), g: unpremultiply(bytes[i + 1]),
                    b: unpremultiply(bytes[i + 2]), a: a)
    }

    private static func style(_ background: Background, radius: Double = 0, shadow: Double = 0) -> Style {
        var s = Style.default
        s.background = background
        s.cornerRadius = radius
        s.shadow = ShadowStyle(strength: shadow)
        return s
    }

    private static let redBackground = Background.solid(ColorValue(hex: "#FF0000")!)

    @Test func renderSizeMatchesLayout() throws {
        let input = RenderInput(original: Self.blueImage(), style: .default)
        let full = try #require(Renderer.render(input))
        #expect(full.width == 328)
        #expect(full.height == 228)
        let half = try #require(Renderer.render(input, outputScale: 0.5))
        #expect(half.width == 164)
        #expect(half.height == 114)
    }

    @Test func solidBackgroundCorner() throws {
        let input = RenderInput(original: Self.blueImage(), style: Self.style(Self.redBackground))
        let image = try #require(Renderer.render(input))
        let p = Self.pixel(image, at: 2, 2)
        #expect(p.isClose(to: Self.red), "\(p)")
    }

    @Test func imageCenterVisible() throws {
        let input = RenderInput(original: Self.blueImage(), style: .default)
        let image = try #require(Renderer.render(input))
        let p = Self.pixel(image, at: 64 + 100, 64 + 50)
        #expect(p.isClose(to: Self.blue, tolerance: 2), "\(p)")
    }

    @Test func cornerRadiusClips() throws {
        let input = RenderInput(original: Self.blueImage(), style: Self.style(Self.redBackground, radius: 30))
        let image = try #require(Renderer.render(input))
        let corner = Self.pixel(image, at: 65, 65)
        #expect(corner.isClose(to: Self.red), "\(corner)")
        let inside = Self.pixel(image, at: 64 + 30, 64 + 30)
        #expect(inside.isClose(to: Self.blue), "\(inside)")
    }

    @Test func noneBackgroundTransparent() throws {
        let input = RenderInput(original: Self.blueImage(), style: Self.style(.none))
        let image = try #require(Renderer.render(input))
        #expect(Self.pixel(image, at: 2, 2).a == 0)
    }

    @Test func shadowDarkensBelow() throws {
        let white = Background.solid(ColorValue(hex: "#FFFFFF")!)
        let input = RenderInput(original: Self.blueImage(), style: Self.style(white, shadow: 100))
        let image = try #require(Renderer.render(input))
        // Image spans y 64..<164; 10 px below its bottom edge, horizontally centered.
        let p = Self.pixel(image, at: 64 + 100, 164 + 10)
        #expect(p.r < 250 && p.g < 250 && p.b < 250, "\(p)")
        // Without shadow the same pixel stays white.
        let plain = try #require(Renderer.render(RenderInput(original: Self.blueImage(), style: Self.style(white))))
        #expect(Self.pixel(plain, at: 64 + 100, 164 + 10).isClose(to: RGBA(r: 255, g: 255, b: 255, a: 255)))
        // The shadow falls downwards: 10 px below the image is clearly darker than 10 px above it.
        let above = Self.pixel(image, at: 64 + 100, 64 - 10)
        #expect(p.r + 10 < above.r, "below \(p) vs above \(above)")
    }

    @Test func shadowScalesWithOutputScale() throws {
        let white = Background.solid(ColorValue(hex: "#FFFFFF")!)
        let input = RenderInput(original: Self.blueImage(), style: Self.style(white, shadow: 100))
        let one = try #require(Renderer.render(input))
        let two = try #require(Renderer.render(input, outputScale: 2))
        for (x, y) in [(64 + 100, 164 + 10), (64 + 100, 164 + 30)] {
            let a = Self.pixel(one, at: x, y)
            let b = Self.pixel(two, at: 2 * x, 2 * y)
            #expect(a.r < 250, "(\(x), \(y)) should be in the shadow: \(a)")
            #expect(a.isClose(to: b, tolerance: 8), "(\(x), \(y)): 1x \(a) vs 2x \(b)")
        }
    }

    @Test func transparentCornersStayClean() throws {
        let ctx = Self.makeContext(width: 200, height: 100)
        ctx.setFillColor(CGColor(srgbRed: 0x20 / 255, green: 0x50 / 255, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        for corner in [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 190, y: 0, width: 10, height: 10),
                       CGRect(x: 0, y: 90, width: 10, height: 10), CGRect(x: 190, y: 90, width: 10, height: 10)] {
            ctx.clear(corner)
        }
        let original = try #require(ctx.makeImage())
        let white = Background.solid(ColorValue(hex: "#FFFFFF")!)
        let image = try #require(Renderer.render(RenderInput(original: original,
                                                             style: Self.style(white, radius: 0, shadow: 50))))
        // Image-local (2, 2) lies in the transparent top-left corner.
        let p = Self.pixel(image, at: 64 + 2, 64 + 2)
        #expect(p.r > 230 && p.g > 230 && p.b > 230, "\(p)")
    }

    @Test func gradientDirection135() throws {
        let stops = [GradientStop(color: ColorValue(hex: "#000000")!, location: 0),
                     GradientStop(color: ColorValue(hex: "#FFFFFF")!, location: 1)]
        let input = RenderInput(original: Self.blueImage(),
                                style: Self.style(.gradient(stops: stops, angle: 135)))
        let image = try #require(Renderer.render(input))
        let topLeft = Self.pixel(image, at: 2, 2)
        let bottomRight = Self.pixel(image, at: image.width - 3, image.height - 3)
        #expect(topLeft.r < bottomRight.r, "\(topLeft) vs \(bottomRight)")
        #expect(topLeft.r < 30, "\(topLeft)")
        #expect(bottomRight.r > 225, "\(bottomRight)")
    }

    @Test func cropApplied() throws {
        let input = RenderInput(original: Self.redBlueImage(), crop: CGRect(x: 100, y: 0, width: 100, height: 100),
                                style: Self.style(.none))
        let image = try #require(Renderer.render(input))
        #expect(image.width == 100 + 128)
        #expect(image.height == 100 + 128)
        for x in [65, 64 + 50, 64 + 98] {
            let p = Self.pixel(image, at: x, 64 + 50)
            #expect(p.isClose(to: Self.blue), "x=\(x): \(p)")
        }
    }

    @Test func jpegFlattensTransparencyOnWhite() throws {
        let input = RenderInput(original: Self.blueImage(), style: Self.style(.none))
        let image = try #require(Renderer.render(input))
        let data = try ImageExporter.data(for: image, scale: 1, format: .jpeg, jpegQuality: 0.9)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let p = Self.pixel(decoded, at: 2, 2)
        #expect(p.r > 245 && p.g > 245 && p.b > 245, "\(p)")
    }

    @Test func writesSnapshots() throws {
        let original = TestImages.gradient(width: 800, height: 500)

        var blurred = Style.default
        blurred.background = .blurredScreenshot(radius: 40)

        var wide = Style.default
        wide.aspect = .r16x9
        wide.alignment = .topLeading

        let scenes: [(String, Style)] = [
            ("preset1-default", .default),
            ("solid-radius30", Self.style(.solid(ColorValue(hex: "#3A7BD5")!), radius: 30, shadow: 50)),
            ("blurred-screenshot", blurred),
            ("aspect16x9-topLeading", wide),
        ]
        for (name, style) in scenes {
            let image = try #require(Renderer.render(RenderInput(original: original, style: style)), "\(name)")
            RenderSnapshot.write(image, name: name)
            let url = RenderSnapshot.directory.appendingPathComponent("\(name).png")
            #expect(FileManager.default.fileExists(atPath: url.path), "\(name)")
        }
    }
}
