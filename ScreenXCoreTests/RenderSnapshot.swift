import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes rendered images to `ScreenXCoreTests/__Output__/<name>.png` for visual review
/// (uploaded by CI as an artifact). Never fails a test; returns `nil` if writing fails.
enum RenderSnapshot {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("__Output__", isDirectory: true)

    @discardableResult
    static func write(_ image: CGImage, name: String) -> URL? {
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}
