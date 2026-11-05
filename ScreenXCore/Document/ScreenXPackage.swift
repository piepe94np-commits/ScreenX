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
    /// The custom template `model.template` names, from `assets/` or else the store; `nil` for builtins
    /// and when it is found in neither (the placement in `model` is kept).
    public var customTemplate: DeviceTemplate?
    /// Bytes of the custom template's frame image (kept so the package can be saved again).
    public var customFrameData: Data?
    public var customFrameImage: CGImage?

    public init(model: DocumentModel, original: CGImage, backgroundImage: CGImage?,
                backgroundData: Data?, isReadOnly: Bool, customTemplate: DeviceTemplate? = nil,
                customFrameData: Data? = nil, customFrameImage: CGImage? = nil) {
        self.model = model
        self.original = original
        self.backgroundImage = backgroundImage
        self.backgroundData = backgroundData
        self.isReadOnly = isReadOnly
        self.customTemplate = customTemplate
        self.customFrameData = customFrameData
        self.customFrameImage = customFrameImage
    }
}

public enum PackageError: Error, LocalizedError, Equatable {
    case corrupt(String)
    case missingOriginal
    case newerVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let detail):
            String(localized: "Die Datei ist beschädigt: \(detail)")
        case .missingOriginal:
            String(localized: "Das Originalbild fehlt in der Datei.")
        case .newerVersion:
            String(localized: "Diese Datei wurde mit einer neueren ScreenX-Version erstellt und kann nicht geöffnet werden.")
        }
    }
}

public enum ScreenXPackage {
    public static let fileExtension = "screenx"
    public static let typeIdentifier = "com.screenx.document"

    static let documentFile = "document.json"
    static let previewFile = "preview.png"
    static let previewMaxEdge: CGFloat = 1024
    static let assetsFolder = "assets"

    /// Builds the package. If `backgroundData` is given it is stored under the name referenced by
    /// `model.style.background` (`.image(file:)`), else as `background.<extension>`.
    ///
    /// If `model.template` names a custom template and `customTemplate` is that template, its JSON is
    /// stored as `assets/<id>.json` and `customFrameData` as `assets/<frame file>`. Builtin templates are
    /// never embedded. The preview is rendered with the template.
    public static func fileWrapper(
        model: DocumentModel,
        original: CGImage,
        backgroundData: Data?,
        backgroundExtension: String?,
        customTemplate: DeviceTemplate? = nil,
        customFrameData: Data? = nil
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

        let custom = embeddableCustomTemplate(customTemplate, for: model)
        var customFrameImage: CGImage?
        if let custom {
            var assets = [
                "\(custom.id).json": FileWrapper(regularFileWithContents: try encoder.encode(custom)),
            ]
            if case .file(let file) = custom.frame, CustomTemplateStore.isSafeFileName(file), let customFrameData {
                assets[file] = FileWrapper(regularFileWithContents: customFrameData)
                customFrameImage = CustomTemplateStore.decode(customFrameData)
            }
            files[assetsFolder] = FileWrapper(directoryWithFileWrappers: assets)
        }

        if let preview = renderPreview(model: model, original: original, backgroundImage: backgroundImage,
                                       customTemplate: custom, customFrameImage: customFrameImage),
           let data = try? ImageExporter.data(for: preview, scale: 1, format: .png, jpegQuality: 1) {
            files[previewFile] = FileWrapper(regularFileWithContents: data)
        }

        return FileWrapper(directoryWithFileWrappers: files)
    }

    /// Reads a package. A custom template comes from `assets/` first, else from `store`.
    public static func read(_ wrapper: FileWrapper, store: CustomTemplateStore? = nil) throws -> LoadedDocument {
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
            if let peek = try? JSONDecoder().decode(VersionPeek.self, from: jsonData),
               peek.version > DocumentModel.currentVersion {
                throw PackageError.newerVersion(peek.version)
            }
            throw PackageError.corrupt(describe(error))
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

        let custom = loadCustomTemplate(for: model, assets: files[assetsFolder]?.fileWrappers, store: store)

        return LoadedDocument(
            model: model, original: original, backgroundImage: backgroundImage,
            backgroundData: backgroundData, isReadOnly: model.version > DocumentModel.currentVersion,
            customTemplate: custom?.template, customFrameData: custom?.frameData,
            customFrameImage: custom?.frameImage)
    }

