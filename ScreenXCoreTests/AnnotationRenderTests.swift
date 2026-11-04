import CoreGraphics
import Foundation
import Testing
@testable import ScreenXCore

struct AnnotationRenderTests {
    private struct RGBA: Equatable, CustomStringConvertible {
        var r, g, b, a: Int
        var description: String { "(\(r), \(g), \(b), \(a))" }

        func isClose(to other: RGBA, tolerance: Int = 3) -> Bool {
            abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance
                && abs(b - other.b) <= tolerance && abs(a - other.a) <= tolerance
        }

        var isWhite: Bool { isClose(to: RGBA(r: 255, g: 255, b: 255, a: 255)) }
    }

    private static let red = ColorValue(hex: "#FF0000")!
    private static let blue = ColorValue(hex: "#0000FF")!
    private static let yellow = ColorValue(hex: "#FFCC00")!
    private static let redPixel = RGBA(r: 255, g: 0, b: 0, a: 255)
    private static let bluePixel = RGBA(r: 0, g: 0, b: 255, a: 255)

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// 200×100, white; `draw` paints on top in a top-left-origin space.
    private static func original(_ draw: (CGContext) -> Void = { _ in }) -> CGImage {
        let ctx = makeContext(width: 200, height: 100)
        ctx.translateBy(x: 0, y: 100)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        draw(ctx)
        return ctx.makeImage()!
    }

    /// White canvas, padding 0, shadow 0, radius 0: canvas pixels == original pixels.
    private static var plainStyle: Style {
        var s = Style.default
        s.background = .solid(ColorValue(hex: "#FFFFFF")!)
        s.padding = 0
        s.cornerRadius = 0
        s.shadow = ShadowStyle(strength: 0)
        s.aspect = .auto
        return s
    }

