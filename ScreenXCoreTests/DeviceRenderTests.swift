import CoreGraphics
import Foundation
import Testing
@testable import ScreenXCore

struct DeviceRenderTests {
    private struct RGBA: Equatable, CustomStringConvertible {
        var r, g, b, a: Int
        var description: String { "(\(r), \(g), \(b), \(a))" }

        func isClose(to other: RGBA, tolerance: Int = 4) -> Bool {
            abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance
                && abs(b - other.b) <= tolerance && abs(a - other.a) <= tolerance
        }
    }

    private static var srgb: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }
    private static let blue = RGBA(r: 0x20, g: 0x50, b: 0xFF, a: 255)
    private static let red = RGBA(r: 255, g: 0, b: 0, a: 255)
    private static let white = RGBA(r: 255, g: 255, b: 255, a: 255)

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func solid(width: Int, height: Int, hex: String) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        ctx.setFillColor(ColorValue(hex: hex)!.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
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

    private static func pixel(_ image: CGImage, at p: CGPoint) -> RGBA {
        pixel(image, at: Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
    }

    private static func bytes(_ image: CGImage) -> [UInt8] {
        let ctx = makeContext(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self),
                                         count: ctx.bytesPerRow * image.height))
    }

    private static func style(background: String? = "#FFFFFF", padding: Double = 0, radius: Double = 0,
                              shadow: Double = 0, tilt: Tilt = .zero) -> Style {
        var s = Style.default
        s.background = background.map { .solid(ColorValue(hex: $0)!) } ?? .none
        s.padding = padding
        s.cornerRadius = radius
        s.shadow = ShadowStyle(strength: shadow)
        s.tilt = tilt
        return s
    }

    private static let phone = TemplateCatalog.builtin(id: "phone-portrait-light")!

    /// Frame point → canvas point for a render with padding 0, no tilt.
    private static func canvasPoint(_ p: CGPoint, template: DeviceTemplate, contentSize: CGSize) -> CGPoint {
        let layout = DeviceCompositor.layout(template: template, contentSize: contentSize, tilt: .zero)
        return CGPoint(x: p.x * layout.frameScale, y: p.y * layout.frameScale)
    }

    @Test func mockupContainsScreenshotInScreen() throws {
        let content = Self.solid(width: 393, height: 852, hex: "#2050FF")
        let size = CGSize(width: 393, height: 852)
        let input = RenderInput(original: content, style: Self.style(), template: Self.phone,
                                placement: TemplatePlacement(templateID: Self.phone.id))
        let image = try #require(Renderer.render(input))
        let layout = DeviceCompositor.layout(template: Self.phone, contentSize: size, tilt: .zero)
        #expect(image.width == Int(layout.deviceSize.width.rounded()))
        #expect(image.height == Int(layout.deviceSize.height.rounded()))

        let screen = Self.phone.screenBounds
        let center = Self.canvasPoint(CGPoint(x: screen.midX, y: screen.midY), template: Self.phone, contentSize: size)
        #expect(Self.pixel(image, at: center).isClose(to: Self.blue), "\(Self.pixel(image, at: center))")

        // Bezel (housing face, 25 units left of the screen at mid height) has the artwork's color.
        let bezelFrame = CGPoint(x: screen.minX - 25, y: screen.midY)
        let bezel = Self.pixel(image, at: Self.canvasPoint(bezelFrame, template: Self.phone, contentSize: size))
        let artwork = try #require(DeviceArtwork.image(builtin: Self.phone.id, scale: layout.frameScale, urlText: nil))
        let expected = Self.pixel(artwork, at: CGPoint(x: bezelFrame.x * layout.frameScale,
                                                       y: bezelFrame.y * layout.frameScale))
        #expect(expected.a == 255)
        #expect(bezel.isClose(to: expected, tolerance: 6), "bezel \(bezel) vs artwork \(expected)")
        #expect(!bezel.isClose(to: Self.blue, tolerance: 40))
    }

    @Test func fitUsesFillColor() throws {
        let content = Self.solid(width: 320, height: 180, hex: "#2050FF")
        let size = CGSize(width: 320, height: 180)
        let placement = TemplatePlacement(templateID: Self.phone.id, fit: .fit, fillColor: ColorValue(hex: "#FF0000")!)
        let input = RenderInput(original: content, style: Self.style(), template: Self.phone, placement: placement)
        let image = try #require(Renderer.render(input))
        let screen = Self.phone.screenBounds
        // Top of the screen (15 % down, left of the camera island) is letterbox, the middle is content.
        let top = Self.canvasPoint(CGPoint(x: screen.minX + screen.width * 0.25, y: screen.minY + screen.height * 0.15),
                                   template: Self.phone, contentSize: size)
        #expect(Self.pixel(image, at: top).isClose(to: Self.red), "\(Self.pixel(image, at: top))")
        let mid = Self.canvasPoint(CGPoint(x: screen.midX, y: screen.midY), template: Self.phone, contentSize: size)
        #expect(Self.pixel(image, at: mid).isClose(to: Self.blue), "\(Self.pixel(image, at: mid))")
    }

    @Test func fillCropsContentToScreen() throws {
        // 16:9 content, left half red, right half blue, in the portrait phone with fill and offset -1:
        // the left edge of the content is shown, so the whole screen is red.
        let ctx = Self.makeContext(width: 320, height: 180)
        ctx.setFillColor(ColorValue(hex: "#FF0000")!.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 180))
        ctx.setFillColor(ColorValue(hex: "#2050FF")!.cgColor)
        ctx.fill(CGRect(x: 160, y: 0, width: 160, height: 180))
        let content = try #require(ctx.makeImage())
        let size = CGSize(width: 320, height: 180)
        let placement = TemplatePlacement(templateID: Self.phone.id, fit: .fill, offset: CGPoint(x: -1, y: 0))
        let image = try #require(Renderer.render(RenderInput(original: content, style: Self.style(),
                                                             template: Self.phone, placement: placement)))
        let screen = Self.phone.screenBounds
        for fx in [0.2, 0.5, 0.8] {
            let p = Self.canvasPoint(CGPoint(x: screen.minX + screen.width * fx, y: screen.midY),
                                     template: Self.phone, contentSize: size)
            #expect(Self.pixel(image, at: p).isClose(to: Self.red), "x \(fx): \(Self.pixel(image, at: p))")
        }
    }

    @Test func tiltChangesShape() throws {
        let content = Self.solid(width: 300, height: 200, hex: "#2050FF")
        let input = RenderInput(original: content, style: Self.style(background: "#FF0000", padding: 20,
                                                                    tilt: Tilt(x: 0, y: 20)))
        let image = try #require(Renderer.render(input))
        let layout = DeviceCompositor.layout(template: nil, contentSize: CGSize(width: 300, height: 200),
                                             tilt: Tilt(x: 0, y: 20))
        let canvas = CanvasLayout.compute(contentSize: layout.imageSize, style: input.style)
        let rect = canvas.imageRect
        #expect(image.width == Int(canvas.canvasSize.width.rounded()))
        // Positive y tilt moves the right edge away: the right edge is shorter, so the top-right corner
        // of the image rectangle is background, while the near left edge spans the full height.
        let topRight = Self.pixel(image, at: CGPoint(x: rect.maxX - 3, y: rect.minY + 3))
        #expect(topRight.isClose(to: Self.red), "top right \(topRight)")
        let topLeft = Self.pixel(image, at: CGPoint(x: rect.minX + 3, y: rect.minY + 3))
        #expect(topLeft.isClose(to: Self.blue, tolerance: 8), "top left \(topLeft)")
        // Without tilt the same top-right pixel is image.
        let plain = try #require(Renderer.render(RenderInput(original: content,
                                                             style: Self.style(background: "#FF0000", padding: 20))))
        #expect(Self.pixel(plain, at: 20 + 297, 20 + 3).isClose(to: Self.blue))
    }

    @Test func tiltAppliesCornerRadiusBeforeTilt() throws {
        let content = Self.solid(width: 300, height: 200, hex: "#2050FF")
        let tilt = Tilt(x: 0, y: -10)
        let input = RenderInput(original: content, style: Self.style(background: "#FF0000", radius: 40, tilt: tilt))
        let image = try #require(Renderer.render(input))
        // Negative y tilt: the left edge is far, the right edge near and full height. The right corner
        // of the bounding box is rounded away.
        let p = Self.pixel(image, at: image.width - 3, 3)
        #expect(p.isClose(to: Self.red), "\(p)")
        let inside = Self.pixel(image, at: image.width - 45, 45)
        #expect(inside.isClose(to: Self.blue, tolerance: 8), "\(inside)")
    }

    @Test func missingTemplateRendersPlain() throws {
        let content = Self.solid(width: 200, height: 100, hex: "#2050FF")
        let style = Self.style(padding: 30, radius: 12, shadow: 40)
        let plain = try #require(Renderer.render(RenderInput(original: content, style: style)))
        let missing = try #require(Renderer.render(RenderInput(
            original: content, style: style, template: nil,
            placement: TemplatePlacement(templateID: "gone-template"))))
        #expect(missing.width == plain.width && missing.height == plain.height)
        #expect(Self.bytes(missing) == Self.bytes(plain))
    }

    @Test func templateIgnoresCornerRadius() throws {
        let content = Self.solid(width: 393, height: 852, hex: "#2050FF")
        let a = try #require(Renderer.render(RenderInput(original: content, style: Self.style(radius: 0),
                                                         template: Self.phone)))
        let b = try #require(Renderer.render(RenderInput(original: content, style: Self.style(radius: 400),
                                                         template: Self.phone)))
        #expect(Self.bytes(a) == Self.bytes(b))
    }

    @Test func shadowFollowsDeviceAlpha() throws {
        let content = Self.solid(width: 393, height: 852, hex: "#2050FF")
        let size = CGSize(width: 393, height: 852)
        let style = Self.style(padding: 64, shadow: 100)
        let image = try #require(Renderer.render(RenderInput(original: content, style: style, template: Self.phone)))
        let layout = DeviceCompositor.layout(template: Self.phone, contentSize: size, tilt: .zero)
        let rect = CanvasLayout.compute(contentSize: layout.imageSize, style: style).imageRect
        // Bottom of the phone body: the frame has a transparent 14-unit margin; probe 10 px below the frame.
        let below = Self.pixel(image, at: CGPoint(x: rect.midX, y: rect.maxY + 10))
        #expect(below.r < 245 && below.g < 245 && below.b < 245, "below \(below)")
        let noShadow = try #require(Renderer.render(RenderInput(original: content, style: Self.style(padding: 64),
                                                                template: Self.phone)))
        #expect(Self.pixel(noShadow, at: CGPoint(x: rect.midX, y: rect.maxY + 10)).isClose(to: Self.white))
        // The body's rounded bottom-left corner is transparent in the frame: the shadow there is lighter
        // than in the margin right below the body, so it follows the device's outline.
        let corner = Self.pixel(image, at: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
        let edge = Self.pixel(image, at: CGPoint(x: rect.midX, y: rect.maxY - 2))
        #expect(corner.a == 255 && edge.a == 255)
        #expect(corner.r > edge.r, "corner \(corner) vs bottom edge \(edge)")
    }

    @Test func customFrameAndSkewedQuad() throws {
        // Custom 200×200 frame: grey with a transparent hole (50…150), and a skewed quad inside it.
        let frameCtx = Self.makeContext(width: 200, height: 200)
        frameCtx.setFillColor(ColorValue(hex: "#808080")!.cgColor)
        frameCtx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        frameCtx.clear(CGRect(x: 50, y: 50, width: 100, height: 100))
        let frame = try #require(frameCtx.makeImage())
        let skewed = DeviceTemplate(
            id: "custom-skew", name: "Skew", frame: .file("skew.png"), frameSize: CGSize(width: 200, height: 200),
            screenQuad: [CGPoint(x: 60, y: 50), CGPoint(x: 150, y: 50), CGPoint(x: 140, y: 150), CGPoint(x: 50, y: 150)],
            screenCornerRadius: 0, preferredAspect: nil)
        let content = Self.solid(width: 90, height: 100, hex: "#2050FF")
        let input = RenderInput(original: content, style: Self.style(), template: skewed, customFrameImage: frame)
        let image = try #require(Renderer.render(input))
        let scale = DeviceCompositor.layout(template: skewed, contentSize: CGSize(width: 90, height: 100),
                                            tilt: .zero).frameScale
        func at(_ x: CGFloat, _ y: CGFloat) -> RGBA { Self.pixel(image, at: CGPoint(x: x * scale, y: y * scale)) }
        #expect(at(100, 100).isClose(to: Self.blue, tolerance: 8), "center \(at(100, 100))")
        #expect(at(20, 20).isClose(to: RGBA(r: 128, g: 128, b: 128, a: 255), tolerance: 3), "frame \(at(20, 20))")
        // Left of the skewed top edge but inside the hole: neither screen nor frame (white background).
        #expect(at(53, 55).isClose(to: Self.white, tolerance: 20), "outside quad \(at(53, 55))")
    }

    /// Task 6 contract: `Renderer.layout(for:)` plus `screenToContentTransform` locate content pixels on
    /// the rendered canvas (crop, fill with offset, padding, output scale 2).
    @Test func layoutMapsCanvasToContent() throws {
        // 400×300 blue original with a red 10×10 marker at original (200, 140); crop at (50, 40) puts it at
        // content (150, 100).
        let ctx = Self.makeContext(width: 400, height: 300)
        ctx.setFillColor(ColorValue(hex: "#2050FF")!.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(ColorValue(hex: "#FF0000")!.cgColor)
        ctx.fill(CGRect(x: 200, y: 300 - 140 - 10, width: 10, height: 10)) // y-up context
        let original = try #require(ctx.makeImage())
        let placement = TemplatePlacement(templateID: Self.phone.id, fit: .fill, offset: CGPoint(x: -0.2, y: 0))
        let input = RenderInput(original: original, crop: CGRect(x: 50, y: 40, width: 300, height: 200),
                                style: Self.style(padding: 30), template: Self.phone, placement: placement)
        let scale: CGFloat = 2
        let image = try #require(Renderer.render(input, outputScale: scale))
        let (canvas, device) = Renderer.layout(for: input)
        let layout = try #require(device)
        #expect(image.width == Int((canvas.canvasSize.width * scale).rounded()))
        #expect(image.height == Int((canvas.canvasSize.height * scale).rounded()))
        let toContent = try #require(TemplateGeometry.screenToContentTransform(
            template: Self.phone, placement: placement, contentSize: CGSize(width: 300, height: 200),
            frameScale: layout.frameScale))
        let origin = canvas.imageRect.origin

        func canvasPoint(content p: CGPoint) -> CGPoint {
            let d = p.applying(toContent.inverted())
            return CGPoint(x: (d.x + origin.x) * scale, y: (d.y + origin.y) * scale)
        }
        // Content → canvas: marker center is red, a point left of it is blue.
        let marker = canvasPoint(content: CGPoint(x: 155, y: 105))
        #expect(Self.pixel(image, at: marker).isClose(to: Self.red, tolerance: 8), "marker \(Self.pixel(image, at: marker))")
        let beside = canvasPoint(content: CGPoint(x: 140, y: 105))
        #expect(Self.pixel(image, at: beside).isClose(to: Self.blue, tolerance: 8), "beside \(Self.pixel(image, at: beside))")

        // Canvas → content: the output pixel at the marker maps back into the marker square.
        let px = CGPoint(x: marker.x.rounded(.down) + 0.5, y: marker.y.rounded(.down) + 0.5)
        let back = CGPoint(x: px.x / scale - origin.x, y: px.y / scale - origin.y).applying(toContent)
        #expect(CGRect(x: 150, y: 100, width: 10, height: 10).contains(back), "\(back)")
    }

    /// Task 6: `CanvasMapping(input:viewScale:)` maps original pixels to the editor view through the template
    /// (crop, fill with offset, padding, view scale) and back, matching the rendered canvas.
    @Test func canvasMappingWithTemplateRoundTrips() throws {
        let ctx = Self.makeContext(width: 400, height: 300)
        ctx.setFillColor(ColorValue(hex: "#2050FF")!.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(ColorValue(hex: "#FF0000")!.cgColor)
        ctx.fill(CGRect(x: 200, y: 300 - 140 - 10, width: 10, height: 10)) // original (200, 140), y-up context
        let original = try #require(ctx.makeImage())
        let crop = CGRect(x: 50, y: 40, width: 300, height: 200)
        let placement = TemplatePlacement(templateID: Self.phone.id, fit: .fill, offset: CGPoint(x: -0.2, y: 0))
        let input = RenderInput(original: original, crop: crop, style: Self.style(padding: 30),
                                template: Self.phone, placement: placement)
        let viewScale: CGFloat = 0.75
        let mapping = try #require(CanvasMapping(input: input, viewScale: viewScale))

        // Round trips in both directions.
        for p in [CGPoint(x: 60, y: 50), CGPoint(x: 205, y: 145), CGPoint(x: 340, y: 230)] {
            let back = mapping.toOriginal(mapping.toView(p))
            #expect(abs(back.x - p.x) < 1e-6 && abs(back.y - p.y) < 1e-6, "\(p) → \(back)")
        }
        let v = CGPoint(x: 123.5, y: 321.25)
        let vBack = mapping.toView(mapping.toOriginal(v))
        #expect(abs(vBack.x - v.x) < 1e-6 && abs(vBack.y - v.y) < 1e-6)

        // Uniform scale: 10 original pixels are 10 × scale view points on both axes.
        let a = mapping.toView(CGPoint(x: 200, y: 140)), b = mapping.toView(CGPoint(x: 210, y: 150))
        #expect(abs((b.x - a.x) - 10 * mapping.scale) < 1e-6 && abs((b.y - a.y) - 10 * mapping.scale) < 1e-6)
        let layout = try #require(Renderer.layout(for: input).device)
        let screenHeight = Self.phone.screenBounds.height * layout.frameScale
        // `.fill` keeps the content height (200) across the screen height.
        #expect(abs(mapping.scale - viewScale * screenHeight / 200) < 1e-6)

        // The view point of the marker is red in a render at output scale = view scale; beside it is blue.
        let image = try #require(Renderer.render(input, outputScale: viewScale))
        let marker = mapping.toView(CGPoint(x: 205, y: 145))
        #expect(Self.pixel(image, at: marker).isClose(to: Self.red, tolerance: 8), "marker \(Self.pixel(image, at: marker))")
        let beside = mapping.toView(CGPoint(x: 190, y: 145))
        #expect(Self.pixel(image, at: beside).isClose(to: Self.blue, tolerance: 8), "beside \(Self.pixel(image, at: beside))")

        // Visible part: the fill crop of the content, in original pixels.
        let width = 200 * Self.phone.screenBounds.width / Self.phone.screenBounds.height
        let visible = mapping.visibleRect
        #expect(abs(visible.width - width) < 1e-6 && visible.minY == 40 && visible.height == 200)
        #expect(abs(visible.minX - (50 + (300 - width) / 2 * 0.8)) < 1e-6)

        // Without template: the same as the plain layout mapping.
        let plainInput = RenderInput(original: original, crop: crop, style: Self.style(padding: 30))
        let plain = try #require(CanvasMapping(input: plainInput, viewScale: 0.5))
        let legacy = CanvasMapping(layout: Renderer.layout(for: plainInput).canvas, crop: crop, viewScale: 0.5)
        #expect(plain.toOriginal(v) == legacy.toOriginal(v))
        #expect(plain.visibleRect == crop && plain.scale == 0.5)

        // Not editable: tilt, or a skewed screen quad.
        var tilted = input
        tilted.style.tilt = Tilt(x: 5, y: 0)
        #expect(CanvasMapping(input: tilted, viewScale: 1) == nil)
        var skewed = Self.phone
        skewed.screenQuad[1].x -= 40
        #expect(CanvasMapping(input: RenderInput(original: original, style: Self.style(), template: skewed),
                              viewScale: 1) == nil)
    }

    @Test func artworkCacheIsBoundedAndLRU() throws {
        let cache = ArtworkCache()
        let id = "laptop-silver"
        let small = try #require(cache.image(id: id, scale: 0.5, urlText: nil))
        // Scales rounding to the same 1/1000 share an entry.
        #expect(try #require(cache.image(id: id, scale: 0.5004, urlText: nil)) === small)
        // Above 8 MP (3000×1900 at 1.2 ≈ 8.2 MP) nothing is cached; compose draws the vectors directly.
        #expect(cache.image(id: id, scale: 1.2, urlText: nil) == nil)
        #expect(cache.usage.count == 1)

        let first = try #require(cache.image(id: id, scale: 1.0, urlText: nil)) // ≈ 22.8 MB each
        for s in [0.99, 0.98] { _ = cache.image(id: id, scale: s, urlText: nil) }
        _ = cache.image(id: id, scale: 0.5, urlText: nil) // touch: most recently used
        for s in [0.97, 0.96, 0.95] { _ = cache.image(id: id, scale: s, urlText: nil) }
        #expect(cache.usage.bytes <= ArtworkCache.byteBudget, "\(cache.usage)")
        #expect(try #require(cache.image(id: id, scale: 0.5, urlText: nil)) === small)
        #expect(try #require(cache.image(id: id, scale: 1.0, urlText: nil)) !== first)
    }

    @Test func writesMockupSnapshots() throws {
        let screenshot = Self.sampleScreenshot(width: 1440, height: 900)
        let tall = Self.sampleScreenshot(width: 590, height: 1278)
        let arrow = Annotation(kind: .arrow(start: CGPoint(x: 200, y: 700), end: CGPoint(x: 700, y: 300),
                                            control: nil, head: .filled), strokeWidth: 12)
        var style = Self.style(padding: 80, shadow: 60)
        style.background = GradientPresets.all[0]
        func render(_ name: String, _ image: CGImage, template id: String?, tilt: Tilt = .zero,
                    placement: TemplatePlacement? = nil, annotations: [Annotation] = []) throws {
            var s = style
            s.tilt = tilt
            let template = id.flatMap(TemplateCatalog.builtin(id:))
            let input = RenderInput(original: image, style: s, annotations: annotations, template: template,
                                    placement: placement ?? id.map { TemplatePlacement(templateID: $0) })
            let output = try #require(Renderer.render(input, outputScale: 0.5))
            RenderSnapshot.write(output, name: "mockup-\(name)")
        }
        try render("laptop", screenshot, template: "laptop-silver", annotations: [arrow])
        try render("phone", tall, template: "phone-portrait-dark")
        try render("tablet-landscape", screenshot, template: "tablet-landscape-light",
                   placement: TemplatePlacement(templateID: "tablet-landscape-light", fit: .fit,
                                                fillColor: ColorValue(hex: "#1D1D1F")!))
        try render("browser", screenshot, template: "browser-light",
                   placement: TemplatePlacement(templateID: "browser-light", urlText: "docs.example.com"))
        try render("laptop-tilted", screenshot, template: "laptop-black", tilt: Tilt(x: 15, y: -10),
                   annotations: [arrow])
        try render("plain-tilted", screenshot, template: nil, tilt: Tilt(x: 15, y: -10), annotations: [arrow])
    }

    /// A screenshot-like image: gradient with a white "window" and dark bars.
    private static func sampleScreenshot(width: Int, height: Int) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        let gradient = CGGradient(colorsSpace: srgb,
                                  colors: [ColorValue(hex: "#0A84FF")!.cgColor, ColorValue(hex: "#AF52DE")!.cgColor] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
        let window = CGRect(x: w * 0.1, y: h * 0.12, width: w * 0.8, height: h * 0.7)
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(ColorValue(hex: "#1D1D1F")!.cgColor)
        for i in 0..<5 {
            ctx.fill(CGRect(x: window.minX + w * 0.05, y: window.maxY - h * 0.1 - CGFloat(i) * h * 0.1,
                            width: w * (0.6 - 0.08 * CGFloat(i)), height: h * 0.04))
        }
        return ctx.makeImage()!
    }
}
