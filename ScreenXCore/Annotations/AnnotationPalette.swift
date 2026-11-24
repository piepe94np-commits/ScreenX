import Foundation

/// Fixed color choices and defaults for annotations.
public enum AnnotationPalette {
    public static let colors: [ColorValue] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#0A84FF", "#AF52DE", "#FFFFFF", "#1D1D1F",
    ].map { ColorValue(hex: $0)! }

    /// Yellow, pink, green, blue, orange.
    public static let noteColors: [ColorValue] = [
        "#FFE066", "#FFB3C7", "#B5EAD7", "#A0C4FF", "#FFD6A5",
    ].map { ColorValue(hex: $0)! }

    public static let defaultColor = ColorValue(hex: "#FF3B30")!
    public static let defaultStrokeWidth: Double = 6
}
