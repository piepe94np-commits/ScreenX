import CoreGraphics

/// Ein Monitor. `frame` liegt im globalen AppKit-Koordinatensystem (Ursprung unten links).
public struct DisplayInfo: Sendable, Equatable {
    public let id: UInt32
    public let frame: CGRect
    public let scale: CGFloat

    public init(id: UInt32, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}
