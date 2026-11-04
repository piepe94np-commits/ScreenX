import CoreGraphics
import Foundation
import Testing
@testable import ScreenXCore

struct AnnotationGeometryTests {
    private func rect(_ r: CGRect, filled: Bool = true, kind: ShapeKind = .rectangle,
                      width: Double = 6, rotation: Double = 0) -> Annotation {
        Annotation(kind: .shape(kind: kind, rect: r, filled: filled), strokeWidth: width, rotation: rotation)
    }

    private func counter(_ n: Int) -> Annotation {
        Annotation(kind: .counter(center: .zero, number: n, radius: 10))
    }

    @Test func hitTestTopmostWins() {
        let a = rect(CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = rect(CGRect(x: 50, y: 50, width: 100, height: 100))
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 70, y: 70), in: [a, b], tolerance: 4) == b.id)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 10, y: 10), in: [a, b], tolerance: 4) == a.id)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 300, y: 300), in: [a, b], tolerance: 4) == nil)
    }

    @Test func hitTestLineTolerance() {
        let line = Annotation(kind: .arrow(start: .zero, end: CGPoint(x: 100, y: 0), control: nil, head: .filled),
                              strokeWidth: 1)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 7), in: [line], tolerance: 8) == line.id)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 12), in: [line], tolerance: 8) == nil)
    }

    @Test func hitTestCurvedArrow() {
        let arrow = Annotation(kind: .arrow(start: .zero, end: CGPoint(x: 100, y: 0),
                                            control: CGPoint(x: 50, y: 100), head: .open), strokeWidth: 2)
        // The curve passes through (50, 50) at t = 0.5.
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 50), in: [arrow], tolerance: 2) == arrow.id)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 0), in: [arrow], tolerance: 2) == nil)
    }

    @Test func hitTestOutlineOnlyBorder() {
        let outline = rect(CGRect(x: 0, y: 0, width: 100, height: 100), filled: false, width: 4)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 50), in: [outline], tolerance: 4) == nil)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 2, y: 50), in: [outline], tolerance: 4) == outline.id)
    }

    @Test func hitTestEllipse() {
        let filled = rect(CGRect(x: 0, y: 0, width: 100, height: 50), kind: .ellipse)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 25), in: [filled], tolerance: 4) == filled.id)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 2, y: 2), in: [filled], tolerance: 4) == nil)
        let outline = rect(CGRect(x: 0, y: 0, width: 100, height: 50), filled: false, kind: .ellipse, width: 4)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 25), in: [outline], tolerance: 4) == nil)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 100, y: 25), in: [outline], tolerance: 4) == outline.id)
    }

    @Test func hitTestRotated() {
        let a = rect(CGRect(x: 0, y: 0, width: 100, height: 20), rotation: .pi / 2)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 50), in: [a], tolerance: 4) == a.id)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 90, y: 10), in: [a], tolerance: 4) == nil)
    }

    @Test func hitTestLineShapeWithNegativeSize() {
        let line = rect(CGRect(x: 100, y: 100, width: -100, height: -100), kind: .line, width: 2)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 50), in: [line], tolerance: 4) == line.id)
        #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 90), in: [line], tolerance: 4) == nil)
    }

    @Test func bounds() {
        let arrow = Annotation(kind: .arrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 0, y: 20),
                                            control: CGPoint(x: 30, y: 5), head: .filled))
        #expect(AnnotationGeometry.bounds(arrow) == CGRect(x: 0, y: 5, width: 30, height: 15))
        let line = rect(CGRect(x: 50, y: 50, width: -20, height: -10), kind: .line)
        #expect(AnnotationGeometry.bounds(line) == CGRect(x: 30, y: 40, width: 20, height: 10))
        #expect(AnnotationGeometry.bounds(counter(1)) == CGRect(x: -10, y: -10, width: 20, height: 20))
        let note = Annotation(kind: .note(frame: CGRect(x: 1, y: 2, width: 3, height: 4), string: "",
                                          noteColor: AnnotationPalette.noteColors[0]))
        #expect(AnnotationGeometry.bounds(note) == CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    @Test func handlesPerKind() {
        let r = rect(CGRect(x: 0, y: 0, width: 100, height: 50))
        let h = AnnotationGeometry.handles(for: r)
        #expect(h.count == 9)
        #expect(h[.rotate] == CGPoint(x: 50, y: -30))
        #expect(h[.bottomRight] == CGPoint(x: 100, y: 50))
        #expect(AnnotationGeometry.handles(for: counter(1)).isEmpty)
        let straight = Annotation(kind: .arrow(start: .zero, end: CGPoint(x: 5, y: 5), control: nil, head: .filled))
        #expect(Set(AnnotationGeometry.handles(for: straight).keys) == [.start, .end])
        let curved = Annotation(kind: .arrow(start: .zero, end: CGPoint(x: 5, y: 5), control: CGPoint(x: 1, y: 4),
                                             head: .filled))
        #expect(Set(AnnotationGeometry.handles(for: curved).keys) == [.start, .end, .control])
        let line = rect(CGRect(x: 0, y: 0, width: -10, height: 5), kind: .line)
        #expect(AnnotationGeometry.handles(for: line) == [.start: .zero, .end: CGPoint(x: -10, y: 5)])
    }

    @Test func snapAngle45() {
        let p = AnnotationGeometry.snapAngle(from: .zero, to: CGPoint(x: 100, y: 10))
        #expect(abs(p.x - 100.4988) < 0.01)
        #expect(abs(p.y) < 1e-9)
        let q = AnnotationGeometry.snapAngle(from: .zero, to: CGPoint(x: 70, y: 72))
        #expect(q.x == q.y)
        let r = AnnotationGeometry.snapAngle(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: -20))
        #expect(abs(r.x - 10) < 1e-9 && abs(r.y + 20) < 1e-9)
    }

    @Test func constrainedSquare() {
        #expect(AnnotationGeometry.constrainedRect(from: .zero, to: CGPoint(x: 30, y: 80), proportional: true)
            == CGRect(x: 0, y: 0, width: 80, height: 80))
        #expect(AnnotationGeometry.constrainedRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 70, y: 120),
                                                   proportional: true)
            == CGRect(x: 70, y: 70, width: 30, height: 30))
        #expect(AnnotationGeometry.constrainedRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 0, y: 40),
                                                   proportional: false)
            == CGRect(x: 0, y: 10, width: 10, height: 30))
    }

    @Test func resizeKeepsOpposite() {
        let a = rect(CGRect(x: 10, y: 10, width: 100, height: 50))
        let b = AnnotationGeometry.resized(a, handle: .bottomRight, to: CGPoint(x: 210, y: 110), proportional: false)
        #expect(AnnotationGeometry.bounds(b) == CGRect(x: 10, y: 10, width: 200, height: 100))
        let c = AnnotationGeometry.resized(a, handle: .left, to: CGPoint(x: 0, y: 999), proportional: false)
        #expect(AnnotationGeometry.bounds(c) == CGRect(x: 0, y: 10, width: 110, height: 50))
        let flipped = AnnotationGeometry.resized(a, handle: .right, to: CGPoint(x: -10, y: 0), proportional: false)
        #expect(AnnotationGeometry.bounds(flipped) == CGRect(x: -10, y: 10, width: 20, height: 50))
    }

    @Test func resizeProportional() {
        let a = rect(CGRect(x: 0, y: 0, width: 100, height: 50))
        let b = AnnotationGeometry.resized(a, handle: .bottomRight, to: CGPoint(x: 200, y: 60), proportional: true)
        #expect(AnnotationGeometry.bounds(b) == CGRect(x: 0, y: 0, width: 200, height: 100))
        let c = AnnotationGeometry.resized(a, handle: .topLeft, to: CGPoint(x: 50, y: 25), proportional: true)
        #expect(AnnotationGeometry.bounds(c) == CGRect(x: 50, y: 25, width: 50, height: 25))
    }

    @Test func resizeLineAndArrowEndpoints() {
        let line = rect(CGRect(x: 0, y: 0, width: 10, height: 10), kind: .line)
        let moved = AnnotationGeometry.resized(line, handle: .start, to: CGPoint(x: 20, y: 5), proportional: false)
        #expect(AnnotationGeometry.handles(for: moved) == [.start: CGPoint(x: 20, y: 5), .end: CGPoint(x: 10, y: 10)])
        let arrow = Annotation(kind: .arrow(start: .zero, end: CGPoint(x: 10, y: 10), control: nil, head: .filled))
        let r = AnnotationGeometry.resized(arrow, handle: .end, to: CGPoint(x: 3, y: 4), proportional: false)
        #expect(AnnotationGeometry.handles(for: r)[.end] == CGPoint(x: 3, y: 4))
    }

    @Test func moveArrow() {
        let a = Annotation(kind: .arrow(start: .zero, end: CGPoint(x: 10, y: 10), control: CGPoint(x: 5, y: 0),
                                        head: .filled))
        let m = AnnotationGeometry.moved(a, by: CGVector(dx: 5, dy: 5))
        #expect(m.kind == .arrow(start: CGPoint(x: 5, y: 5), end: CGPoint(x: 15, y: 15),
                                 control: CGPoint(x: 10, y: 5), head: .filled))
        #expect(m.id == a.id)
    }

    @Test func rotateTowardPointer() {
        let a = rect(CGRect(x: 0, y: 0, width: 100, height: 100))
        // Pointer straight above the center: no rotation. To the right: 90°.
        #expect(abs(AnnotationGeometry.rotated(a, toward: CGPoint(x: 50, y: -100), snap: false).rotation) < 1e-9)
        #expect(abs(AnnotationGeometry.rotated(a, toward: CGPoint(x: 200, y: 50), snap: false).rotation - .pi / 2) < 1e-9)
        let snapped = AnnotationGeometry.rotated(a, toward: CGPoint(x: 200, y: 20), snap: true)
        #expect(abs(snapped.rotation / (.pi / 12) - (snapped.rotation / (.pi / 12)).rounded()) < 1e-9)
    }

    @Test func nextCounterNumber() {
        #expect(AnnotationGeometry.nextCounterNumber(in: [counter(1), counter(2), counter(5)], start: 1) == 6)
        #expect(AnnotationGeometry.nextCounterNumber(in: [], start: 3) == 3)
        #expect(AnnotationGeometry.nextCounterNumber(in: [counter(1)], start: 10) == 10)
    }

    @Test func canvasMappingRoundTrip() {
        var style = Style.default
        style.padding = 64
        style.aspect = .auto
        let layout = CanvasLayout.compute(contentSize: CGSize(width: 1000, height: 500), style: style)
        let view = CGPoint(x: 32 + 50, y: 32 + 25)

        let plain = CanvasMapping(layout: layout, crop: nil, viewScale: 0.5)
        #expect(plain.toOriginal(view) == CGPoint(x: 100, y: 50))

        let cropped = CanvasMapping(layout: layout, crop: CGRect(x: 200, y: 100, width: 600, height: 300),
                                    viewScale: 0.5)
        #expect(cropped.toOriginal(view) == CGPoint(x: 300, y: 150))

        let back = cropped.toView(cropped.toOriginal(view))
        #expect(abs(back.x - view.x) < 1e-9 && abs(back.y - view.y) < 1e-9)
    }
}
