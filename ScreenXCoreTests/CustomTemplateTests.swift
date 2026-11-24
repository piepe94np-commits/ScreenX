import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenXCore

struct CustomTemplateTests {
    private static let quad = [CGPoint(x: 20, y: 10), CGPoint(x: 180, y: 10),
                               CGPoint(x: 180, y: 100), CGPoint(x: 20, y: 100)]

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("screenx-templates-\(UUID())", isDirectory: true)
    }

    private static func frameData(_ w: Int = 200, _ h: Int = 120) throws -> Data {
        let image = TestImages.solid(width: w, height: h, color: CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        return try ImageExporter.data(for: image, scale: 1, format: .png, jpegQuality: 1)
    }

    private static func model(template: String?) -> DocumentModel {
        DocumentModel(
            original: OriginalInfo(pixelWidth: 160, pixelHeight: 90, scale: 1, mode: .area, windowTitle: nil),
            style: .default,
            template: template.map { TemplatePlacement(templateID: $0) })
    }

    private static func original() -> CGImage {
        TestImages.solid(width: 160, height: 90, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    }

    @Test func addListDelete() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CustomTemplateStore(directory: dir)
        #expect(store.all().isEmpty)

        let template = try store.add(name: "  Mein Gerät ", imageData: Self.frameData(),
                                     imageExtension: "PNG", quad: Self.quad)
        #expect(template.id.hasPrefix("custom-"))
        #expect(UUID(uuidString: String(template.id.dropFirst("custom-".count))) != nil)
        #expect(template.name == "Mein Gerät")
        #expect(template.frame == .file("\(template.id).png"))
        #expect(template.frameSize == CGSize(width: 200, height: 120))
        #expect(template.screenQuad == Self.quad)
        #expect(template.screenCornerRadius == 0)
        #expect(template.preferredAspect == [16, 9])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["\(template.id).json", "\(template.id).png"])

        // A corrupt JSON file does not hide the others.
        try Data("{".utf8).write(to: dir.appendingPathComponent("custom-\(UUID()).json"))
        #expect(store.all() == [template])
        #expect(store.template(id: template.id) == template)
        let image = try #require(store.image(for: template))
        #expect(image.width == 200 && image.height == 120)

        try store.delete(id: template.id)
        #expect(store.all().isEmpty)
        #expect(store.image(for: template) == nil)
        try store.delete(id: template.id)
        try store.delete(id: "../etc")
    }

    @Test func quadValidation() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CustomTemplateStore(directory: dir)
        let data = try Self.frameData()
        #expect(throws: TemplateError.invalidQuad) {
            try store.add(name: "x", imageData: data, imageExtension: "png", quad: Array(Self.quad.prefix(3)))
        }
        #expect(throws: TemplateError.invalidQuad) {
            try store.add(name: "x", imageData: data, imageExtension: "png", quad: Self.quad + [.zero])
        }
        #expect(throws: TemplateError.invalidQuad) {
            try store.add(name: "x", imageData: data, imageExtension: "png",
                          quad: [.zero, CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)])
        }
        #expect(throws: TemplateError.invalidQuad) {
            try store.add(name: "x", imageData: data, imageExtension: "png",
                          quad: [.zero, CGPoint(x: 500, y: 0), CGPoint(x: 500, y: 10), CGPoint(x: 0, y: 10)])
        }
        #expect(throws: TemplateError.unsupportedImageType("../png")) {
            try store.add(name: "x", imageData: data, imageExtension: "../png", quad: Self.quad)
        }
        #expect(throws: TemplateError.unreadableImage) {
            try store.add(name: "x", imageData: Data("nope".utf8), imageExtension: "png", quad: Self.quad)
        }
        #expect(throws: TemplateError.imageTooLarge) {
            try store.add(name: "x", imageData: try Self.frameData(16385, 1), imageExtension: "png",
                          quad: [.zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 1), CGPoint(x: 0, y: 1)])
        }
        #expect(store.all().isEmpty)
        #expect(TemplateError.invalidQuad.errorDescription?.isEmpty == false)
        #expect(TemplateError.imageTooLarge.errorDescription?.isEmpty == false)
    }

    /// Embedded JSON with absurd geometry, an unsafe frame name or another id counts as corrupt.
    @Test func invalidEmbeddedTemplatesAreIgnored() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CustomTemplateStore(directory: dir)
        let template = try store.add(name: "Rahmen", imageData: Self.frameData(),
                                     imageExtension: "png", quad: Self.quad)
        let wrapper = try ScreenXPackage.fileWrapper(
            model: Self.model(template: template.id), original: Self.original(),
            backgroundData: nil, backgroundExtension: nil,
            customTemplate: template, customFrameData: store.imageData(for: template))
        let assets = try #require(wrapper.fileWrappers?["assets"]?.fileWrappers)
        let json = try #require(assets["\(template.id).json"]?.regularFileContents)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])

        func read(patching key: String, _ value: Any) throws -> LoadedDocument {
            var patched = object
            patched[key] = value
            var newAssets = assets
            newAssets["\(template.id).json"] = FileWrapper(
                regularFileWithContents: try JSONSerialization.data(withJSONObject: patched))
            var files = wrapper.fileWrappers ?? [:]
            files["assets"] = FileWrapper(directoryWithFileWrappers: newAssets)
            return try ScreenXPackage.read(FileWrapper(directoryWithFileWrappers: files))
        }

        #expect(try ScreenXPackage.read(wrapper).customTemplate == template)
        #expect(try read(patching: "frameSize", [1e20, 1e20]).customTemplate == nil)
        #expect(try read(patching: "frameSize", [0, 120]).customTemplate == nil)
        #expect(try read(patching: "frame", ["file": "../x.png"]).customTemplate == nil)
        #expect(try read(patching: "frame", ["builtin": "laptop-silver"]).customTemplate == nil)
        #expect(try read(patching: "id", "custom-\(UUID())").customTemplate == nil)
        #expect(try read(patching: "screenQuad", [[0, 0], [500, 0], [500, 50], [0, 50]]).customTemplate == nil)
        #expect(try read(patching: "screenCornerRadius", -1).customTemplate == nil)

        // The same JSON in the store is skipped there too.
        var huge = object
        huge["frameSize"] = [1e20, 1e20]
        try JSONSerialization.data(withJSONObject: huge).write(to: dir.appendingPathComponent("\(template.id).json"))
        #expect(store.template(id: template.id) == nil)
        #expect(store.all().isEmpty)
    }

    @Test func deleteInMissingFolderIsNoOp() throws {
        let store = CustomTemplateStore(directory: Self.tempDirectory())
        try store.delete(id: "custom-\(UUID())")
        #expect(store.all().isEmpty)
    }

    @Test func customTemplateEmbeddedInPackage() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeDir = dir.appendingPathComponent("Templates", isDirectory: true)
        let store = CustomTemplateStore(directory: storeDir)
        let template = try store.add(name: "Rahmen", imageData: Self.frameData(),
                                     imageExtension: "png", quad: Self.quad)
        let frameData = try #require(store.imageData(for: template))
        let model = Self.model(template: template.id)
        let url = dir.appendingPathComponent("doc.screenx")
        try ScreenXPackage.write(model: model, original: Self.original(), backgroundData: nil,
                                 backgroundExtension: nil, customTemplate: template,
                                 customFrameData: frameData, to: url)
        let assets = try FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("assets").path).sorted()
        #expect(assets == ["\(template.id).json", "\(template.id).png"])

        try FileManager.default.removeItem(at: storeDir)
        #expect(store.template(id: template.id) == nil)

        let loaded = try ScreenXPackage.read(from: url, store: store)
        #expect(loaded.model == model)
        #expect(loaded.customTemplate == template)
        #expect(loaded.customFrameData == frameData)
        let image = try #require(loaded.customFrameImage)
        #expect(image.width == 200 && image.height == 120)

        // Saving the loaded document again keeps the embedded template.
        let again = try ScreenXPackage.fileWrapper(
            model: loaded.model, original: loaded.original, backgroundData: nil, backgroundExtension: nil,
            customTemplate: loaded.customTemplate, customFrameData: loaded.customFrameData)
        #expect(again.fileWrappers?["assets"]?.fileWrappers?["\(template.id).png"] != nil)

        // Neither in assets nor in the store: no template, the placement stays.
        var files = again.fileWrappers ?? [:]
        files["assets"] = nil
        let stripped = try ScreenXPackage.read(FileWrapper(directoryWithFileWrappers: files), store: store)
        #expect(stripped.customTemplate == nil)
        #expect(stripped.customFrameImage == nil)
        #expect(stripped.model.template?.templateID == template.id)
    }

    @Test func storeIsFallbackWhenAssetsMissing() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CustomTemplateStore(directory: dir)
        let template = try store.add(name: "Rahmen", imageData: Self.frameData(),
                                     imageExtension: "png", quad: Self.quad)
        // Written without the template: nothing is embedded.
        let wrapper = try ScreenXPackage.fileWrapper(
            model: Self.model(template: template.id), original: Self.original(),
            backgroundData: nil, backgroundExtension: nil)
        #expect(wrapper.fileWrappers?["assets"] == nil)
        let loaded = try ScreenXPackage.read(wrapper, store: store)
        #expect(loaded.customTemplate == template)
        #expect(loaded.customFrameImage?.width == 200)
    }

    @Test func builtinNotEmbedded() throws {
        let phone = try #require(TemplateCatalog.builtin(id: "phone-portrait-dark"))
        let wrapper = try ScreenXPackage.fileWrapper(
            model: Self.model(template: phone.id), original: Self.original(),
            backgroundData: nil, backgroundExtension: nil,
            customTemplate: phone, customFrameData: try Self.frameData())
        #expect(wrapper.fileWrappers?["assets"] == nil)
        let loaded = try ScreenXPackage.read(wrapper)
        #expect(loaded.customTemplate == nil)
        #expect(loaded.model.template?.templateID == phone.id)
    }

    @Test func previewShowsTemplate() throws {
        // A portrait phone around 16:9 content gives a portrait preview.
        let wrapper = try ScreenXPackage.fileWrapper(
            model: Self.model(template: "phone-portrait-dark"), original: Self.original(),
            backgroundData: nil, backgroundExtension: nil)
        let data = try #require(wrapper.fileWrappers?["preview.png"]?.regularFileContents)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.height > image.width)
    }
}