    public static func read(from url: URL, store: CustomTemplateStore? = nil) throws -> LoadedDocument {
        // I/O errors (not found, permission) propagate unchanged; only format problems are `.corrupt`.
        try read(FileWrapper(url: url, options: .immediate), store: store)
    }

    /// Writes atomically: builds a temporary package next to `url`, then swaps it in.
    public static func write(
        model: DocumentModel,
        original: CGImage,
        backgroundData: Data?,
        backgroundExtension: String?,
        customTemplate: DeviceTemplate? = nil,
        customFrameData: Data? = nil,
        to url: URL
    ) throws {
        let wrapper = try fileWrapper(
            model: model, original: original,
            backgroundData: backgroundData, backgroundExtension: backgroundExtension,
            customTemplate: customTemplate, customFrameData: customFrameData)
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

    private struct VersionPeek: Decodable { let version: Int }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        let context: DecodingError.Context
        switch decoding {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            context = c
        @unknown default:
            return error.localizedDescription
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The id of a custom template `model` uses, or `nil` for none, a builtin or an id that cannot name a file.
    private static func customTemplateID(for model: DocumentModel) -> String? {
        guard let id = model.template?.templateID, TemplateCatalog.builtin(id: id) == nil,
              CustomTemplateStore.isValidID(id) else { return nil }
        return id
    }

    private static func embeddableCustomTemplate(_ template: DeviceTemplate?, for model: DocumentModel) -> DeviceTemplate? {
        guard let template, let id = customTemplateID(for: model), template.id == id else { return nil }
        return template
    }

    /// `assets/` first, the store second, separately for the JSON and the frame image.
    private static func loadCustomTemplate(
        for model: DocumentModel, assets: [String: FileWrapper]?, store: CustomTemplateStore?
    ) -> (template: DeviceTemplate, frameData: Data?, frameImage: CGImage?)? {
        guard let id = customTemplateID(for: model) else { return nil }
        var template: DeviceTemplate?
        if let data = assets?["\(id).json"]?.regularFileContents,
           let embedded = try? JSONDecoder().decode(DeviceTemplate.self, from: data), embedded.id == id {
            template = embedded
        } else {
            template = store?.template(id: id)
        }
        guard let template else { return nil }
        guard case .file(let file) = template.frame, CustomTemplateStore.isSafeFileName(file) else {
            return (template, nil, nil)
        }
        for data in [assets?[file]?.regularFileContents, store?.imageData(for: template)] {
            if let data, let image = CustomTemplateStore.decode(data) { return (template, data, image) }
        }
        return (template, nil, nil)
    }

    private static func renderPreview(model: DocumentModel, original: CGImage, backgroundImage: CGImage?,
                                      customTemplate: DeviceTemplate?, customFrameImage: CGImage?) -> CGImage? {
        let template = model.template.flatMap { TemplateCatalog.builtin(id: $0.templateID) } ?? customTemplate
        let input = RenderInput(original: original, crop: model.crop, style: model.style,
                                backgroundImage: backgroundImage, annotations: model.annotations,
                                originalScale: model.original.scale > 0 ? CGFloat(model.original.scale) : 1,
                                template: template, placement: model.template,
                                customFrameImage: template == nil ? nil : customFrameImage)
        guard let full = Renderer.render(input, outputScale: 1) else { return nil }
        let longest = CGFloat(max(full.width, full.height))
        guard longest > previewMaxEdge else { return full }
        return Renderer.render(input, outputScale: previewMaxEdge / longest)
    }
}
