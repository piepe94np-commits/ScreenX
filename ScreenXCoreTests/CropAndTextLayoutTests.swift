import CoreGraphics
import Foundation
import Testing
@testable import ScreenXCore

struct CropGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test func resizeMovesOnlyTheDraggedSides() {
        let r = CGRect(x: 100, y: 100, width: 100, height: 50)
        #expect(CropGeometry.resized(r, handle: .bottomRight, to: CGPoint(x: 250, y: 200), keepAspect: false,
                                     in: bounds) == CGRect(x: 100, y: 100, width: 150, height: 100))
        #expect(CropGeometry.resized(r, handle: .left, to: CGPoint(x: 50, y: 0), keepAspect: false,
                                     in: bounds) == CGRect(x: 50, y: 100, width: 150, height: 50))
    }

    @Test func resizeStopsAtMinimumSizeAndBounds() {
        let r = CGRect(x: 100, y: 100, width: 100, height: 50)
        // Dragged past the opposite corner: stays 16 × 16 at the fixed corner.
        #expect(CropGeometry.resized(r, handle: .topLeft, to: CGPoint(x: 300, y: 300), keepAspect: false,
                                     in: bounds) == CGRect(x: 184, y: 134, width: 16, height: 16))
        // Dragged outside the original: clamped to it.
        #expect(CropGeometry.resized(r, handle: .topRight, to: CGPoint(x: 900, y: -50), keepAspect: false,
                                     in: bounds) == CGRect(x: 100, y: 0, width: 300, height: 150))
    }

    @Test func resizeKeepsAspectRatio() {
        let r = CGRect(x: 100, y: 100, width: 100, height: 50)
        let corner = CropGeometry.resized(r, handle: .bottomRight, to: CGPoint(x: 300, y: 160), keepAspect: true,
                                          in: bounds)
        #expect(corner == CGRect(x: 100, y: 100, width: 200, height: 100))
        // Edge handle: grows around the center of the other axis.
        let edge = CropGeometry.resized(r, handle: .right, to: CGPoint(x: 260, y: 0), keepAspect: true, in: bounds)
        #expect(edge == CGRect(x: 100, y: 85, width: 160, height: 80))
        // Limited by the original: scaled down so it still fits, ratio unchanged.
        let limited = CropGeometry.resized(r, handle: .bottomRight, to: CGPoint(x: 900, y: 900),
                                           keepAspect: true, in: bounds)
        #expect(limited == CGRect(x: 100, y: 100, width: 300, height: 150))
        // Shrunk below the minimum: the shorter side is 16.
        let small = CropGeometry.resized(r, handle: .bottomRight, to: CGPoint(x: 101, y: 101), keepAspect: true,
                                         in: bounds)
        #expect(small == CGRect(x: 100, y: 100, width: 32, height: 16))
    }

    @Test func moveStaysInsideOriginal() {
        let r = CGRect(x: 100, y: 100, width: 100, height: 50)
        #expect(CropGeometry.moved(r, by: CGVector(dx: 20, dy: -10), in: bounds)
                == CGRect(x: 120, y: 90, width: 100, height: 50))
        #expect(CropGeometry.moved(r, by: CGVector(dx: 500, dy: -500), in: bounds)
                == CGRect(x: 300, y: 0, width: 100, height: 50))
    }

    @Test func newRectNeedsMinimumSize() {
        #expect(CropGeometry.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 20, y: 80), square: false,
                                  in: bounds) == nil)
        #expect(CropGeometry.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 500), square: false,
                                  in: bounds) == CGRect(x: 10, y: 50, width: 40, height: 250))
        #expect(CropGeometry.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 90, y: 60), square: true,
                                  in: bounds) == CGRect(x: 50, y: 50, width: 40, height: 40))
    }

    @Test func committedRoundsAndDropsFullOriginal() {
        #expect(CropGeometry.committed(CGRect(x: 10.4, y: 20.6, width: 100.2, height: 50), bounds: bounds)
                == CGRect(x: 10, y: 21, width: 101, height: 50))
        #expect(CropGeometry.committed(bounds, bounds: bounds) == nil)
        #expect(CropGeometry.committed(CGRect(x: -0.2, y: 0, width: 400.1, height: 300), bounds: bounds) == nil)
    }

    @Test func initialRectFallsBackToWholeOriginal() {
        #expect(CropGeometry.initialRect(crop: nil, bounds: bounds) == bounds)
        #expect(CropGeometry.initialRect(crop: CGRect(x: 10, y: 10, width: 50, height: 60), bounds: bounds)
                == CGRect(x: 10, y: 10, width: 50, height: 60))
        #expect(CropGeometry.initialRect(crop: CGRect(x: 1000, y: 0, width: 50, height: 60), bounds: bounds)
                == bounds)
    }
}

struct AnnotationTextLayoutTests {
    private func text(_ string: String, width: CGFloat = 300, height: CGFloat = 10) -> Annotation {
        Annotation(kind: .text(frame: CGRect(x: 0, y: 0, width: width, height: height), string: string,
                               fontSize: 20, bold: false, background: nil))
    }

    @Test func emptyTextNeedsOneLine() throws {
        let empty = try #require(AnnotationTextLayout.requiredFrameHeight(of: text(""), originalScale: 1))
        let one = try #require(AnnotationTextLayout.requiredFrameHeight(of: text("Hallo"), originalScale: 1))
        #expect(empty > 20)
        #expect(empty == one)
    }

    @Test func heightGrowsWithLines() throws {
        let one = try #require(AnnotationTextLayout.requiredFrameHeight(of: text("A"), originalScale: 1))
        let two = try #require(AnnotationTextLayout.requiredFrameHeight(of: text("A\nB"), originalScale: 1))
        // A trailing line break already starts the next line (the caret sits there).
        let started = try #require(AnnotationTextLayout.requiredFrameHeight(of: text("A\n"), originalScale: 1))
        #expect(two > one * 1.6)
        #expect(started == two)
        // Wrapping at a narrow width needs more lines.
        let long = String(repeating: "Wort ", count: 20)
        let wide = try #require(AnnotationTextLayout.requiredFrameHeight(of: text(long, width: 2000), originalScale: 1))
        let narrow = try #require(AnnotationTextLayout.requiredFrameHeight(of: text(long, width: 100), originalScale: 1))
        #expect(narrow > wide * 3)
    }

    @Test func noteAddsPaddingAndScalesWithCapture() throws {
        let note = Annotation(kind: .note(frame: CGRect(x: 0, y: 0, width: 232, height: 50), string: "Notiz",
                                          noteColor: AnnotationPalette.noteColors[0]))
        let height = try #require(AnnotationTextLayout.requiredFrameHeight(of: note, originalScale: 1))
        let inner = AnnotationTextLayout.textHeight("Notiz", fontSize: 15, bold: false, width: 200)
        #expect(height == inner + 32)
        let retina = try #require(AnnotationTextLayout.requiredFrameHeight(of: note, originalScale: 2))
        #expect(retina > height)
        #expect(AnnotationTextLayout.textStyle(of: note, originalScale: 2)?.fontSize == 30)
        #expect(AnnotationTextLayout.textRect(of: note) == CGRect(x: 16, y: 16, width: 200, height: 18))
    }

    @Test func otherKindsHaveNoTextLayout() {
        let shape = Annotation(kind: .highlight(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(AnnotationTextLayout.requiredFrameHeight(of: shape, originalScale: 1) == nil)
        #expect(AnnotationTextLayout.textStyle(of: shape, originalScale: 1) == nil)
    }
}
