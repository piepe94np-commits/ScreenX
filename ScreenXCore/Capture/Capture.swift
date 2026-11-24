import CoreGraphics
import Foundation

public enum CaptureMode: String, Codable, Sendable, CaseIterable {
    case area
    case window
    case fullscreen
}

extension CaptureMode: CodingKeyRepresentable {
    public var codingKey: any CodingKey { _CaptureModeKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

private struct _CaptureModeKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public struct Capture: Sendable {
    public let image: CGImage
    public let scale: CGFloat
    public let mode: CaptureMode
    public let date: Date
    public let windowTitle: String?

    public init(image: CGImage, scale: CGFloat, mode: CaptureMode, date: Date, windowTitle: String? = nil) {
        self.image = image
        self.scale = scale
        self.mode = mode
        self.date = date
        self.windowTitle = windowTitle
    }
}
