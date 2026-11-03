import Testing
@testable import ScreenXCore

struct HotkeyErrorTests {
    private let combo = KeyCombo(keyCode: 21, modifiers: [.option, .shift])

    @Test func mapsHotkeyExistsError() {
        #expect(HotkeyError.from(status: -9878, combo: combo) == .alreadyTaken(combo))
    }

    @Test func noErrIsNil() {
        #expect(HotkeyError.from(status: 0, combo: combo) == nil)
    }

    @Test func otherStatusIsFailed() {
        #expect(HotkeyError.from(status: -50, combo: combo) == .failed(-50))
    }
}
