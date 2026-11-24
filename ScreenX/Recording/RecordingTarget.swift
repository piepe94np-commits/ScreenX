import CoreGraphics

/// What a video recording captures.
enum RecordingTarget: Sendable, Equatable {
    /// A whole display.
    case display(CGDirectDisplayID)
    /// A rectangle on a display, in points relative to the display's top-left corner.
    case area(CGDirectDisplayID, CGRect)
    /// A single window, independent of what covers it.
    case window(CGWindowID)
}
