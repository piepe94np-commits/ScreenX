import CoreGraphics

public struct WindowInfo: Sendable, Equatable {
    public let id: UInt32
    /// Global, Ursprung oben links.
    public let frame: CGRect
    public let layer: Int
    public let ownerPID: Int32
    public let title: String?

    public init(id: UInt32, frame: CGRect, layer: Int, ownerPID: Int32, title: String?) {
        self.id = id
        self.frame = frame
        self.layer = layer
        self.ownerPID = ownerPID
        self.title = title
    }
}

public enum WindowHitTester {
    static let minimumWindowSize: CGFloat = 40

    /// `point` und `WindowInfo.frame` liegen im selben Raum (global, oben links).
    /// `windows` ist von vorne nach hinten sortiert.
    public static func window(at point: CGPoint, in windows: [WindowInfo], excludingPID: Int32) -> WindowInfo? {
        windows.first { w in
            w.ownerPID != excludingPID
                && w.layer == 0
                && w.frame.width >= minimumWindowSize
                && w.frame.height >= minimumWindowSize
                && w.frame.contains(point)
        }
    }
}
