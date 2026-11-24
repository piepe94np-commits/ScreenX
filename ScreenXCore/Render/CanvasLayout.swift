import CoreGraphics
import Foundation

/// Canvas size and image placement in original pixels, origin top-left.
public struct CanvasLayout: Equatable, Sendable {
    public let canvasSize: CGSize
    public let imageRect: CGRect

    public init(canvasSize: CGSize, imageRect: CGRect) {
        self.canvasSize = canvasSize
        self.imageRect = imageRect
    }

    /// `contentSize` is the size of the original or of the crop.
    public static func compute(contentSize: CGSize, style: Style) -> CanvasLayout {
        let pad = CGFloat(style.padding)
        var width = contentSize.width + 2 * pad
        var height = contentSize.height + 2 * pad

        // Only the too-small side grows (rounded up to whole pixels); never crops.
        if let ratio = style.aspect.ratio, width > 0, height > 0 {
            let eps = 1e-6
            if Double(width / height) < ratio {
                width = CGFloat((Double(height) * ratio - eps).rounded(.up))
            } else {
                height = CGFloat((Double(width) / ratio - eps).rounded(.up))
            }
        }

        func position(canvas: CGFloat, content: CGFloat, leading: Bool, trailing: Bool) -> CGFloat {
            if leading { return pad }
            if trailing { return canvas - content - pad }
            return ((canvas - content) / 2).rounded(.down)
        }

        let a = style.alignment
        let x = position(canvas: width, content: contentSize.width,
                         leading: [.topLeading, .leading, .bottomLeading].contains(a),
                         trailing: [.topTrailing, .trailing, .bottomTrailing].contains(a))
        let y = position(canvas: height, content: contentSize.height,
                         leading: [.topLeading, .top, .topTrailing].contains(a),
                         trailing: [.bottomLeading, .bottom, .bottomTrailing].contains(a))

        return CanvasLayout(canvasSize: CGSize(width: width, height: height),
                            imageRect: CGRect(x: x, y: y, width: contentSize.width, height: contentSize.height))
    }
}
