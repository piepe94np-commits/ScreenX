import CoreGraphics

public enum ImageCropper {
    /// Schneidet `pixelRect` (Ursprung oben links) aus dem Bild. `nil`, wenn nach dem
    /// Begrenzen auf die Bildgröße nichts übrig bleibt.
    public static func crop(_ image: CGImage, to pixelRect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = pixelRect.standardized.integral.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return image.cropping(to: clipped)
    }
}
