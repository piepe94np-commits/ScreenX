import Foundation
import Testing
@testable import ScreenXCore

struct StyleTests {
    @Test func defaultStyleMatchesSpec() {
        let s = Style.default
        #expect(s.padding == 64)
        #expect(s.cornerRadius == 12)
        #expect(s.shadow.strength == 50)
        #expect(s.shadow.offsetY == nil && s.shadow.blur == nil && s.shadow.opacity == nil)
        #expect(s.keepWindowShadow == false)
        #expect(s.aspect == .auto)
        #expect(s.alignment == .center)
        #expect(s.background == GradientPresets.all[0])
    }

    @Test func styleJSONShape() throws {
        let data = try JSONEncoder().encode(Style.default)
        // Key order in JSONEncoder output is unspecified, so inspect the parsed structure.
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let background = try #require(root["background"] as? [String: Any])
        #expect(background["type"] as? String == "gradient")
        #expect(background["angle"] as? Double == 135)
        #expect(root["aspect"] as? String == "auto")
        #expect(root["alignment"] as? String == "center")
        #expect(root["padding"] as? Double == 64)
        #expect(root["cornerRadius"] as? Double == 12)
        let shadow = try #require(root["shadow"] as? [String: Any])
        #expect(shadow["strength"] as? Double == 50)
        #expect(shadow["offsetY"] is NSNull)
        let stops = try #require(background["stops"] as? [[String: Any]])
        #expect(stops.first?["color"] as? String == "#FF9A6B")
        let decoded = try JSONDecoder().decode(Style.self, from: data)
        #expect(decoded == Style.default)
    }

    @Test func backgroundRoundTripAllCases() throws {
        let cases: [Background] = [
            .gradient(stops: [GradientStop(color: ColorValue(hex: "#112233")!, location: 0),
                              GradientStop(color: ColorValue(hex: "#44556680")!, location: 1)], angle: 45),
            .solid(ColorValue(hex: "#ABCDEF")!),
            .image(file: "background.png"),
            .blurredScreenshot(radius: 24),
            .none,
        ]
        for background in cases {
            let data = try JSONEncoder().encode(background)
            #expect(try JSONDecoder().decode(Background.self, from: data) == background)
        }
        let blurred = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cases[3])) as? [String: Any]
        #expect(blurred?["type"] as? String == "blurred")
    }

    @Test func colorHexParsing() throws {
        let opaque = try #require(ColorValue(hex: "#FF9A6B"))
        #expect(opaque.alpha == 1)
        #expect(opaque.hex == "#FF9A6B")
        let translucent = try #require(ColorValue(hex: "#00000080"))
        #expect(abs(translucent.alpha - 0.502) < 0.001)
        #expect(translucent.hex == "#00000080")
        #expect(ColorValue(hex: "zz") == nil)
        #expect(ColorValue(hex: "#ff9a6b")?.hex == "#FF9A6B")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ColorValue.self, from: Data("\"nope\"".utf8))
        }
    }

    @Test func shadowResolvedDefaults() {
        let r = ShadowStyle(strength: 50).resolved()
        #expect(r.offsetY == 20)
        #expect(r.blur == 40)
        #expect(abs(r.opacity - 0.275) < 1e-9)
        let o = ShadowStyle(strength: 50, offsetY: 5).resolved()
        #expect(o.offsetY == 5)
        #expect(o.blur == 40)
        #expect(abs(o.opacity - 0.275) < 1e-9)
    }

    @Test func aspectRatios() throws {
        #expect(AspectRatio.r16x9.ratio == 16.0 / 9.0)
        #expect(AspectRatio.auto.ratio == nil)
        let decoded = try JSONDecoder().decode(AspectRatio.self, from: Data("\"9:16\"".utf8))
        #expect(decoded == .r9x16)
        for a in AspectRatio.allCases {
            let data = try JSONEncoder().encode(a)
            #expect(try JSONDecoder().decode(AspectRatio.self, from: data) == a)
        }
    }

    @Test func alignmentJSONValues() throws {
        let data = try JSONEncoder().encode(ContentAlignment.topLeading)
        #expect(String(decoding: data, as: UTF8.self) == "\"topLeft\"")
        for a in ContentAlignment.allCases {
            let d = try JSONEncoder().encode(a)
            #expect(try JSONDecoder().decode(ContentAlignment.self, from: d) == a)
        }
    }

    @Test func presetsCount() {
        #expect(GradientPresets.all.count == 12)
    }

    @Test func newCaptureStyleUsesLastStyleWhenEnabled() {
        var last = Style.default
        last.padding = 120
        last.background = .solid(ColorValue(red: 1, green: 0, blue: 0, alpha: 1))
        last.keepWindowShadow = true
        let style = Style.forNewCapture(lastStyle: last, applyLastStyle: true)
        #expect(style.padding == 120)
        #expect(style.background == last.background)
        #expect(style.keepWindowShadow == false)
    }

    @Test func newCaptureStyleIsDefaultWhenDisabledOrMissing() {
        var last = Style.default
        last.padding = 120
        #expect(Style.forNewCapture(lastStyle: last, applyLastStyle: false) == .default)
        #expect(Style.forNewCapture(lastStyle: nil, applyLastStyle: true) == .default)
    }

    @Test func newCaptureStyleReplacesImageBackground() {
        var last = Style.default
        last.cornerRadius = 30
        last.background = .image(file: "background.png")
        let style = Style.forNewCapture(lastStyle: last, applyLastStyle: true)
        #expect(style.background == Style.default.background)
        #expect(style.cornerRadius == 30)
    }
}
