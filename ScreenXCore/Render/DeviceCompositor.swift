import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Size of the image the renderer places on the canvas when a device template and/or tilt is used,
/// in canvas units (original pixels).
public struct DeviceLayout: Equatable, Sendable {
    /// Frame units → canvas units (`TemplateGeometry.frameScale`); 1 without template.
    public let frameScale: CGFloat
    /// The composed device image (frame size × `frameScale`), or the content size without template.
    public let deviceSize: CGSize
    /// `deviceSize` after the tilt (bounding box of `TemplateGeometry.tiltCorners`); this is the
    /// `contentSize` the renderer passes to `CanvasLayout.compute`.
    public let imageSize: CGSize

    public init(frameScale: CGFloat, deviceSize: CGSize, imageSize: CGSize) {
        self.frameScale = frameScale
        self.deviceSize = deviceSize
        self.imageSize = imageSize
    }
}

/// Places screen content into a device frame and applies the 3D tilt.
public enum DeviceCompositor {
    /// Largest composed device image per side, in pixels.
    public static let maxOutputSide = 16384
    /// Largest composed device image in total (about 200 MP, 800 MB at 4 bytes per pixel).
    public static let maxOutputPixels = 200_000_000

    /// The layout `Renderer` uses for `contentSize` (the crop size).
    ///
    /// On the canvas, the device image lies at `CanvasLayout.compute(contentSize: imageSize, style:)
    /// .imageRect`. Without tilt, a canvas point minus that rect's origin is a device-image point as
    /// expected by `TemplateGeometry.screenToContentTransform(…, frameScale: frameScale)`.
    public static func layout(template: DeviceTemplate?, contentSize: CGSize, tilt: Tilt) -> DeviceLayout {
        var frameScale: CGFloat = 1
        var deviceSize = contentSize
        if let template {
            frameScale = TemplateGeometry.frameScale(template: template, contentSize: contentSize)
            deviceSize = CGSize(width: template.frameSize.width * frameScale,
                                height: template.frameSize.height * frameScale)
        }
        var imageSize = deviceSize
        if TemplateGeometry.clamped(tilt) != .zero, deviceSize.width > 0, deviceSize.height > 0 {
            let corners = TemplateGeometry.tiltCorners(size: deviceSize, tilt: tilt)
            imageSize = CGSize(width: corners.map(\.x).max() ?? 0, height: corners.map(\.y).max() ?? 0)
        }
        return DeviceLayout(frameScale: frameScale, deviceSize: deviceSize, imageSize: imageSize)
    }

