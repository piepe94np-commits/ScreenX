import AppKit
import CoreGraphics

public enum Clipboard {
    @MainActor
    public static func copy(_ image: CGImage, scale: CGFloat, to pasteboard: NSPasteboard = .general) {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let nsImage = NSImage(cgImage: image, size: size)
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
        if let png = try? ImageExporter.data(for: image, scale: scale, format: .png, jpegQuality: 1) {
            pasteboard.setData(png, forType: .png)
        }
    }
}
