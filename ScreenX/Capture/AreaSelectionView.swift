import AppKit
import ScreenXCore

/// Bereichsauswahl auf einem Bildschirm: 40 % Abdunklung über dem Standbild, Auswahl ausgespart
/// mit 1 pt weißem Rand und Pixelgrößen-Label, dazu die Lupe am Zeiger.
final class AreaSelectionView: OverlayInputView {
    private static let dimming = NSColor.black.withAlphaComponent(0.4)
    private static let magnifierOffset: CGFloat = 20
    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    /// Auswahl als Pixelrechteck im Bild dieses Monitors (oben links); `nil` = keine.
    private var selection: CGRect?
    private var dirtyArea: CGRect = .null
    private let magnifier: MagnifierView

    init(display: DisplayInfo, image: CGImage?) {
        magnifier = MagnifierView(image: image)
        super.init(display: display, cursor: .crosshair)
        magnifier.isHidden = true
        addSubview(magnifier)
    }

    /// `pointer` in AppKit-Global-Koordinaten.
    func update(selection newSelection: CGRect?, pointer: CGPoint) {
        let visible = newSelection.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
        if visible != selection {
            selection = visible
            let area = visible.map(selectionArea) ?? .null
            let invalid = dirtyArea.union(area)
            if !invalid.isNull { setNeedsDisplay(invalid) }
            dirtyArea = area
        }
        updateMagnifier(pointer)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        let hole = selection.map(localRect(forPixels:))
        if let hole {
            dim.append(NSBezierPath(rect: hole))
            dim.windingRule = .evenOdd
        }
        Self.dimming.setFill()
        dim.fill()

        guard let hole, let selection else { return }
        // Rand außerhalb der Auswahl, damit er keine aufgenommenen Pixel verdeckt.
        let border = NSBezierPath(rect: hole.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()

        let text = sizeText(selection)
        let frame = labelFrame(for: hole, text: text)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: frame.minX + 6, y: frame.minY + 3), withAttributes: Self.labelAttributes)
    }

    // MARK: - Hilfen

    private func sizeText(_ selection: CGRect) -> NSString {
        "\(Int(selection.width)) × \(Int(selection.height))" as NSString
    }

    /// Label rechtsbündig unter der Auswahl, innerhalb des Bildschirms gehalten.
    private func labelFrame(for hole: CGRect, text: NSString) -> CGRect {
        let size = text.size(withAttributes: Self.labelAttributes)
        let width = ceil(size.width) + 12
        let height = ceil(size.height) + 6
        let margin: CGFloat = 4
        var x = hole.maxX - width
        var y = hole.minY - height - 6
        x = min(max(x, margin), bounds.maxX - width - margin)
        y = min(max(y, margin), bounds.maxY - height - margin)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Bereich, der beim Ändern der Auswahl neu gezeichnet werden muss (Loch, Rand, Label).
    private func selectionArea(_ selection: CGRect) -> CGRect {
        let hole = localRect(forPixels: selection)
        return hole.union(labelFrame(for: hole, text: sizeText(selection))).insetBy(dx: -4, dy: -4)
    }

    private func updateMagnifier(_ pointer: CGPoint) {
        let frame = display.frame
        guard frame.contains(pointer) else {
            magnifier.isHidden = true
            return
        }
        let local = CGPoint(x: pointer.x - frame.minX, y: pointer.y - frame.minY)
        let maxX = frame.width * display.scale - 1
        let maxY = frame.height * display.scale - 1
        let pixel = CGPoint(
            x: min(max(floor(local.x * display.scale), 0), maxX),
            y: min(max(floor((frame.height - local.y) * display.scale), 0), maxY)
        )
        magnifier.show(pixel: pixel)

        // Rechts unterhalb des Zeigers; an Bildschirmrändern auf die andere Seite klappen.
        let size = magnifier.frame.size
        let offset = Self.magnifierOffset
        var origin = CGPoint(x: local.x + offset, y: local.y - offset - size.height)
        if origin.x + size.width > bounds.maxX { origin.x = local.x - offset - size.width }
        if origin.y < bounds.minY { origin.y = local.y + offset }
        magnifier.setFrameOrigin(origin)
        magnifier.isHidden = false
    }
}

/// Laufende Bereichsauswahl in AppKit-Global-Koordinaten, immer auf das Start-Display begrenzt.
struct AreaDrag {
    let display: DisplayInfo
    var anchor: CGPoint
    var last: CGPoint
    var square = false
    var moving = false
    var rect = CGRect.null

    init(display: DisplayInfo, anchor: CGPoint, last: CGPoint) {
        self.display = display
        self.anchor = anchor
        self.last = last
    }

    mutating func drag(to point: CGPoint, shift: Bool) {
        if moving {
            // Ganze Auswahl verschieben, ohne das Display zu verlassen.
            var dx = point.x - last.x
            var dy = point.y - last.y
            if !rect.isNull {
                let bounds = display.frame
                dx = min(max(dx, bounds.minX - rect.minX), bounds.maxX - rect.maxX)
                dy = min(max(dy, bounds.minY - rect.minY), bounds.maxY - rect.maxY)
                rect = rect.offsetBy(dx: dx, dy: dy)
            }
            anchor.x += dx
            anchor.y += dy
            last = point
        } else {
            square = shift
            last = point
            resize()
        }
    }

    mutating func setSquare(_ on: Bool) {
        square = on
        if !moving { resize() }
    }

    mutating func setMoving(_ on: Bool) {
        if on, !moving, !rect.isNull {
            // Anker auf die dem Zeiger gegenüberliegende Ecke legen, damit das Aufziehen danach nahtlos weitergeht.
            anchor = CGPoint(
                x: last.x >= anchor.x ? rect.minX : rect.maxX,
                y: last.y >= anchor.y ? rect.minY : rect.maxY
            )
        }
        moving = on
        if !on { resize() }
    }

    mutating func resize() {
        let raw = SelectionGeometry.rect(from: anchor, to: last, square: square)
        rect = SelectionGeometry.clamp(raw, to: display.frame)
    }
}
