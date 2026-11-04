import CoreGraphics
import Foundation

/// Maps between editor view points and original-image pixels.
///
/// The view has its origin top-left, with the canvas at (0,0). `viewScale` is view points per canvas pixel.
/// original = (view / viewScale - imageRect.origin) + crop.origin
public struct CanvasMapping: Sendable {
    private let viewScale: CGFloat
    private let imageOrigin: CGPoint
    private let cropOrigin: CGPoint

    public init(layout: CanvasLayout, crop: CGRect?, viewScale: CGFloat) {
        self.viewScale = viewScale
        self.imageOrigin = layout.imageRect.origin
        self.cropOrigin = crop?.origin ?? .zero
    }

    public func toOriginal(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / viewScale - imageOrigin.x + cropOrigin.x,
                y: viewPoint.y / viewScale - imageOrigin.y + cropOrigin.y)
    }

    public func toView(_ originalPoint: CGPoint) -> CGPoint {
        CGPoint(x: (originalPoint.x - cropOrigin.x + imageOrigin.x) * viewScale,
                y: (originalPoint.y - cropOrigin.y + imageOrigin.y) * viewScale)
    }
}
