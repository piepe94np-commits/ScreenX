import CoreGraphics

public enum ExportScale: String, Codable, Sendable, CaseIterable {
    case original, x1, x2
}

public enum ExportScaling {
    /// Factor applied to original-pixel geometry. `x1`/`x2` are relative to points,
    /// so they divide by the capture's backing scale.
    public static func factor(_ s: ExportScale, captureScale: CGFloat) -> CGFloat {
        switch s {
        case .original: 1
        case .x1: 1 / captureScale
        case .x2: 2 / captureScale
        }
    }
}
