import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: Error, LocalizedError {
    case encodingFailed
    case directoryNotWritable(URL)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            String(localized: "Das Bild konnte nicht kodiert werden.")
        case .directoryNotWritable(let url):
            String(localized: "In den Ordner „\(url.path)“ kann nicht geschrieben werden.")
        }
    }
}

public enum ImageExporter {
    public static func fileName(date: Date, format: ExportFormat, timeZone: TimeZone = .current) -> String {
        "ScreenX \(timestamp(date: date, timeZone: timeZone)).\(format.fileExtension)"
    }

    public static func data(for image: CGImage, scale: CGFloat, format: ExportFormat, jpegQuality: Double) throws -> Data {
        let type: UTType = format == .png ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed
        }
        let dpi = 72 * Double(scale)
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        let encoded = format == .jpeg && hasAlpha(image) ? try flattenedOnWhite(image) : image
        CGImageDestinationAddImage(destination, encoded, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodingFailed
        }
        return output as Data
    }

    public static func write(
        _ image: CGImage,
        scale: CGFloat,
        to directory: URL,
        date: Date,
        format: ExportFormat,
        jpegQuality: Double
    ) throws -> URL {
        let encoded = try data(for: image, scale: scale, format: format, jpegQuality: jpegQuality)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = timestamp(date: date, timeZone: .current)
            var counter = 1
            while true {
                let suffix = counter == 1 ? "" : " (\(counter))"
                let url = directory.appendingPathComponent("ScreenX \(stamp)\(suffix).\(format.fileExtension)")
                do {
                    // .withoutOverwriting fails atomically if the file exists, avoiding races.
                    try encoded.write(to: url, options: .withoutOverwriting)
                    return url
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    counter += 1
                }
            }
        } catch {
            throw ExportError.directoryNotWritable(directory)
        }
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// JPEG has no alpha: composite onto opaque white so transparent areas don't turn black.
    /// Keeps the image's color space when it is RGB, otherwise uses sRGB.
    private static func flattenedOnWhite(_ image: CGImage) throws -> CGImage {
        let rgbSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let space = rgbSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExportError.encodingFailed }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let flattened = ctx.makeImage() else { throw ExportError.encodingFailed }
        return flattened
    }

    private static func timestamp(date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return formatter.string(from: date)
    }
}
