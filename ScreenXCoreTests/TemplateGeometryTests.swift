import CoreGraphics
import Foundation
import Testing
@testable import ScreenXCore

struct TemplateGeometryTests {
    private let content = CGSize(width: 1600, height: 900)
    private let phoneScreen = CGSize(width: 1180, height: 2540)

    private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.1) -> Bool { abs(a - b) <= tolerance }

    @Test func fillCropsCenteredAndClampsOffset() {
        let centered = TemplateGeometry.sourceRect(contentSize: content, screenSize: phoneScreen, fit: .fill, offset: .zero)
        #expect(close(centered.source.width, 900 * 1180 / 2540))
        #expect(close(centered.source.width, 418.1))
        #expect(centered.source.height == 900)
        #expect(centered.source.minY == 0)
        #expect(close(centered.source.minX, 590.9))
        #expect(close(centered.source.midX, 800, 0.001))
        #expect(centered.dest == CGRect(origin: .zero, size: phoneScreen))

        let right = TemplateGeometry.sourceRect(contentSize: content, screenSize: phoneScreen, fit: .fill,
                                                offset: CGPoint(x: 1, y: 0))
        #expect(close(right.source.maxX, 1600, 0.001))
        let clamped = TemplateGeometry.sourceRect(contentSize: content, screenSize: phoneScreen, fit: .fill,
                                                  offset: CGPoint(x: 5, y: 0))
        #expect(clamped.source == right.source)
        let left = TemplateGeometry.sourceRect(contentSize: content, screenSize: phoneScreen, fit: .fill,
                                               offset: CGPoint(x: -5, y: 3))
        #expect(left.source.minX == 0)
        #expect(left.source.minY == 0) // no free range vertically
    }

    @Test func fitLetterboxes() {
        let r = TemplateGeometry.sourceRect(contentSize: content, screenSize: phoneScreen, fit: .fit,
                                            offset: CGPoint(x: 1, y: 1))
        #expect(r.source == CGRect(origin: .zero, size: content))
        #expect(close(r.dest.width, 1180, 0.001))
        #expect(close(r.dest.height, 663.75, 0.001))
        #expect(close(r.dest.minX, 0, 0.001))
        #expect(close(r.dest.minY, 938.1))
    }

    @Test func frameScaleMatchesWidth() throws {
        let phone = try #require(TemplateCatalog.builtin(id: "phone-portrait-dark"))
        #expect(TemplateGeometry.frameScale(template: phone, contentSize: CGSize(width: 2360, height: 5000)) == 2)
        #expect(TemplateGeometry.frameScale(template: phone, contentSize: CGSize(width: 10, height: 10)) == 0.25)
        #expect(TemplateGeometry.frameScale(template: phone, contentSize: CGSize(width: 99_999, height: 10)) == 4)
    }

    @Test func aspectMismatchThreshold() throws {
        let same = try #require(TemplateGeometry.aspectMismatch(contentSize: content, preferred: [16, 9]))
        #expect(abs(same) < 1e-9)
        let phone = try #require(TemplateGeometry.aspectMismatch(contentSize: content, preferred: [1179, 2556]))
        #expect(phone > 0.15)
        #expect(TemplateGeometry.aspectMismatch(contentSize: content, preferred: nil) == nil)
        #expect(TemplateGeometry.recommendedAspectText([1179, 2556]) == "9:19,5")
        #expect(TemplateGeometry.recommendedAspectText([2556, 1179]) == "19,5:9")
        #expect(TemplateGeometry.recommendedAspectText([16, 10]) == "16:10")
        #expect(TemplateGeometry.recommendedAspectText([1920, 1080]) == "16:9")
    }

    @Test func tiltZeroIsIdentityRect() {
        let corners = TemplateGeometry.tiltCorners(size: CGSize(width: 400, height: 300), tilt: .zero)
        let expected = [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0), CGPoint(x: 400, y: 300), CGPoint(x: 0, y: 300)]
        #expect(corners.count == 4)
        for (c, e) in zip(corners, expected) {
            #expect(close(c.x, e.x, 1e-6) && close(c.y, e.y, 1e-6))
        }
    }

    @Test func tiltCornersStayInFrontAndBounded() {
        let size = CGSize(width: 3000, height: 500)
        func crossSigns(_ p: [CGPoint]) -> [Bool] {
            (0..<4).map { i in
                let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
                return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 0
            }
        }
        let flat = crossSigns(TemplateGeometry.tiltCorners(size: size, tilt: .zero))
        for tilt in [Tilt(x: 30, y: 30), Tilt(x: -30, y: 30), Tilt(x: 30, y: -30), Tilt(x: -30, y: -30)] {
            let corners = TemplateGeometry.tiltCorners(size: size, tilt: tilt)
            #expect(corners.count == 4)
            #expect(corners.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 })
            #expect(crossSigns(corners) == flat, "\(tilt)")
            let maxX = corners.map(\.x).max() ?? 0, maxY = corners.map(\.y).max() ?? 0
            #expect(maxX < 3 * size.width && maxY < 3 * size.height)
            #expect(maxX > 0.5 * size.width && maxY > 0.5 * size.height)
        }
        // A tilt actually changes the shape.
        let tilted = TemplateGeometry.tiltCorners(size: size, tilt: Tilt(x: 0, y: 30))
        #expect(!close(tilted[1].y, tilted[0].y, 1))
    }

    @Test func affineMappingOnlyForRectQuadsWithoutTilt() throws {
        let phone = try #require(TemplateCatalog.builtin(id: "phone-portrait-light"))
        #expect(TemplateGeometry.isAffineEditable(template: phone, tilt: .zero))
        #expect(!TemplateGeometry.isAffineEditable(template: phone, tilt: Tilt(x: 5, y: 0)))
        var skewed = phone
        skewed.screenQuad = [CGPoint(x: 80, y: 40), CGPoint(x: 1240, y: 90),
                             CGPoint(x: 1200, y: 2600), CGPoint(x: 60, y: 2560)]
        #expect(!TemplateGeometry.isAffineEditable(template: skewed, tilt: .zero))
        #expect(TemplateGeometry.isAffineEditable(template: nil, tilt: .zero))
        #expect(!TemplateGeometry.isAffineEditable(template: nil, tilt: Tilt(x: 0, y: -3)))

        let placement = TemplatePlacement(templateID: phone.id, fit: .fit)
        #expect(TemplateGeometry.screenToContentTransform(template: skewed, placement: placement,
                                                          contentSize: content, frameScale: 2) == nil)
        let t = try #require(TemplateGeometry.screenToContentTransform(template: phone, placement: placement,
                                                                        contentSize: content, frameScale: 2))
        // Fit: content top-left sits at screen (60, 60) + dest origin (0, 938.125), scaled by 2.
        let topLeft = CGPoint(x: 60 * 2, y: (60 + 938.125) * 2).applying(t)
        #expect(close(topLeft.x, 0, 1e-6) && close(topLeft.y, 0, 1e-6))
        let bottomRight = CGPoint(x: (60 + 1180) * 2, y: (60 + 938.125 + 663.75) * 2).applying(t)
        #expect(close(bottomRight.x, 1600, 1e-6) && close(bottomRight.y, 900, 1e-6))

        let fill = TemplatePlacement(templateID: phone.id, fit: .fill, offset: CGPoint(x: 1, y: 0))
        let tf = try #require(TemplateGeometry.screenToContentTransform(template: phone, placement: fill,
                                                                         contentSize: content, frameScale: 1))
        let screenTopRight = CGPoint(x: 60 + 1180, y: 60).applying(tf)
        #expect(close(screenTopRight.x, 1600, 1e-6) && close(screenTopRight.y, 0, 1e-6))
    }
}
