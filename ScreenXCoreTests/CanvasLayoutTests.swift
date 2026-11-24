import CoreGraphics
import Testing
@testable import ScreenXCore

struct CanvasLayoutTests {
    private func style(padding: Double, aspect: AspectRatio = .auto, alignment: ContentAlignment = .center) -> Style {
        var s = Style.default
        s.padding = padding
        s.aspect = aspect
        s.alignment = alignment
        return s
    }

    @Test func autoAddsPadding() {
        let l = CanvasLayout.compute(contentSize: CGSize(width: 1000, height: 500), style: style(padding: 64))
        #expect(l.canvasSize == CGSize(width: 1128, height: 628))
        #expect(l.imageRect == CGRect(x: 64, y: 64, width: 1000, height: 500))
    }

    @Test func aspectExpandsNeverCrops() {
        let a = CanvasLayout.compute(contentSize: CGSize(width: 1000, height: 1000),
                                     style: style(padding: 0, aspect: .r16x9))
        #expect(a.canvasSize == CGSize(width: 1778, height: 1000))
        #expect(a.imageRect.origin.x == 389)
        let b = CanvasLayout.compute(contentSize: CGSize(width: 1600, height: 500),
                                     style: style(padding: 0, aspect: .r1x1))
        #expect(b.canvasSize == CGSize(width: 1600, height: 1600))
    }

    @Test func exactRatioDoesNotGrow() {
        let l = CanvasLayout.compute(contentSize: CGSize(width: 1600, height: 900),
                                     style: style(padding: 0, aspect: .r16x9))
        #expect(l.canvasSize == CGSize(width: 1600, height: 900))
    }

    @Test func alignmentTopLeading() {
        let l = CanvasLayout.compute(contentSize: CGSize(width: 1000, height: 1000),
                                     style: style(padding: 50, aspect: .r16x9, alignment: .topLeading))
        #expect(l.canvasSize == CGSize(width: 1956, height: 1100))
        #expect(l.imageRect.origin == CGPoint(x: 50, y: 50))
    }

    @Test func alignmentBottomTrailing() {
        let l = CanvasLayout.compute(contentSize: CGSize(width: 1000, height: 1000),
                                     style: style(padding: 50, aspect: .r16x9, alignment: .bottomTrailing))
        #expect(l.imageRect.origin == CGPoint(x: 906, y: 50))
    }

    @Test func paddingZeroAuto() {
        let l = CanvasLayout.compute(contentSize: CGSize(width: 300, height: 200), style: style(padding: 0))
        #expect(l.canvasSize == CGSize(width: 300, height: 200))
        #expect(l.imageRect == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func exportScaleFactors() {
        #expect(ExportScaling.factor(.original, captureScale: 2) == 1)
        #expect(ExportScaling.factor(.x1, captureScale: 2) == 0.5)
        #expect(ExportScaling.factor(.x2, captureScale: 2) == 1)
        #expect(ExportScaling.factor(.x2, captureScale: 1) == 2)
    }
}
