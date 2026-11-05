import CoreGraphics
import Foundation
import ImageIO
import os

/// Errors when creating a custom template from user input.
public enum TemplateError: Error, Equatable, Sendable {
    /// The screen needs exactly 4 finite corners inside the image, spanning a non-empty area.
    case invalidQuad
    /// Only png, jpg, jpeg, heic and tiff are accepted.
    case unsupportedImageType(String)
    case unreadableImage
}

extension TemplateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidQuad:
            String(localized: "Für den Bildschirm werden genau vier Eckpunkte innerhalb des Bildes benötigt.")
        case .unsupportedImageType(let ext):
            String(localized: "Das Bildformat „\(ext)“ wird für Vorlagen nicht unterstützt.")
        case .unreadableImage:
            String(localized: "Das Bild der Vorlage konnte nicht gelesen werden.")
        }
    }
}

/// Custom device templates on disk: `<id>.json` plus the frame image `<id>.<ext>` in one folder
/// (standard `~/Library/Application Support/ScreenX/Templates`).
public final class CustomTemplateStore: @unchecked Sendable {
    /// Image types a custom frame may have.
    public static let allowedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
    static let idPrefix = "custom-"

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenX", isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true)
    }

    /// Store in `defaultDirectory`, shared by the app.
    public static let shared = CustomTemplateStore()

    private static let logger = Logger(subsystem: "com.screenx.app", category: "templates")

    public let directory: URL
    /// Serializes file access; `@unchecked Sendable` is sound because all mutable state is on disk behind it.
    private let lock = NSLock()

    public init(directory: URL = CustomTemplateStore.defaultDirectory) {
        self.directory = directory
    }

    /// All readable templates, sorted by name. Corrupt or foreign JSON files are skipped.
    public func all() -> [DeviceTemplate] {
        lock.lock()
        defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { loadTemplate(stem: String($0.dropLast(5))) }
            .sorted { a, b in
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
    }

    /// The stored template with `id`, if it exists and is readable.
    public func template(id: String) -> DeviceTemplate? {
        guard Self.isValidID(id) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return loadTemplate(stem: id)
    }

    /// Stores a new template. `quad` is in image pixels (top-left, top-right, bottom-right, bottom-left).
    @discardableResult
    public func add(name: String, imageData: Data, imageExtension: String, quad: [CGPoint]) throws -> DeviceTemplate {
        let ext = imageExtension.lowercased()
        guard Self.allowedImageExtensions.contains(ext) else { throw TemplateError.unsupportedImageType(imageExtension) }
        guard let image = Self.decode(imageData) else { throw TemplateError.unreadableImage }
        let size = CGSize(width: image.width, height: image.height)
        guard quad.count == 4,
              quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...size.width).contains($0.x)
                                && (0...size.height).contains($0.y) }) else { throw TemplateError.invalidQuad }
        let xs = quad.map(\.x), ys = quad.map(\.y)
        let boundsW = Int(((xs.max() ?? 0) - (xs.min() ?? 0)).rounded())
        let boundsH = Int(((ys.max() ?? 0) - (ys.min() ?? 0)).rounded())
        guard boundsW > 0, boundsH > 0 else { throw TemplateError.invalidQuad }
        let divisor = Self.gcd(boundsW, boundsH)

        let id = Self.idPrefix + UUID().uuidString
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = DeviceTemplate(
            id: id, name: trimmed.isEmpty ? String(localized: "Eigene Vorlage") : trimmed,
            frame: .file("\(id).\(ext)"), frameSize: size, screenQuad: quad,
            screenCornerRadius: 0, preferredAspect: [boundsW / divisor, boundsH / divisor])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(template)

        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("\(id).\(ext)")
        try imageData.write(to: imageURL, options: .atomic)
        do {
            try json.write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }
        return template
    }

    /// Removes the template's JSON and image. Unknown ids are ignored.
    public func delete(id: String) throws {
        guard Self.isValidID(id) else { return }
        lock.lock()
        defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where (name as NSString).deletingPathExtension == id {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Raw bytes of the template's frame image, as stored.
    public func imageData(for template: DeviceTemplate) -> Data? {
        guard case .file(let file) = template.frame, Self.isSafeFileName(file) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: directory.appendingPathComponent(file))
    }

    public func image(for template: DeviceTemplate) -> CGImage? {
        imageData(for: template).flatMap(Self.decode)
    }

    // MARK: - Helpers

    /// `custom-<UUID>`; nothing else can name a file in the store.
    static func isValidID(_ id: String) -> Bool {
        id.hasPrefix(idPrefix) && UUID(uuidString: String(id.dropFirst(idPrefix.count))) != nil
    }

    /// A plain file name: no path components, not hidden, with an allowed image extension.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".")
            && allowedImageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Caller holds `lock`.
    private func loadTemplate(stem: String) -> DeviceTemplate? {
        guard Self.isValidID(stem) else { return nil }
        let url = directory.appendingPathComponent("\(stem).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let template = try JSONDecoder().decode(DeviceTemplate.self, from: data)
            return template.id == stem ? template : nil
        } catch {
            Self.logger.error("Skipping unreadable template \(stem, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }
}
