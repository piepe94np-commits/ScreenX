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
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
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

    private static func timestamp(date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return formatter.string(from: date)
    }
}
