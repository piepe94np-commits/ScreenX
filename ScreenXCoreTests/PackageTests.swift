import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenXCore

struct PackageTests {
    private func model(width: Int = 40, height: Int = 20, background: Background? = nil) -> DocumentModel {
        var style = Style.default
        if let background { style.background = background }
        return DocumentModel(
            original: OriginalInfo(pixelWidth: width, pixelHeight: height, scale: 2, mode: .area, windowTitle: "Titel"),
            crop: CGRect(x: 1, y: 2, width: 10, height: 8),
            style: style)
    }

    private func original(_ w: Int = 40, _ h: Int = 20) -> CGImage {
        TestImages.solid(width: w, height: h, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    }

    private func replacing(_ wrapper: FileWrapper, name: String, with data: Data?) -> FileWrapper {
        var files = wrapper.fileWrappers ?? [:]
        files[name] = data.map { FileWrapper(regularFileWithContents: $0) }
        return FileWrapper(directoryWithFileWrappers: files)
    }

    @Test func jsonFieldNames() throws {
        var m = model()
        m.crop = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(m), as: UTF8.self)
        #expect(json.contains("\"version\":1"))
        #expect(json.contains("\"original\":{\"file\":\"original.png\""))
        #expect(json.contains("\"crop\":null"))
        #expect(json.contains("\"template\":null"))
        #expect(json.contains("\"annotations\":[]"))
    }

    @Test func roundTrip() throws {
        let m = model()
        let wrapper = try ScreenXPackage.fileWrapper(
            model: m, original: original(), backgroundData: nil, backgroundExtension: nil)
        let loaded = try ScreenXPackage.read(wrapper)
        #expect(loaded.model == m)
        #expect(loaded.original.width == 40)
        #expect(loaded.original.height == 20)
        #expect(loaded.isReadOnly == false)
        #expect(loaded.backgroundImage == nil)
    }

    @Test func roundTripWithBackgroundImage() throws {
        let m = model(background: .image(file: "background.png"))
        let bg = TestImages.solid(width: 8, height: 8, color: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        let bgData = try ImageExporter.data(for: bg, scale: 1, format: .png, jpegQuality: 1)
        let wrapper = try ScreenXPackage.fileWrapper(
            model: m, original: original(), backgroundData: bgData, backgroundExtension: "png")
        #expect(wrapper.fileWrappers?["background.png"] != nil)
        let loaded = try ScreenXPackage.read(wrapper)
        #expect(loaded.backgroundImage != nil)
        #expect(loaded.backgroundData != nil)
        #expect(loaded.model.style.background == .image(file: "background.png"))
    }

    @Test func writesPreviewMax1024() throws {
        let m = model(width: 3000, height: 1000)
        let wrapper = try ScreenXPackage.fileWrapper(
            model: m, original: original(3000, 1000), backgroundData: nil, backgroundExtension: nil)
        let data = try #require(wrapper.fileWrappers?["preview.png"]?.regularFileContents)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width <= 1024)
        #expect(image.width > 0)
    }

    @Test func missingOriginalThrows() throws {
        let wrapper = try ScreenXPackage.fileWrapper(
            model: model(), original: original(), backgroundData: nil, backgroundExtension: nil)
        let broken = replacing(wrapper, name: "original.png", with: nil)
        #expect(throws: PackageError.missingOriginal) { try ScreenXPackage.read(broken) }
    }

    @Test func corruptJSONThrows() throws {
        let wrapper = try ScreenXPackage.fileWrapper(
            model: model(), original: original(), backgroundData: nil, backgroundExtension: nil)
        let broken = replacing(wrapper, name: "document.json", with: Data("{".utf8))
        do {
            _ = try ScreenXPackage.read(broken)
            Issue.record("expected error")
        } catch let error as PackageError {
            guard case .corrupt = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test func newerVersionReadOnly() throws {
        var m = model()
        m.version = 99
        let wrapper = try ScreenXPackage.fileWrapper(
            model: m, original: original(), backgroundData: nil, backgroundExtension: nil)
        let loaded = try ScreenXPackage.read(wrapper)
        #expect(loaded.isReadOnly == true)
    }

    @Test func writeToURLAndBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screenx-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.screenx")
        let m = model()
        try ScreenXPackage.write(model: m, original: original(), backgroundData: nil, backgroundExtension: nil, to: url)
        try ScreenXPackage.write(model: m, original: original(), backgroundData: nil, backgroundExtension: nil, to: url)
        let loaded = try ScreenXPackage.read(from: url)
        #expect(loaded.model == m)
        #expect(loaded.original.width == 40)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["x.screenx"])
    }
}
