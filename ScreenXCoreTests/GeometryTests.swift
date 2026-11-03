import CoreGraphics
import Testing
@testable import ScreenXCore

struct GeometryTests {
    @Test func toTopLeftFlipsY() {
        let p = CoordinateSpace.toTopLeft(CGPoint(x: 10, y: 100), primaryHeight: 900)
        #expect(p == CGPoint(x: 10, y: 800))
    }

    @Test func toTopLeftRect() {
        let r = CoordinateSpace.toTopLeft(CGRect(x: 10, y: 100, width: 50, height: 20), primaryHeight: 900)
        #expect(r == CGRect(x: 10, y: 780, width: 50, height: 20))
    }

    @Test func rectFromDragAnyDirection() {
        let r = SelectionGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 50, y: 40), square: false)
        #expect(r == CGRect(x: 50, y: 40, width: 50, height: 60))
    }

    @Test func squareUsesLongerSide() {
        let r = SelectionGeometry.rect(from: .zero, to: CGPoint(x: 30, y: 80), square: true)
        #expect(r == CGRect(x: 0, y: 0, width: 80, height: 80))
    }

    @Test func squareGrowsInNegativeDirection() {
        let r = SelectionGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 70, y: 20), square: true)
        #expect(r == CGRect(x: 20, y: 20, width: 80, height: 80))
    }

    @Test func clampsToStartDisplay() {
        let r = SelectionGeometry.clamp(
            CGRect(x: 900, y: 100, width: 300, height: 200),
            to: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(r == CGRect(x: 900, y: 100, width: 100, height: 200))
    }

    @Test func clampDisjointIsInvalid() {
        let r = SelectionGeometry.clamp(
            CGRect(x: 2000, y: 0, width: 50, height: 50),
            to: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(!SelectionGeometry.isValid(r))
    }

    @Test func tinySelectionIsInvalid() {
        #expect(!SelectionGeometry.isValid(CGRect(x: 0, y: 0, width: 3, height: 10)))
        #expect(SelectionGeometry.isValid(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    @Test func pixelRectRetina() {
        let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
        let r = SelectionGeometry.pixelRect(for: CGRect(x: 100, y: 700, width: 200, height: 100), on: display)
        #expect(r == CGRect(x: 200, y: 200, width: 400, height: 200))
    }

    @Test func pixelRectSecondaryDisplayLeft() {
        let display = DisplayInfo(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1)
        let r = SelectionGeometry.pixelRect(for: CGRect(x: -1820, y: 980, width: 100, height: 50), on: display)
        #expect(r == CGRect(x: 100, y: 50, width: 100, height: 50))
    }

    @Test func pixelRectFractionalRoundsOutward() {
        let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)
        let r = SelectionGeometry.pixelRect(for: CGRect(x: 10.3, y: 20, width: 5.2, height: 10), on: display)
        #expect(r.minX == 10)
        #expect(r.width == 6)
    }

    @Test func pixelRectClippedToDisplayImage() {
        let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        let r = SelectionGeometry.pixelRect(for: CGRect(x: 80, y: -10, width: 50, height: 30), on: display)
        #expect(r == CGRect(x: 160, y: 160, width: 40, height: 40))
    }

    @Test func cropReturnsExactSize() throws {
        let image = TestImages.solid(width: 100, height: 100, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let cropped = try #require(ImageCropper.crop(image, to: CGRect(x: 10, y: 20, width: 30, height: 40)))
        #expect(cropped.width == 30)
        #expect(cropped.height == 40)
    }

    @Test func cropOutsideImageReturnsNil() {
        let image = TestImages.solid(width: 100, height: 100, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(ImageCropper.crop(image, to: CGRect(x: 200, y: 200, width: 10, height: 10)) == nil)
    }
}
