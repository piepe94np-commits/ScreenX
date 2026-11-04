import CoreGraphics
import Foundation
import Testing
@testable import ScreenXCore

struct AnnotationInteractionGeometryTests {
    private func box(_ r: CGRect, rotation: Double = 0, width: Double = 6) -> Annotation {
        Annotation(kind: .shape(kind: .rectangle, rect: r, filled: false), strokeWidth: width, rotation: rotation)
    }

    private func close(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 1e-6) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
    }

    @Test func localAndOriginalRoundTrip() {
        let a = box(CGRect(x: 0, y: 0, width: 100, height: 50), rotation: .pi / 2)
        // Rotating 90° (clockwise on screen, y down) around (50, 25): the top-left corner lands at (75, -25).
        let topLeft = AnnotationGeometry.toOriginal(.zero, of: a)
        #expect(close(topLeft, CGPoint(x: 75, y: -25)))
        #expect(close(AnnotationGeometry.toLocal(topLeft, of: a), .zero))
    }

    @Test func outlineOfRotatedBox() {
        let a = box(CGRect(x: 0, y: 0, width: 100, height: 50), rotation: .pi / 2)
        let corners = AnnotationGeometry.outline(of: a)
        #expect(corners.count == 4)
        #expect(close(corners[0], CGPoint(x: 75, y: -25)))
        #expect(close(corners[2], CGPoint(x: 25, y: 75)))
        let plain = AnnotationGeometry.outline(of: box(CGRect(x: 10, y: 20, width: 30, height: 40)))
        #expect(plain == [CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 20), CGPoint(x: 40, y: 60), CGPoint(x: 10, y: 60)])
    }

    @Test func marqueeSelectsIntersectingInOrder() {
        let a = box(CGRect(x: 0, y: 0, width: 50, height: 50))
        let b = box(CGRect(x: 200, y: 200, width: 50, height: 50))
        let c = box(CGRect(x: 40, y: 40, width: 20, height: 20))
        let ids = AnnotationGeometry.ids(intersecting: CGRect(x: 45, y: 45, width: -30, height: -30), in: [a, b, c])
        #expect(ids == [a.id, c.id])
        #expect(AnnotationGeometry.ids(intersecting: CGRect(x: 100, y: 100, width: 10, height: 10), in: [a, b, c]).isEmpty)
    }

    @Test func marqueeHitsHorizontalLine() {
        // A horizontal arrow has zero-height bounds; it still counts when the rectangle crosses it.
        let arrow = Annotation(kind: .arrow(start: CGPoint(x: 0, y: 50), end: CGPoint(x: 100, y: 50),
                                            control: nil, head: .filled), strokeWidth: 1)
        #expect(AnnotationGeometry.ids(intersecting: CGRect(x: 40, y: 40, width: 20, height: 20), in: [arrow]) == [arrow.id])
    }

    @Test func marqueeUsesRotatedBounds() {
        // 200×20 rotated 90° around (100, 10): spans y -90…110 at x 90…110.
        let a = box(CGRect(x: 0, y: 0, width: 200, height: 20), rotation: .pi / 2, width: 1)
        #expect(AnnotationGeometry.ids(intersecting: CGRect(x: 95, y: 80, width: 5, height: 5), in: [a]) == [a.id])
        #expect(AnnotationGeometry.ids(intersecting: CGRect(x: 10, y: 5, width: 5, height: 5), in: [a]).isEmpty)
    }

    @Test func resizeUnrotatedMatchesPlainResize() {
        let a = box(CGRect(x: 0, y: 0, width: 100, height: 50))
        let viaOriginal = AnnotationGeometry.resized(a, handle: .bottomRight, toOriginal: CGPoint(x: 150, y: 80),
                                                     constrained: false)
        let plain = AnnotationGeometry.resized(a, handle: .bottomRight, to: CGPoint(x: 150, y: 80), proportional: false)
        #expect(viaOriginal == plain)
        #expect(AnnotationGeometry.bounds(viaOriginal) == CGRect(x: 0, y: 0, width: 150, height: 80))
    }

    @Test func resizeRotatedKeepsOppositeCornerOnScreen() {
        let a = box(CGRect(x: 0, y: 0, width: 100, height: 50), rotation: 0.6)
        let fixedBefore = AnnotationGeometry.outline(of: a)[0] // top-left, opposite of bottom-right
        let target = AnnotationGeometry.toOriginal(CGPoint(x: 160, y: 90), of: a)
        let resized = AnnotationGeometry.resized(a, handle: .bottomRight, toOriginal: target, constrained: false)
        let corners = AnnotationGeometry.outline(of: resized)
        #expect(resized.rotation == a.rotation)
        let size = AnnotationGeometry.bounds(resized).size
        #expect(abs(size.width - 160) < 1e-9 && abs(size.height - 90) < 1e-9)
        #expect(close(corners[0], fixedBefore))
        // The dragged corner follows the pointer.
        #expect(close(corners[2], target))
    }

    @Test func resizeRotatedEdgeKeepsOppositeEdge() {
        let a = box(CGRect(x: 0, y: 0, width: 100, height: 50), rotation: -1.1)
        let leftMidBefore = AnnotationGeometry.toOriginal(CGPoint(x: 0, y: 25), of: a)
        let target = AnnotationGeometry.toOriginal(CGPoint(x: 140, y: 25), of: a)
        let resized = AnnotationGeometry.resized(a, handle: .right, toOriginal: target, constrained: false)
        let r = AnnotationGeometry.bounds(resized)
        #expect(abs(r.width - 140) < 1e-9)
        #expect(close(AnnotationGeometry.toOriginal(CGPoint(x: r.minX, y: r.midY), of: resized), leftMidBefore))
    }

    @Test func constrainedEndpointSnapsToFortyFiveDegrees() {
        let arrow = Annotation(kind: .arrow(start: .zero, end: CGPoint(x: 100, y: 0), control: nil, head: .filled))
        let snapped = AnnotationGeometry.resized(arrow, handle: .end, toOriginal: CGPoint(x: 100, y: 10),
                                                 constrained: true)
        guard case let .arrow(start, end, _, _) = snapped.kind else { Issue.record("not an arrow"); return }
        #expect(start == .zero)
        #expect(abs(end.y) < 1e-9)
        #expect(abs(end.x - hypot(100, 10)) < 1e-9)

        let line = Annotation(kind: .shape(kind: .line, rect: CGRect(x: 0, y: 0, width: 50, height: 0), filled: false))
        let movedStart = AnnotationGeometry.resized(line, handle: .start, toOriginal: CGPoint(x: 2, y: 48),
                                                    constrained: true)
        guard case let .shape(.line, rect, _) = movedStart.kind else { Issue.record("not a line"); return }
        // End stays at (50, 0); the start snaps straight below-left at 135°.
        #expect(close(CGPoint(x: rect.origin.x + rect.size.width, y: rect.origin.y + rect.size.height), CGPoint(x: 50, y: 0)))
        #expect(abs((rect.origin.x - 50) + rect.origin.y) < 1e-9)
    }

    @Test func constrainedBoxKeepsAspectRatio() {
        let a = box(CGRect(x: 0, y: 0, width: 100, height: 50))
        let r = AnnotationGeometry.bounds(
            AnnotationGeometry.resized(a, handle: .bottomRight, toOriginal: CGPoint(x: 200, y: 60), constrained: true))
        #expect(r == CGRect(x: 0, y: 0, width: 200, height: 100))
    }
}
