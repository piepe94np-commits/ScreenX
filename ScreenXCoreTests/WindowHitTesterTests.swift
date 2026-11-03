import CoreGraphics
import Testing
@testable import ScreenXCore

struct WindowHitTesterTests {
    private func win(_ id: UInt32, _ frame: CGRect, layer: Int = 0, pid: Int32 = 100) -> WindowInfo {
        WindowInfo(id: id, frame: frame, layer: layer, ownerPID: pid, title: nil)
    }

    @Test func hitTestPicksFrontmost() {
        let front = win(1, CGRect(x: 0, y: 0, width: 200, height: 200))
        let back = win(2, CGRect(x: 50, y: 50, width: 300, height: 300))
        #expect(WindowHitTester.window(at: CGPoint(x: 100, y: 100), in: [front, back], excludingPID: 1)?.id == 1)
    }

    @Test func hitTestSkipsOwnAndNonZeroLayer() {
        let own = win(1, CGRect(x: 0, y: 0, width: 200, height: 200), pid: 7)
        let menu = win(2, CGRect(x: 0, y: 0, width: 200, height: 200), layer: 25)
        let tiny = win(3, CGRect(x: 0, y: 0, width: 39, height: 200))
        let normal = win(4, CGRect(x: 0, y: 0, width: 200, height: 200))
        let hit = WindowHitTester.window(at: CGPoint(x: 10, y: 10), in: [own, menu, tiny, normal], excludingPID: 7)
        #expect(hit?.id == 4)
    }

    @Test func hitTestNoneOnDesktop() {
        let w = win(1, CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(WindowHitTester.window(at: CGPoint(x: 500, y: 500), in: [w], excludingPID: 1) == nil)
    }
}
