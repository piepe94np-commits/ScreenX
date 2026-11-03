import AppKit
import Testing
@testable import ScreenXCore

struct ClipboardTests {
    @MainActor
    @Test func clipboardContainsPNG() throws {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let image = TestImages.solid(width: 40, height: 20, color: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        Clipboard.copy(image, scale: 2, to: pasteboard)
        let data = try #require(pasteboard.data(forType: .png))
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(decoded.pixelsWide == 40)
        #expect(decoded.pixelsHigh == 20)
    }
}
