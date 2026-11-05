import CoreGraphics
import CoreText
import Foundation

// Per-device drawing. All coordinates are frame units of the (portrait) template, origin top-left.
extension DeviceArtwork {
    // MARK: Devices

    /// Rounded lid with a thin bezel and camera dot, hinge, and a flat trapezoid base with a notch.
    static func drawLaptop(_ t: DeviceTemplate, palette p: Palette, in ctx: CGContext) {
        let screen = t.screenBounds
        let lid = CGRect(x: screen.minX - 60, y: screen.minY - 60,
                         width: screen.width + 120, height: screen.height + 128)

        // Base: slab seen slightly from above (wider at the bottom), with a darker foot lip below.
        let top = lid.maxY + 6, bottom = top + 132
        let foot = CGRect(x: 120, y: bottom - 20, width: t.frameSize.width - 240, height: 56)
        fill(roundedRect(foot, top: 0, bottom: 28), color: p.edge.darker(p.isDark ? 0.35 : 0.22).cg(), in: ctx)
        let base = roundedPolygon([CGPoint(x: 60, y: top), CGPoint(x: t.frameSize.width - 60, y: top),
                                   CGPoint(x: t.frameSize.width, y: bottom), CGPoint(x: 0, y: bottom)],
                                  radii: [10, 50, 50, 10])
        fillGradient(base, colors: [p.housing.lighter(p.isDark ? 0.12 : 0.6).cg(), p.housing.cg(),
                                    p.edge.cg(), p.edge.darker(0.12).cg()],
                     from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: bottom), in: ctx)
        // Notch to open the lid, centered on the top edge.
        ctx.saveGState()
        ctx.addPath(base)
        ctx.clip()
        let notch = CGRect(x: t.frameSize.width / 2 - 180, y: top - 30, width: 360, height: 62)
        fillGradient(roundedRect(notch, top: 31, bottom: 31),
                     colors: [p.edge.darker(0.25).cg(), p.edge.darker(0.05).cg()],
                     from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: notch.maxY), in: ctx)
        ctx.restoreGState()
        fill(CGPath(rect: CGRect(x: 60, y: top, width: t.frameSize.width - 120, height: 3), transform: nil),
             color: p.highlight, in: ctx)
        // Hinge between lid and base.
        fill(CGPath(rect: CGRect(x: lid.minX + 70, y: lid.maxY - 4, width: lid.width - 140, height: 12),
                    transform: nil),
             color: p.edge.darker(p.isDark ? 0.4 : 0.3).cg(), in: ctx)

        drawPanel(t, outer: lid, top: 64, bottom: 14, edge: 8, rim: 10, palette: p, in: ctx)
        drawCamera(center: CGPoint(x: lid.midX, y: lid.minY + 30), radius: 9, palette: p, in: ctx)
    }

    /// Thin bezel, neck and foot plate.
    static func drawMonitor(_ t: DeviceTemplate, palette p: Palette, in ctx: CGContext) {
        let screen = t.screenBounds
        let panel = CGRect(x: 0, y: 0, width: t.frameSize.width, height: screen.maxY + 128)
        let mid = t.frameSize.width / 2

        // Neck, shaded like a rounded surface.
        let neckTop = panel.maxY - 80, plateTop = t.frameSize.height - 150
        let neck = roundedPolygon([CGPoint(x: mid - 170, y: neckTop), CGPoint(x: mid + 170, y: neckTop),
                                   CGPoint(x: mid + 215, y: plateTop + 10), CGPoint(x: mid - 215, y: plateTop + 10)],
                                  radii: [1, 1, 1, 1])
        fillGradient(neck, colors: [p.edge.darker(0.12).cg(), p.housing.lighter(p.isDark ? 0.06 : 0.4).cg(),
                                    p.housing.cg(), p.edge.darker(0.18).cg()],
                     from: CGPoint(x: mid - 215, y: 0), to: CGPoint(x: mid + 215, y: 0), in: ctx)
        // Shadow of the panel on the neck.
        fillGradient(neck, colors: [CGColor(gray: 0, alpha: 0.25), CGColor(gray: 0, alpha: 0)],
                     from: CGPoint(x: 0, y: panel.maxY), to: CGPoint(x: 0, y: panel.maxY + 90), in: ctx)

        // Foot plate.
        let plate = CGRect(x: mid - 620, y: plateTop, width: 1240, height: 84)
        fill(roundedRect(plate.offsetBy(dx: 0, dy: 10), top: 30, bottom: 30), color: p.edge.darker(0.25).cg(), in: ctx)
        fillGradient(roundedRect(plate, top: 30, bottom: 30),
                     colors: [p.housing.lighter(p.isDark ? 0.12 : 0.6).cg(), p.housing.cg(), p.edge.cg()],
                     from: CGPoint(x: 0, y: plate.minY), to: CGPoint(x: 0, y: plate.maxY), in: ctx)

        drawPanel(t, outer: panel, top: 36, bottom: 36, edge: 8, rim: 8, palette: p, in: ctx)
    }

    /// Uniform bezel, radius ≈ 170, pill-shaped camera island over the top of the screen, side buttons.
    static func drawPhone(_ t: DeviceTemplate, palette p: Palette, in ctx: CGContext) {
        let body = CGRect(x: 14, y: 14, width: t.frameSize.width - 28, height: t.frameSize.height - 28)
        // Buttons first, so the body overlaps their inner ends.
        let buttonColors = [p.edge.darker(0.2).cg(), p.edge.lighter(p.isDark ? 0.1 : 0.3).cg(), p.edge.cg()]
        for (x, y, height) in [(CGFloat(2), CGFloat(470), CGFloat(110)), (2, 640, 190), (2, 870, 190),
                               (body.maxX - 6, 720, 280)] {
            let button = CGRect(x: x, y: y, width: 18, height: height)
            fillGradient(roundedRect(button, top: 6, bottom: 6), colors: buttonColors,
                         from: CGPoint(x: button.minX, y: 0), to: CGPoint(x: button.maxX, y: 0), in: ctx)
        }
        drawPanel(t, outer: body, top: 176, bottom: 176, edge: 12, rim: 10, palette: p, in: ctx)

        // Camera island: opaque, on top of the screen area.
        let screen = t.screenBounds
        let island = CGRect(x: screen.midX - 180, y: screen.minY + 34, width: 360, height: 104)
        fill(roundedRect(island, top: 52, bottom: 52), color: CGColor(gray: 0, alpha: 1), in: ctx)
        let lens = CGPoint(x: island.maxX - 52, y: island.midY)
        fill(CGPath(ellipseIn: CGRect(x: lens.x - 22, y: lens.y - 22, width: 44, height: 44), transform: nil),
             color: RGB(0x0D0E16).cg(), in: ctx)
        fill(CGPath(ellipseIn: CGRect(x: lens.x - 12, y: lens.y - 12, width: 14, height: 14), transform: nil),
             color: RGB(0x2A2F4A).cg(), in: ctx)
    }

    /// Uniform bezel with a camera dot.
    static func drawTablet(_ t: DeviceTemplate, palette p: Palette, in ctx: CGContext) {
        let body = CGRect(origin: .zero, size: t.frameSize)
        let bezel = t.screenBounds.minX
        drawPanel(t, outer: body, top: t.screenCornerRadius + bezel, bottom: t.screenCornerRadius + bezel,
                  edge: 10, rim: 10, palette: p, in: ctx)
        drawCamera(center: CGPoint(x: body.midX, y: t.screenBounds.minY / 2), radius: 13, palette: p, in: ctx)
    }

    /// Title bar with three neutral grey circles and a rounded URL field.
    static func drawBrowser(_ t: DeviceTemplate, palette p: Palette, urlText: String, in ctx: CGContext) {
        let window = CGRect(origin: .zero, size: t.frameSize)
        let barHeight = t.screenBounds.minY
        let outline = p.isDark ? RGB(0x000000) : RGB(0xC6C6CB)
        fill(roundedRect(window, top: 22, bottom: 0), hole: screenPath(t, inset: 0), color: outline.cg(), in: ctx)
        let bar = CGRect(x: 2, y: 2, width: window.width - 4, height: barHeight - 2)
        let barStops = p.isDark
            ? [p.housing.lighter(0.08).cg(), p.housing.cg()]
            : [p.housing.lighter(0.6).cg(), p.housing.darker(0.02).cg()]
        fillGradient(roundedRect(bar, top: 20, bottom: 0), colors: barStops,
                     from: CGPoint(x: 0, y: bar.minY), to: CGPoint(x: 0, y: bar.maxY), in: ctx)
        let separator = p.isDark ? RGB(0x000000) : RGB(0xD1D1D6)
        fill(CGPath(rect: CGRect(x: 0, y: barHeight - 2, width: window.width, height: 2), transform: nil),
             color: separator.cg(), in: ctx)

        let circleFill = p.isDark ? RGB(0x4A4A4E) : RGB(0xC7C7CC)
        let circleRing = p.isDark ? RGB(0x3A3A3D) : RGB(0xB3B3B8)
        for i in 0..<3 {
            let c = CGRect(x: 46 + CGFloat(i) * 40 - 13, y: barHeight / 2 - 13, width: 26, height: 26)
            fill(CGPath(ellipseIn: c, transform: nil), color: circleRing.cg(), in: ctx)
            fill(CGPath(ellipseIn: c.insetBy(dx: 1.5, dy: 1.5), transform: nil), color: circleFill.cg(), in: ctx)
        }

        let field = CGRect(x: window.midX - 460, y: barHeight / 2 - 27, width: 920, height: 54)
        fill(roundedRect(field, top: 14, bottom: 14), color: (p.isDark ? RGB(0x2C2C2F) : RGB(0xE4E4E9)).cg(),
             in: ctx)
        let textColor = p.isDark ? RGB(0xEBEBF5).cg(0.8) : RGB(0x3C3C43).cg(0.85)
        drawCenteredText(urlText, size: 26, color: textColor, center: CGPoint(x: field.midX, y: field.midY),
                         maxWidth: field.width - 60, in: ctx)
    }

    // MARK: Building blocks

    /// A housing face around the screen: outer edge band, face gradient, bevel highlight and the thin
    /// inner screen border. All layers leave the screen area transparent (even-odd hole).
    static func drawPanel(_ t: DeviceTemplate, outer: CGRect, top: CGFloat, bottom: CGFloat, edge: CGFloat,
                          rim: CGFloat, palette p: Palette, in ctx: CGContext) {
        let hole = screenPath(t, inset: 0)
        fill(roundedRect(outer, top: top, bottom: bottom), hole: hole, color: p.edge.cg(), in: ctx)
        let face = roundedRect(outer.insetBy(dx: edge, dy: edge), top: top - edge, bottom: bottom - edge)
        fillGradient(face, hole: hole, colors: p.faceStops,
                     from: CGPoint(x: 0, y: outer.minY), to: CGPoint(x: 0, y: outer.maxY), in: ctx)
        ctx.saveGState()
        ctx.addPath(face)
        ctx.addPath(hole)
        ctx.clip(using: .evenOdd)
        ctx.addPath(face)
        ctx.setStrokeColor(p.highlight)
        ctx.setLineWidth(4)
        ctx.strokePath()
        ctx.restoreGState()
        fill(screenPath(t, inset: rim), hole: hole, color: p.inner.cg(), in: ctx)
    }

    /// A small camera lens.
    static func drawCamera(center: CGPoint, radius: CGFloat, palette p: Palette, in ctx: CGContext) {
        let outer = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        fill(CGPath(ellipseIn: outer, transform: nil), color: (p.isDark ? RGB(0x050506) : RGB(0x1C1C20)).cg(),
             in: ctx)
        let r = radius * 0.45
        fill(CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2),
                    transform: nil),
             color: RGB(0x262B42).cg(), in: ctx)
    }

    /// The screen area of `t` grown by `inset`, with concentric corners.
    static func screenPath(_ t: DeviceTemplate, inset: CGFloat) -> CGPath {
        let rect = t.screenBounds.insetBy(dx: -inset, dy: -inset)
        let radius = CGFloat(t.screenCornerRadius) + (t.screenCornerRadius > 0 ? inset : 0)
        return roundedRect(rect, top: radius, bottom: radius)
    }

    /// One line in the system font, centered on `center`, truncated at the end to `maxWidth`.
    static func drawCenteredText(_ string: String, size: CGFloat, color: CGColor, center: CGPoint,
                                 maxWidth: CGFloat, in ctx: CGContext) {
        guard !string.isEmpty else { return }
        let font = AnnotationTextLayout.systemFont(size: size, bold: false)
        var line = CTLineCreateWithAttributedString(AnnotationTextLayout.attributed(string, font: font, color: color))
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth) {
            let token = CTLineCreateWithAttributedString(AnnotationTextLayout.attributed("…", font: font, color: color))
            if let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) { line = truncated }
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        ctx.saveGState()
        // Core Text draws y-up: flip locally around the center.
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -width / 2, y: -(ascent - descent) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Paths and fills

    /// Rectangle with separate radii for the top and bottom corners (clamped to fit).
    static func roundedRect(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
        let limit = min(r.width, r.height) / 2
        let t = max(0, min(top, limit)), b = max(0, min(bottom, limit))
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: t)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: b)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: b)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: t)
        p.closeSubpath()
        return p
    }

    /// Closed polygon with a rounding radius per corner.
    static func roundedPolygon(_ points: [CGPoint], radii: [CGFloat]) -> CGPath {
        let p = CGMutablePath()
        guard points.count >= 3, radii.count == points.count, let first = points.first, let last = points.last
        else { return p }
        p.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        for i in points.indices {
            p.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % points.count], radius: radii[i])
        }
        p.closeSubpath()
        return p
    }

    /// Fills `path`, minus `hole` (even-odd) when given.
    static func fill(_ path: CGPath, hole: CGPath? = nil, color: CGColor, in ctx: CGContext) {
        ctx.addPath(path)
        if let hole { ctx.addPath(hole) }
        ctx.setFillColor(color)
        ctx.fillPath(using: hole == nil ? .winding : .evenOdd)
    }

    /// Fills `path`, minus `hole` (even-odd) when given, with a linear gradient of evenly spaced stops.
    static func fillGradient(_ path: CGPath, hole: CGPath? = nil, colors: [CGColor], from start: CGPoint,
                             to end: CGPoint, in ctx: CGContext) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)
        else { return }
        ctx.saveGState()
        ctx.addPath(path)
        if let hole { ctx.addPath(hole) }
        ctx.clip(using: hole == nil ? .winding : .evenOdd)
        ctx.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}
