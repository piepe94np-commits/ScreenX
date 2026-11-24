import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenXCore

struct ImageExporterTests {
    private let date: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 22, minute: 15, second: 30))!
    }()

    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    @Test func fileNameFormat() {
        #expect(ImageExporter.fileName(date: date, format: .png, timeZone: .gmt) == "ScreenX 2026-11-03 um 22.15.30.png")
        #expect(ImageExporter.fileName(date: date, format: .jpeg, timeZone: .gmt).hasSuffix(".jpg"))
    }

    @Test func pngRoundTrip() throws {
        let image = TestImages.solid(width: 40, height: 20, color: red)
        let data = try ImageExporter.data(for: image, scale: 1, format: .png, jpegQuality: 1)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 40)
        #expect(decoded.height == 20)
    }

    @Test(arguments: [(1.0, 72.0), (2.0, 144.0)])
    func retinaDPI(scale: Double, expected: Double) throws {
        let image = TestImages.solid(width: 10, height: 10, color: red)
        let data = try ImageExporter.data(for: image, scale: scale, format: .png, jpegQuality: 1)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let dpi = try #require(properties[kCGImagePropertyDPIWidth] as? Double)
        // PNG stores pixels per meter, so the value is rounded slightly.
        #expect(abs(dpi - expected) < 0.5)
    }

    @Test func jpegQualityAffectsSize() throws {
        let image = TestImages.gradient(width: 200, height: 200)
        let low = try ImageExporter.data(for: image, scale: 1, format: .jpeg, jpegQuality: 0.2)
        let high = try ImageExporter.data(for: image, scale: 1, format: .jpeg, jpegQuality: 1.0)
        #expect(low.count < high.count)
    }

    @Test func createsMissingDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("a/b")
        let image = TestImages.solid(width: 10, height: 10, color: red)
        let url = try ImageExporter.write(image, scale: 1, to: directory, date: date, format: .png, jpegQuality: 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().path == directory.path)
    }

    @Test func doesNotOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = TestImages.solid(width: 10, height: 10, color: red)
        let first = try ImageExporter.write(image, scale: 1, to: directory, date: date, format: .png, jpegQuality: 1)
        let second = try ImageExporter.write(image, scale: 1, to: directory, date: date, format: .png, jpegQuality: 1)
        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(second.lastPathComponent.hasSuffix(" (2).png"))
    }
}
