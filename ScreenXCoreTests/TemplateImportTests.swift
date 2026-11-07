import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenXCore

struct TemplateImportTests {
    private static func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9
    }

    @Test func fittedRectAndMappingRoundTrip() {
        let size = CGSize(width: 200, height: 100)
        let fit = QuadPicking.fittedRect(imageSize: size, in: CGRect(x: 10, y: 20, width: 400, height: 400))
        #expect(fit == CGRect(x: 10, y: 120, width: 400, height: 200))
        // Top-left of the image is the top-left of the fitted rect; y grows downwards in both.
        #expect(QuadPicking.toView(.zero, imageSize: size, fittedRect: fit) == CGPoint(x: 10, y: 120))
        #expect(QuadPicking.toView(CGPoint(x: 200, y: 100), imageSize: size, fittedRect: fit)
                == CGPoint(x: 410, y: 320))
        #expect(QuadPicking.toImage(CGPoint(x: 110, y: 170), imageSize: size, fittedRect: fit)
                == CGPoint(x: 50, y: 25))
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 37.5, y: 81.25), CGPoint(x: 200, y: 100)] {
            let view = QuadPicking.toView(p, imageSize: size, fittedRect: fit)
            #expect(Self.close(QuadPicking.toImage(view, imageSize: size, fittedRect: fit), p))
        }
        // Tall image in a wide view: centered horizontally.
        let tall = QuadPicking.fittedRect(imageSize: CGSize(width: 100, height: 400),
                                          in: CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(tall == CGRect(x: 125, y: 0, width: 50, height: 200))
        #expect(QuadPicking.fittedRect(imageSize: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }

    @Test func clampingAndHitTesting() {
        let size = CGSize(width: 200, height: 100)
        #expect(QuadPicking.clamped(CGPoint(x: -5, y: 50), to: size) == CGPoint(x: 0, y: 50))
        #expect(QuadPicking.clamped(CGPoint(x: 250, y: 130), to: size) == CGPoint(x: 200, y: 100))
        #expect(QuadPicking.clamped(CGPoint(x: CGFloat.nan, y: CGFloat.infinity), to: size) == .zero)
        #expect(QuadPicking.clamped(CGPoint(x: 12, y: 34), to: size) == CGPoint(x: 12, y: 34))

        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10), CGPoint(x: 18, y: 10)]
        #expect(QuadPicking.hitIndex(at: CGPoint(x: 20, y: 12), in: points, tolerance: 12) == 2)
        #expect(QuadPicking.hitIndex(at: CGPoint(x: 9, y: 9), in: points, tolerance: 12) == 0)
        #expect(QuadPicking.hitIndex(at: CGPoint(x: 100, y: 100), in: points, tolerance: 12) == nil)
        #expect(QuadPicking.hitIndex(at: .zero, in: [], tolerance: 12) == nil)
    }

    @Test func cornersAreOrderedClockwiseFromTopLeft() {
        let tl = CGPoint(x: 10, y: 12), tr = CGPoint(x: 190, y: 8)
        let br = CGPoint(x: 185, y: 95), bl = CGPoint(x: 14, y: 90)
        let expected = [tl, tr, br, bl]
        for clicked in [[tl, tr, br, bl], [br, bl, tl, tr], [tl, bl, br, tr], [tr, tl, bl, br]] {
            #expect(QuadPicking.orderedClockwise(clicked) == expected, "\(clicked)")
        }
        // A strongly skewed (perspective) screen keeps its corners.
        let skewed = [CGPoint(x: 40, y: 0), CGPoint(x: 160, y: 20), CGPoint(x: 200, y: 100), CGPoint(x: 0, y: 80)]
        #expect(QuadPicking.orderedClockwise([skewed[2], skewed[0], skewed[3], skewed[1]]) == skewed)
        // Not four points: unchanged.
        #expect(QuadPicking.orderedClockwise([tr, tl]) == [tr, tl])
    }

    /// A one-page PDF (`size` points) with a red square of 10 pt in its top-left corner, and a second page.
    private static func makePDF(size: CGSize) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: size.height - 10, width: 10, height: 10)) // PDF space is y-up
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        ctx.fill(box)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Pixel at (x, y), origin top-left: (r, g, b, a) premultiplied bytes.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                         bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        let i = y * ctx.bytesPerRow + x * 4
        return [bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]]
    }

    @Test func pdfFirstPageIsRasterizedAtTwiceTheSize() throws {
        let png = try TemplateImageImport.rasterizeFirstPage(pdfData: try Self.makePDF(size: CGSize(width: 100, height: 50)))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 200 && image.height == 100)
        // The red square lands top-left (20 × 20 px); the rest of the first page is transparent.
        let red = try Self.pixel(image, 5, 5)
        #expect(red[0] > 240 && red[1] < 15 && red[2] < 15 && red[3] > 240, "\(red)")
        #expect(try Self.pixel(image, 150, 70)[3] == 0)
        #expect(try Self.pixel(image, 5, 90)[3] == 0)

        // The PNG is accepted by the store as a frame image.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let template = try CustomTemplateStore(directory: dir).add(
            name: "PDF", imageData: png, imageExtension: "png",
            quad: [CGPoint(x: 20, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 100), CGPoint(x: 20, y: 100)])
        #expect(template.frameSize == CGSize(width: 200, height: 100))
    }

    @Test func pdfErrors() throws {
        #expect(throws: TemplateError.unreadableImage) {
            try TemplateImageImport.rasterizeFirstPage(pdfData: Data("no pdf".utf8))
        }
        let wide = try Self.makePDF(size: CGSize(width: 9000, height: 10))
        #expect(throws: TemplateError.imageTooLarge) {
            try TemplateImageImport.rasterizeFirstPage(pdfData: wide)
        }
        // At scale 1 the same page fits.
        let png = try TemplateImageImport.rasterizeFirstPage(pdfData: wide, scale: 1)
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 9000 && image.height == 10)
    }
}