    /// Draws `content` into the screen of `template` and the frame above it.
    ///
    /// - `scale`: output pixels per frame unit (`frameScale × outputScale`); the result has
    ///   `frameSize × scale` pixels (rounded).
    /// - The content is placed with `TemplateGeometry.sourceRect` (fill/fit, offset, fill color), the
    ///   screen corners are rounded with `screenCornerRadius × scale`. A non-rectangular quad gets the
    ///   screen through a perspective transform.
    /// - Frame: built-in vector artwork, or `customFrame` (scaled to the frame) for `.file` frames;
    ///   without `customFrame` only the screen is drawn.
    /// Returns `nil` for an invalid scale or frame size, for an output larger than `maxOutputSide` per side
    /// or `maxOutputPixels` in total, or if no context can be created.
    public static func compose(content: CGImage, template: DeviceTemplate, placement: TemplatePlacement,
                               customFrame: CGImage?, scale: CGFloat) -> CGImage? {
        let frame = template.frameSize
        guard scale.isFinite, scale > 0, frame.width > 0, frame.height > 0 else { return nil }
        // Checked in floating point first: a huge product must not reach `Int(_:)`.
        let w = max(1, (frame.width * scale).rounded()), h = max(1, (frame.height * scale).rounded())
        guard w.isFinite, h.isFinite, w <= CGFloat(maxOutputSide), h <= CGFloat(maxOutputSide),
              w * h <= CGFloat(maxOutputPixels)
        else { return nil }
        let width = Int(w), height = Int(h)
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        // Exact pixels per frame unit on each axis (after rounding the output size).
        let sx = CGFloat(width) / frame.width, sy = CGFloat(height) / frame.height
        let map = CGAffineTransform(scaleX: sx, y: sy)

        // Screen
        let quad = template.screenQuad
        let layerSize: CGSize
        if template.isRectangular {
            layerSize = template.screenBounds.size
        } else {
            func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
            layerSize = CGSize(width: (length(quad[0], quad[1]) + length(quad[3], quad[2])) / 2,
                               height: (length(quad[0], quad[3]) + length(quad[1], quad[2])) / 2)
        }
        if let layer = screenLayer(content: content, placement: placement,
                                   size: CGSize(width: layerSize.width * sx, height: layerSize.height * sy),
                                   cornerRadius: CGFloat(template.screenCornerRadius) * scale) {
            if template.isRectangular {
                ctx.drawUpright(layer, in: template.screenBounds.applying(map))
            } else if let warped = warp(layer, to: quad.map { $0.applying(map) }) {
                ctx.drawUpright(warped.image, in: warped.rect)
            }
        }

        // Frame above the screen
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        switch template.frame {
        case .builtin(let id):
            if let artwork = artworkCache.image(id: id, scale: scale, urlText: placement.urlText) {
                ctx.drawUpright(artwork, in: full)
            } else {
                // Not cached (too large for the cache or for an image): draw the vectors directly.
                DeviceArtwork.draw(builtin: id, in: ctx, size: full.size, urlText: placement.urlText)
            }
        case .file:
            if let customFrame { ctx.drawUpright(customFrame, in: full) }
        }
        return ctx.makeImage()
    }

    /// `image` after the 3D tilt (`TemplateGeometry.tiltCorners`), sized to the tilted bounding box.
    /// Returns `image` unchanged for a (clamped) tilt of zero.
    public static func tilted(_ image: CGImage, tilt: Tilt) -> CGImage? {
        guard TemplateGeometry.clamped(tilt) != .zero else { return image }
        let corners = TemplateGeometry.tiltCorners(size: CGSize(width: image.width, height: image.height),
                                                   tilt: tilt)
        return warp(image, to: corners)?.image
    }

    // MARK: - Helpers

    /// The screen content: fill color (fit), content placed per `placement`, rounded corners.
    private static func screenLayer(content: CGImage, placement: TemplatePlacement, size: CGSize,
                                    cornerRadius: CGFloat) -> CGImage? {
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = max(0, min(cornerRadius, min(bounds.width, bounds.height) / 2))
        ctx.interpolationQuality = .high
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        if placement.fit == .fit {
            ctx.setFillColor(placement.fillColor.cgColor)
            ctx.fill(bounds)
        }
        let contentSize = CGSize(width: content.width, height: content.height)
        let (source, dest) = TemplateGeometry.sourceRect(contentSize: contentSize, screenSize: bounds.size,
                                                        fit: placement.fit, offset: placement.offset)
        guard source.width > 0, source.height > 0 else { return ctx.makeImage() }
        let kx = dest.width / source.width, ky = dest.height / source.height
        ctx.clip(to: dest)
        ctx.drawUpright(content, in: CGRect(x: dest.minX - source.minX * kx, y: dest.minY - source.minY * ky,
                                            width: contentSize.width * kx, height: contentSize.height * ky))
        return ctx.makeImage()
    }

