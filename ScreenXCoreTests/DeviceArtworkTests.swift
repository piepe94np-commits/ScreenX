import CoreGraphics
import Foundation
import Testing
@testable import ScreenXCore

struct DeviceArtworkTests {
    /// Alpha values of an image, read back through a premultiplied RGBA context (row 0 = top).
    private struct Alpha {
        let width: Int, height: Int
        private let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytes = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self),
                                              count: width * height * 4))
        }

        /// Alpha of the pixel containing the frame point `p` (frame units × `scale`).
        func at(_ p: CGPoint, scale: CGFloat) -> Int {
            let x = min(max(Int(p.x * scale), 0), width - 1), y = min(max(Int(p.y * scale), 0), height - 1)
            return Int(bytes[(y * width + x) * 4 + 3])
        }
    }

    private static let scale: CGFloat = 0.5

    @Test func screenAreaTransparent() throws {
        for template in TemplateCatalog.builtins {
            let image = try #require(DeviceArtwork.image(builtin: template.id, scale: Self.scale, urlText: nil),
                                     "\(template.id)")
            let screen = template.screenBounds
            #expect(Alpha(image).at(CGPoint(x: screen.midX, y: screen.midY), scale: Self.scale) == 0,
                    "\(template.id)")
        }
    }

    /// 10 units left of the screen's left edge, at its vertical middle. The browser's screen starts at
    /// x = 0, so there the point is 10 units above the screen's top edge (title bar).
    @Test func bezelOpaque() throws {
        for template in TemplateCatalog.builtins {
            let image = try #require(DeviceArtwork.image(builtin: template.id, scale: Self.scale, urlText: nil),
                                     "\(template.id)")
            let screen = template.screenBounds
            let point = screen.minX >= 10
                ? CGPoint(x: screen.minX - 10, y: screen.midY)
                : CGPoint(x: screen.midX, y: screen.minY - 10)
            #expect(Alpha(image).at(point, scale: Self.scale) == 255, "\(template.id)")
        }
    }

    /// Probes 3 units inside and outside each screen edge midpoint: the cut-out sits exactly at the quad,
    /// also for the rotated landscape variants. Edges on the frame boundary (browser) have no outside.
    /// With rounded screen corners, a point just inside the bounding-box corner is opaque.
    @Test func screenCutOutMatchesQuad() throws {
        for template in TemplateCatalog.builtins {
            let image = try #require(DeviceArtwork.image(builtin: template.id, scale: Self.scale, urlText: nil),
                                     "\(template.id)")
            let alpha = Alpha(image)
            let s = template.screenBounds, f = template.frameSize
            // (midpoint, outward direction, edge touches the frame boundary)
            let edges: [(CGPoint, CGVector, Bool)] = [
                (CGPoint(x: s.midX, y: s.minY), CGVector(dx: 0, dy: -1), s.minY <= 0),
                (CGPoint(x: s.maxX, y: s.midY), CGVector(dx: 1, dy: 0), s.maxX >= f.width),
                (CGPoint(x: s.midX, y: s.maxY), CGVector(dx: 0, dy: 1), s.maxY >= f.height),
                (CGPoint(x: s.minX, y: s.midY), CGVector(dx: -1, dy: 0), s.minX <= 0),
            ]
            for (mid, out, onBoundary) in edges {
                let inside = CGPoint(x: mid.x - 3 * out.dx, y: mid.y - 3 * out.dy)
                #expect(alpha.at(inside, scale: Self.scale) == 0, "\(template.id) inside \(mid)")
                if !onBoundary {
                    let outside = CGPoint(x: mid.x + 3 * out.dx, y: mid.y + 3 * out.dy)
                    #expect(alpha.at(outside, scale: Self.scale) == 255, "\(template.id) outside \(mid)")
                }
            }
            if template.screenCornerRadius > 0 {
                for corner in [CGPoint(x: s.minX + 2, y: s.minY + 2), CGPoint(x: s.maxX - 3, y: s.minY + 2),
                               CGPoint(x: s.maxX - 3, y: s.maxY - 3), CGPoint(x: s.minX + 2, y: s.maxY - 3)] {
                    #expect(alpha.at(corner, scale: Self.scale) == 255, "\(template.id) corner \(corner)")
                }
            }
        }
    }

    /// The camera island sits over the top center of the screen and stays opaque, also when rotated.
    @Test func phoneCameraIslandOpaque() throws {
        let portrait = try #require(TemplateCatalog.builtin(id: "phone-portrait-dark"))
        let image = try #require(DeviceArtwork.image(builtin: portrait.id, scale: Self.scale, urlText: nil))
        let s = portrait.screenBounds
        #expect(Alpha(image).at(CGPoint(x: s.midX, y: s.minY + 80), scale: Self.scale) == 255)
        // Landscape: portrait top edge becomes the right edge.
        let landscape = try #require(TemplateCatalog.builtin(id: "phone-landscape-dark"))
        let rotated = try #require(DeviceArtwork.image(builtin: landscape.id, scale: Self.scale, urlText: nil))
        let l = landscape.screenBounds
        #expect(Alpha(rotated).at(CGPoint(x: l.maxX - 80, y: l.midY), scale: Self.scale) == 255)
        #expect(Alpha(rotated).at(CGPoint(x: l.minX + 80, y: l.midY), scale: Self.scale) == 0)
    }

    @Test func imageSizeFormatAndUnknownID() throws {
        for template in TemplateCatalog.builtins {
            let image = try #require(DeviceArtwork.image(builtin: template.id, scale: 0.25, urlText: "a.b"))
            #expect(image.width == Int((template.frameSize.width * 0.25).rounded()), "\(template.id)")
            #expect(image.height == Int((template.frameSize.height * 0.25).rounded()), "\(template.id)")
            #expect(image.alphaInfo == .premultipliedLast, "\(template.id)")
            #expect((image.colorSpace?.name as String?) == (CGColorSpace.sRGB as String), "\(template.id)")
        }
        #expect(DeviceArtwork.image(builtin: "nope", scale: 1, urlText: nil) == nil)
        #expect(DeviceArtwork.image(builtin: "laptop-silver", scale: 0, urlText: nil) == nil)
        #expect(DeviceArtwork.image(builtin: "laptop-silver", scale: .nan, urlText: nil) == nil)
        // 3000 × 6 = 18000 px > 16384.
        #expect(DeviceArtwork.image(builtin: "laptop-silver", scale: 6, urlText: nil) == nil)
    }

    @Test func writesDeviceSnapshots() throws {
        for template in TemplateCatalog.builtins {
            let image = try #require(DeviceArtwork.image(builtin: template.id, scale: 0.25, urlText: nil),
                                     "\(template.id)")
            let name = "device-\(template.id)"
            RenderSnapshot.write(image, name: name)
            let url = RenderSnapshot.directory.appendingPathComponent("\(name).png")
            #expect(FileManager.default.fileExists(atPath: url.path), "\(name)")
        }
    }
}