    private static func render(_ annotations: [Annotation], original: CGImage = original(),
                               crop: CGRect? = nil) throws -> CGImage {
        try #require(Renderer.render(RenderInput(original: original, crop: crop, style: plainStyle,
                                                 annotations: annotations)))
    }

    /// Pixels of an image, origin top-left, as straight (unpremultiplied) sRGB bytes.
    private struct Bitmap {
        let width: Int
        private let bytes: [UInt8]

        init(_ image: CGImage) {
            let ctx = AnnotationRenderTests.makeContext(width: image.width, height: image.height)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            width = image.width
            bytes = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        }

        subscript(x: Int, y: Int) -> RGBA {
            let i = (y * width + x) * 4
            let a = Int(bytes[i + 3])
            func unpremultiply(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, (Int(v) * 255 + a / 2) / a) }
            return RGBA(r: unpremultiply(bytes[i]), g: unpremultiply(bytes[i + 1]),
                        b: unpremultiply(bytes[i + 2]), a: a)
        }
    }

    private static func pixel(_ image: CGImage, at x: Int, _ y: Int) -> RGBA { Bitmap(image)[x, y] }

    private static func shape(_ rect: CGRect, filled: Bool, color: ColorValue = blue, rotation: Double = 0)
        -> Annotation {
        Annotation(kind: .shape(kind: .rectangle, rect: rect, filled: filled), color: color, rotation: rotation)
    }

    @Test func arrowDrawsColor() throws {
        let arrow = Annotation(kind: .arrow(start: CGPoint(x: 20, y: 50), end: CGPoint(x: 180, y: 50),
                                            control: nil, head: .filled),
                               color: Self.red, strokeWidth: 6)
        let image = try Self.render([arrow])
        let p = Self.pixel(image, at: 100, 50)
        #expect(p.isClose(to: Self.redPixel), "\(p)")
        // The filled head is wider than the shaft.
        let head = Self.pixel(image, at: 168, 54)
        #expect(head.isClose(to: Self.redPixel), "\(head)")
        #expect(Self.pixel(image, at: 100, 56).isWhite)
    }

    @Test func filledShape() throws {
        let image = try Self.render([Self.shape(CGRect(x: 10, y: 10, width: 50, height: 50), filled: true)])
        let p = Self.pixel(image, at: 35, 35)
        #expect(p.isClose(to: Self.bluePixel), "\(p)")
    }

    @Test func outlineShapeHollow() throws {
        let image = try Self.render([Self.shape(CGRect(x: 10, y: 10, width: 50, height: 50), filled: false)])
        let inside = Self.pixel(image, at: 35, 35)
        #expect(inside.isWhite, "\(inside)")
        let border = Self.pixel(image, at: 10, 35)
        #expect(border.isClose(to: Self.bluePixel), "\(border)")
    }

    @Test func counterDrawsCircle() throws {
        let counter = Annotation(kind: .counter(center: CGPoint(x: 100, y: 50), number: 1, radius: 20),
                                 color: Self.red)
        let image = try Self.render([counter])
        let p = Self.pixel(image, at: 100, 40)
        #expect(p.isClose(to: Self.redPixel), "\(p)")
        #expect(Self.pixel(image, at: 100, 25).isWhite)
    }

    @Test func blurChangesPixels() throws {
        let striped = Self.original { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 100, y: 0, width: 3, height: 100))
        }
        #expect(Self.pixel(try Self.render([], original: striped), at: 101, 50).r < 10)
        let blur = Annotation(kind: .blur(rect: CGRect(x: 80, y: 0, width: 40, height: 100), mode: .blur,
                                          strength: 10))
        let image = try Self.render([blur], original: striped)
        let p = Self.pixel(image, at: 101, 50)
        #expect(p.r > 30, "\(p)")
        // Outside the blur rect the original is untouched.
        #expect(Self.pixel(image, at: 60, 50).isWhite)
    }

    @Test func pixelateBlocks() throws {
        let gradient = TestImages.gradient(width: 200, height: 100)
        let pixelate = Annotation(kind: .blur(rect: CGRect(x: 0, y: 0, width: 200, height: 100), mode: .pixelate,
                                              strength: 20))
        let plain = try Self.render([], original: gradient)
        #expect(!Self.pixel(plain, at: 0, 0).isClose(to: Self.pixel(plain, at: 10, 10)))
        let image = try Self.render([pixelate], original: gradient)
        let a = Self.pixel(image, at: 0, 0), b = Self.pixel(image, at: 10, 10)
        #expect(a.isClose(to: b, tolerance: 2), "\(a) vs \(b)")
    }

    @Test func highlightMultiplies() throws {
        let highlight = Annotation(kind: .highlight(rect: CGRect(x: 50, y: 25, width: 100, height: 50)),
                                   color: Self.yellow)
        let image = try Self.render([highlight])
        let p = Self.pixel(image, at: 100, 50)
        #expect(p.r > 240 && p.b < 200 && p.b + 40 < p.g, "\(p)")
        #expect(!p.isWhite, "\(p)")
        // Over blue, multiply keeps red and green at 0: ≈ (0, 0, 153). Normal blending gives ≈ (102, 82, 153).
        let blueOriginal = Self.original { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        let overBlue = Self.pixel(try Self.render([highlight], original: blueOriginal), at: 100, 50)
        #expect(overBlue.isClose(to: RGBA(r: 0, g: 0, b: 153, a: 255), tolerance: 6), "\(overBlue)")
    }

    @Test func highlightClippedToImage() throws {
        var style = Self.plainStyle
        style.padding = 20
        let highlight = Annotation(kind: .highlight(rect: CGRect(x: -20, y: 40, width: 60, height: 20)),
                                   color: Self.yellow)
        let image = try #require(Renderer.render(RenderInput(original: Self.original(), style: style,
                                                             annotations: [highlight])))
        // Canvas x 10 is padding (original x −10): not highlighted. Canvas x 30 is original x 10: highlighted.
        #expect(Self.pixel(image, at: 10, 70).isWhite)
        #expect(!Self.pixel(image, at: 30, 70).isWhite)
    }

    @Test func annotationsOutsideCropKeptButClipped() throws {
        let outside = Self.shape(CGRect(x: 150, y: 10, width: 20, height: 20), filled: true)
        let crop = CGRect(x: 0, y: 0, width: 100, height: 100)
        let image = try Self.render([outside], crop: crop)
        #expect(image.width == 100)
        for y in stride(from: 0, to: 100, by: 5) {
            for x in stride(from: 0, to: 100, by: 5) {
                #expect(Self.pixel(image, at: x, y).isWhite, "(\(x), \(y))")
            }
        }
        let model = DocumentModel(original: OriginalInfo(pixelWidth: 200, pixelHeight: 100, scale: 2),
                                  crop: crop, style: Self.plainStyle, annotations: [outside])
        let decoded = try JSONDecoder().decode(DocumentModel.self, from: JSONEncoder().encode(model))
        #expect(decoded.annotations == [outside])
    }

    @Test func annotationsInCroppedAwayAreaSkipped() throws {
        var style = Self.plainStyle
        style.padding = 64
        let crop = CGRect(x: 0, y: 0, width: 100, height: 100)
        let outside = Self.shape(CGRect(x: 150, y: 10, width: 20, height: 20), filled: true)
        let overlapping = Self.shape(CGRect(x: 90, y: 60, width: 20, height: 20), filled: true)
        let image = try #require(Renderer.render(RenderInput(original: Self.original(), crop: crop, style: style,
                                                             annotations: [outside, overlapping])))
        #expect(image.width == 228)
        let bitmap = Bitmap(image)
        // `outside` would land at canvas x 214..<234, y 74..<94 (padding): it is skipped.
        for y in stride(from: 70, to: 100, by: 2) {
            for x in stride(from: 166, to: 228, by: 2) {
                #expect(bitmap[x, y].isWhite, "(\(x), \(y)): \(bitmap[x, y])")
            }
        }
        // `overlapping` meets the crop and draws unclipped into the padding (canvas x 154..<174).
        #expect(bitmap[158, 134].isClose(to: Self.bluePixel))
        #expect(bitmap[170, 134].isClose(to: Self.bluePixel))
    }

    @Test func curvedArrowControlNearEnd() throws {
        // Control 5 px from the end: the head follows the curve's tangent where the shaft meets it.
        let arrow = Annotation(kind: .arrow(start: CGPoint(x: 20, y: 50), end: CGPoint(x: 180, y: 50),
                                            control: CGPoint(x: 177, y: 46), head: .filled),
                               color: Self.red, strokeWidth: 6)
        let bitmap = Bitmap(try Self.render([arrow]))
        for x in [170, 174] {
            #expect(bitmap[x, 50].isClose(to: Self.redPixel, tolerance: 30), "(\(x), 50): \(bitmap[x, 50])")
        }
        // Nothing beyond the tip.
        for y in 20..<80 {
            for x in 182..<200 {
                #expect(bitmap[x, y].isWhite, "(\(x), \(y)): \(bitmap[x, y])")
            }
        }
    }

    @Test func annotationsFollowCrop() throws {
        let rect = Self.shape(CGRect(x: 150, y: 40, width: 20, height: 20), filled: true)
        let image = try Self.render([rect], crop: CGRect(x: 100, y: 0, width: 100, height: 100))
        // Original x 160 lies at canvas x 60 when the crop starts at x 100.
        #expect(Self.pixel(image, at: 60, 50).isClose(to: Self.bluePixel))
        #expect(Self.pixel(image, at: 40, 50).isWhite)
    }

    @Test func rotationApplied() throws {
        let rotated = Self.shape(CGRect(x: 90, y: 40, width: 20, height: 20), filled: true, rotation: .pi / 4)
        let image = try Self.render([rotated])
        let center = Self.pixel(image, at: 100, 50)
        #expect(center.isClose(to: Self.bluePixel), "\(center)")
        // An unrotated corner lies outside the diamond; its tip at the right reaches past the square.
        #expect(Self.pixel(image, at: 91, 41).isWhite)
        #expect(Self.pixel(image, at: 112, 50).isClose(to: Self.bluePixel, tolerance: 40))
    }

    @Test func textDrawsUpright() throws {
        let text = Annotation(kind: .text(frame: CGRect(x: 10, y: 10, width: 180, height: 40), string: "T",
                                          fontSize: 40, bold: true, background: nil),
                              color: Self.red)
        let image = try Self.render([text])
        let bitmap = Bitmap(image)
        // Ink (red, so low green) per row; the glyph lies inside the frame.
        let inkRows = (0..<image.height).map { y in (0..<image.width).filter { bitmap[$0, y].g < 128 }.count }
        let inked = inkRows.indices.filter { inkRows[$0] > 0 }
        let first = try #require(inked.first), last = try #require(inked.last)
        #expect(first >= 10 && last < 60, "rows \(first)...\(last)")
        // A "T" has its bar at the top: the top rows are much wider than the bottom rows (the stem).
        let top = inkRows[first..<(first + 3)].reduce(0, +), bottom = inkRows[(last - 2)...last].reduce(0, +)
        #expect(top > 2 * bottom, "top \(top), bottom \(bottom)")
    }

    @Test func noteDrawsFill() throws {
        let note = Annotation(kind: .note(frame: CGRect(x: 20, y: 20, width: 120, height: 60), string: "",
                                          noteColor: AnnotationPalette.noteColors[0]))
        let image = try Self.render([note])
        #expect(Self.pixel(image, at: 30, 30).isClose(to: RGBA(r: 0xFF, g: 0xE0, b: 0x66, a: 255)))
        // The shadow falls downwards.
        let below = Self.pixel(image, at: 80, 83), above = Self.pixel(image, at: 80, 17)
        #expect(below.r < above.r, "below \(below), above \(above)")
    }

    @Test func writesAnnotationSnapshots() throws {
        // Gradient with black and white stripes under the blur and pixelate rects, so both are visible.
        let ctx = Self.makeContext(width: 800, height: 500)
        ctx.draw(TestImages.gradient(width: 800, height: 500), in: CGRect(x: 0, y: 0, width: 800, height: 500))
        for (i, x) in stride(from: 540, to: 780, by: 10).enumerated() {
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: x, y: 180, width: 5, height: 300))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: x + 5, y: 180 + (i % 2) * 20, width: 5, height: 280))
        }
        let original = try #require(ctx.makeImage())
        let annotations: [Annotation] = [
            Annotation(kind: .highlight(rect: CGRect(x: 40, y: 380, width: 300, height: 40)),
                       color: ColorValue(hex: "#FFCC00")!),
            Annotation(kind: .blur(rect: CGRect(x: 560, y: 40, width: 200, height: 120), mode: .blur,
                                   strength: 12)),
            Annotation(kind: .blur(rect: CGRect(x: 560, y: 180, width: 200, height: 120), mode: .pixelate,
                                   strength: 16)),
            Annotation(kind: .arrow(start: CGPoint(x: 60, y: 60), end: CGPoint(x: 260, y: 160), control: nil,
                                    head: .filled)),
            Annotation(kind: .arrow(start: CGPoint(x: 60, y: 200), end: CGPoint(x: 300, y: 220),
                                    control: CGPoint(x: 180, y: 120), head: .open),
                       color: ColorValue(hex: "#34C759")!),
            Annotation(kind: .arrow(start: CGPoint(x: 60, y: 300), end: CGPoint(x: 300, y: 300), control: nil,
                                    head: .double),
                       color: ColorValue(hex: "#0A84FF")!, strokeWidth: 4),
            Annotation(kind: .shape(kind: .rectangle, rect: CGRect(x: 340, y: 40, width: 160, height: 90),
                                    filled: false)),
            Annotation(kind: .shape(kind: .roundedRectangle, rect: CGRect(x: 340, y: 150, width: 160, height: 90),
                                    filled: true),
                       color: ColorValue(hex: "#AF52DE")!, rotation: 0.2),
            Annotation(kind: .shape(kind: .ellipse, rect: CGRect(x: 340, y: 260, width: 160, height: 90),
                                    filled: false),
                       color: ColorValue(hex: "#FF9500")!),
            Annotation(kind: .shape(kind: .line, rect: CGRect(x: 500, y: 480, width: -150, height: -100),
                                    filled: false),
                       color: ColorValue(hex: "#1D1D1F")!, strokeWidth: 3),
            Annotation(kind: .text(frame: CGRect(x: 40, y: 430, width: 280, height: 30),
                                   string: "Beschriftung mit Box", fontSize: 24, bold: true,
                                   background: ColorValue(hex: "#1D1D1F")!),
                       color: ColorValue(hex: "#FFFFFF")!),
            Annotation(kind: .note(frame: CGRect(x: 520, y: 330, width: 260, height: 150),
                                   string: "Notiz:\nmehrzeilig und umbrochen",
                                   noteColor: AnnotationPalette.noteColors[0])),
            Annotation(kind: .counter(center: CGPoint(x: 30, y: 30), number: 1, radius: 18)),
            Annotation(kind: .counter(center: CGPoint(x: 520, y: 30), number: 2, radius: 18)),
            Annotation(kind: .counter(center: CGPoint(x: 790, y: 12), number: 12, radius: 18),
                       color: ColorValue(hex: "#0A84FF")!),
            Annotation(kind: .text(frame: CGRect(x: 640, y: 485, width: 220, height: 30),
                                   string: "Ragt über den Rand", fontSize: 22, bold: false, background: nil),
                       color: ColorValue(hex: "#FFFFFF")!),
        ]
        var style = Style.default
        style.cornerRadius = 16
        for (name, scale) in [("annotations-all", CGFloat(1)), ("annotations-all@2x", CGFloat(2))] {
            let input = RenderInput(original: original, style: style, annotations: annotations,
                                    originalScale: 2)
            let image = try #require(Renderer.render(input, outputScale: scale), "\(name)")
            RenderSnapshot.write(image, name: name)
            let url = RenderSnapshot.directory.appendingPathComponent("\(name).png")
            #expect(FileManager.default.fileExists(atPath: url.path), "\(name)")
        }
    }
}