    /// Maps the whole of `image` onto `corners` (top-left, top-right, bottom-right, bottom-left; origin
    /// top-left, y down) with `CIPerspectiveTransform`. `rect` is the integral bounding box of the corners
    /// in the same coordinates; the returned image covers exactly that rect.
    static func warp(_ image: CGImage, to corners: [CGPoint]) -> (image: CGImage, rect: CGRect)? {
        guard corners.count == 4, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        // A small tolerance, so float noise (e.g. -1e-12 for a corner at 0) does not add a pixel.
        let eps: CGFloat = 1e-6
        let minX = ((corners.map(\.x).min() ?? 0) + eps).rounded(.down)
        let maxX = ((corners.map(\.x).max() ?? 0) - eps).rounded(.up)
        let minY = ((corners.map(\.y).min() ?? 0) + eps).rounded(.down)
        let maxY = ((corners.map(\.y).max() ?? 0) - eps).rounded(.up)
        guard maxX > minX, maxY > minY else { return nil }
        // Core Image has its origin at the bottom-left: flip y against the bottom of the bounding box.
        func ci(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: maxY - p.y) }
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = CIImage(cgImage: image)
        filter.topLeft = ci(corners[0])
        filter.topRight = ci(corners[1])
        filter.bottomRight = ci(corners[2])
        filter.bottomLeft = ci(corners[3])
        guard let output = filter.outputImage else { return nil }
        let extent = CGRect(x: minX, y: 0, width: maxX - minX, height: maxY - minY)
        guard let result = BackgroundPainter.sharedCIContext.context.createCGImage(
            output, from: extent, format: .RGBA8, colorSpace: DeviceArtwork.sRGB) else { return nil }
        return (result, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    /// sRGB, premultiplied alpha, flipped to a top-left origin.
    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: DeviceArtwork.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    static let artworkCache = ArtworkCache()
}

/// Built-in frame images by (id, pixel scale rounded to 1/1000, URL text), since previews render the same
/// frame repeatedly. Bounded by a byte budget with least-recently-used eviction; images above
/// `maxCachedPixels` are not cached (the caller draws the vectors directly).
final class ArtworkCache: @unchecked Sendable {
    // @unchecked: `images`, `order` and `bytes` are only accessed while holding `lock`; CGImage is immutable.
    private struct Key: Hashable {
        let id: String
        let scale: Int
        let urlText: String?
    }

    static let byteBudget = 96 * 1024 * 1024
    static let maxCachedPixels = 8_000_000

    private let lock = NSLock()
    private var images: [Key: CGImage] = [:]
    /// Keys from least to most recently used.
    private var order: [Key] = []
    private var bytes = 0

    /// Number of cached images and their total size in bytes (for tests).
    var usage: (count: Int, bytes: Int) { lock.withLock { (images.count, bytes) } }

    /// The cached or newly drawn frame image; `nil` when it would exceed `maxCachedPixels` or cannot be drawn.
    func image(id: String, scale: CGFloat, urlText: String?) -> CGImage? {
        guard scale.isFinite, scale > 0, let template = TemplateCatalog.builtin(id: id) else { return nil }
        let rounded = (Double(scale) * 1000).rounded()
        guard rounded >= 1, rounded < Double(Int.max) else { return nil }
        let pixels = Double(template.frameSize.width * scale) * Double(template.frameSize.height * scale)
        guard pixels <= Double(Self.maxCachedPixels) else { return nil }
        let key = Key(id: id, scale: Int(rounded), urlText: urlText)
        let cached: CGImage? = lock.withLock {
            guard let image = images[key] else { return nil }
            touch(key)
            return image
        }
        if let cached { return cached }
        guard let image = DeviceArtwork.image(builtin: id, scale: CGFloat(rounded / 1000), urlText: urlText)
        else { return nil }
        let size = image.bytesPerRow * image.height
        lock.withLock {
            if let old = images.updateValue(image, forKey: key) {
                bytes -= old.bytesPerRow * old.height
            }
            bytes += size
            touch(key)
            while bytes > Self.byteBudget, order.count > 1, let oldest = order.first {
                order.removeFirst()
                if let removed = images.removeValue(forKey: oldest) { bytes -= removed.bytesPerRow * removed.height }
            }
        }
        return image
    }

    /// Marks `key` as most recently used. Call with `lock` held.
    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
