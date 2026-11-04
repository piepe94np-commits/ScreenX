import CoreGraphics
import Foundation
import ImageIO

public struct LoadedDocument: Sendable {
    public var model: DocumentModel
    public var original: CGImage
    public var backgroundImage: CGImage?
    public var backgroundData: Data?
    /// `true` when the file was written by a newer app version; it may be viewed but not saved.
    public var isReadOnly: Bool

    public init(model: DocumentModel, original: CGImage, backgroundImage: CGImage?,
                backgroundData: Data?, isReadOnly: Bool) {
        self.model = model
        self.original = original
        self.backgroundImage = backgroundImage
        self.backgroundData = backgroundData
        self.isReadOnly = isReadOnly
    }
}

public enum PackageError: Error, LocalizedError, Equatable {
    case corrupt(String)
    case missingOriginal

    public var errorDescription: String? {
        switch self {
        case .corrupt(let detail):
            String(localized: "Die Datei ist beschädigt: \(detail)")
        case .missingOriginal:
            String(localized: "Das Originalbild fehlt in der Datei.")
        }
    }
}

public enum ScreenXPackage {
    public static let fileExtension = "screenx"
    public static let typeIdentifier = "com.screenx.document"

    static let documentFile = "document.json"
    static let previewFile = "preview.png"
    static let previewMaxEdge: CGFloat = 1024

    /// Builds the package. If `backgroundData` is given it is stored under the name referenced by
    /// `model.style.background` (`.image(file:)`), else as `background.<extension>`.
    public static func fileWrapper(
        model: DocumentModel,
        original: CGImage,
        backgroundData: Data?,
        backgroundExtension: String?
    ) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(model)
        let originalPNG = try ImageExporter.data(
            for: original, scale: CGFloat(model.original.scale), format: .png, jpegQuality: 1)

        var files: [String: FileWrapper] = [
            documentFile: FileWrapper(regularFileWithContents: json),
            model.original.file: FileWrapper(regularFileWithContents: originalPNG),
        ]

        var backgroundImage: CGImage?
        if let backgroundData {
            let name: String
            if case .image(let file) = model.style.background {
                name = file
            } else {
                name = "background.\(backgroundExtension ?? "png")"
            }
            files[name] = FileWrapper(regularFileWithContents: backgroundData)
            backgroundImage = decode(backgroundData)
        }

        if let preview = renderPreview(model: model, original: original, backgroundImage: backgroundImage),
           let data = try? ImageExporter.data(for: preview, scale: 1, format: .png, jpegQuality: 1) {
            files[previewFile] = FileWrapper(regularFileWithContents: data)
        }

        return FileWrapper(directoryWithFileWrappers: files)
    }

    public static func read(_ wrapper: FileWrapper) throws -> LoadedDocument {
        guard wrapper.isDirectory, let files = wrapper.fileWrappers else {
            throw PackageError.corrupt(String(localized: "Kein Paket"))
        }
        guard let jsonData = files[documentFile]?.regularFileContents else {
            throw PackageError.corrupt(String(localized: "document.json fehlt"))
        }
        let model: DocumentModel
        do {
            model = try JSONDecoder().decode(DocumentModel.self, from: jsonData)
        } catch {
            throw PackageError.corrupt(String(describing: error))
        }
        guard let originalData = files[model.original.file]?.regularFileContents else {
            throw PackageError.missingOriginal
        }
        guard let original = decode(originalData) else {
            throw PackageError.corrupt(String(localized: "Das Originalbild ist nicht lesbar"))
        }

        var backgroundData: Data?
        var backgroundImage: CGImage?
        if case .image(let file) = model.style.background,
           let data = files[file]?.regularFileContents {
            backgroundData = data
            backgroundImage = decode(data)
        }

        return LoadedDocument(
            model: model, original: original, backgroundImage: backgroundImage,
            backgroundData: backgroundData, isReadOnly: model.version > DocumentModel.currentVersion)
    }

    public static func read(from url: URL) throws -> LoadedDocument {
        let wrapper: FileWrapper
        do {
            wrapper = try FileWrapper(url: url, options: .immediate)
        } catch {
            throw PackageError.corrupt(error.localizedDescription)
        }
        return try read(wrapper)
    }

    /// Writes atomically: builds a temporary package next to `url`, then swaps it in.
    public static func write(
        model: DocumentModel,
        original: CGImage,
        backgroundData: Data?,
        backgroundExtension: String?,
        to url: URL
    ) throws {
        let wrapper = try fileWrapper(
            model: model, original: original,
            backgroundData: backgroundData, backgroundExtension: backgroundExtension)
        let fileManager = FileManager.default
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: true)
        do {
            try wrapper.write(to: temp, options: [], originalContentsURL: nil)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func renderPreview(model: DocumentModel, original: CGImage, backgroundImage: CGImage?) -> CGImage? {
        let input = RenderInput(original: original, crop: model.crop, style: model.style,
                                backgroundImage: backgroundImage)
        guard let full = Renderer.render(input, outputScale: 1) else { return nil }
        let longest = CGFloat(max(full.width, full.height))
        guard longest > previewMaxEdge else { return full }
        return Renderer.render(input, outputScale: previewMaxEdge / longest)
    }
}
