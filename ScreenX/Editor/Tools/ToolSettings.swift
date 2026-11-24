import CoreGraphics
import Foundation
import Observation
import ScreenXCore

/// Die Optionen der Werkzeuge, gemeinsam für alle Editor-Fenster.
/// Farbe und Strichstärke gelten für alle Werkzeuge (zuletzt genutzt).
/// Jede Änderung wird als `Codable`-Abbild unter „toolSettings.v1“ in `UserDefaults` gesichert.
@MainActor
@Observable
final class ToolSettings {
    static let shared = ToolSettings()
    static let defaultsKey = "toolSettings.v1"

    var color: ColorValue { didSet { save() } }
    var strokeWidth: Double { didSet { save() } }
    var arrowCurved: Bool { didSet { save() } }
    var arrowHead: ArrowHead { didSet { save() } }
    var shapeKind: ShapeKind { didSet { save() } }
    var shapeFilled: Bool { didSet { save() } }
    var fontSize: Double { didSet { save() } }
    var textBold: Bool { didSet { save() } }
    var textBackground: ColorValue? { didSet { save() } }
    var noteColor: ColorValue { didSet { save() } }
    var counterStart: Int { didSet { save() } }
    var blurMode: BlurMode { didSet { save() } }
    var blurStrength: Double { didSet { save() } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        color = loaded.color
        strokeWidth = loaded.strokeWidth
        arrowCurved = loaded.arrowCurved
        arrowHead = loaded.arrowHead
        shapeKind = loaded.shapeKind
        shapeFilled = loaded.shapeFilled
        fontSize = loaded.fontSize
        textBold = loaded.textBold
        textBackground = loaded.textBackground
        noteColor = loaded.noteColor
        counterStart = loaded.counterStart
        blurMode = loaded.blurMode
        blurStrength = loaded.blurStrength
    }

    private var stored: Stored {
        Stored(color: color, strokeWidth: strokeWidth, arrowCurved: arrowCurved, arrowHead: arrowHead,
               shapeKind: shapeKind, shapeFilled: shapeFilled, fontSize: fontSize, textBold: textBold,
               textBackground: textBackground, noteColor: noteColor, counterStart: counterStart,
               blurMode: blurMode, blurStrength: blurStrength)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Kontrollpunkt für einen neu gebogenen Pfeil: seitlich der Mitte, um 20 % der Länge versetzt.
    nonisolated static func curvedControl(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        return CGPoint(x: (start.x + end.x) / 2 - dy * 0.2, y: (start.y + end.y) / 2 + dx * 0.2)
    }

    /// Codable-Abbild. Fehlende Felder (ältere oder beschädigte Daten) erhalten ihren Standardwert.
    private struct Stored: Codable {
        var color = AnnotationPalette.defaultColor
        var strokeWidth = AnnotationPalette.defaultStrokeWidth
        var arrowCurved = false
        var arrowHead = ArrowHead.filled
        var shapeKind = ShapeKind.rectangle
        var shapeFilled = false
        var fontSize: Double = 32
        var textBold = false
        var textBackground: ColorValue?
        var noteColor = AnnotationPalette.noteColors[0]
        var counterStart = 1
        var blurMode = BlurMode.blur
        var blurStrength: Double = 12

        init() {}

        init(color: ColorValue, strokeWidth: Double, arrowCurved: Bool, arrowHead: ArrowHead,
             shapeKind: ShapeKind, shapeFilled: Bool, fontSize: Double, textBold: Bool,
             textBackground: ColorValue?, noteColor: ColorValue, counterStart: Int,
             blurMode: BlurMode, blurStrength: Double) {
            self.color = color
            self.strokeWidth = strokeWidth
            self.arrowCurved = arrowCurved
            self.arrowHead = arrowHead
            self.shapeKind = shapeKind
            self.shapeFilled = shapeFilled
            self.fontSize = fontSize
            self.textBold = textBold
            self.textBackground = textBackground
            self.noteColor = noteColor
            self.counterStart = counterStart
            self.blurMode = blurMode
            self.blurStrength = blurStrength
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Stored()
            color = (try? c.decode(ColorValue.self, forKey: .color)) ?? d.color
            strokeWidth = (try? c.decode(Double.self, forKey: .strokeWidth)) ?? d.strokeWidth
            arrowCurved = (try? c.decode(Bool.self, forKey: .arrowCurved)) ?? d.arrowCurved
            arrowHead = (try? c.decode(ArrowHead.self, forKey: .arrowHead)) ?? d.arrowHead
            shapeKind = (try? c.decode(ShapeKind.self, forKey: .shapeKind)) ?? d.shapeKind
            shapeFilled = (try? c.decode(Bool.self, forKey: .shapeFilled)) ?? d.shapeFilled
            fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? d.fontSize
            textBold = (try? c.decode(Bool.self, forKey: .textBold)) ?? d.textBold
            textBackground = try? c.decodeIfPresent(ColorValue.self, forKey: .textBackground)
            noteColor = (try? c.decode(ColorValue.self, forKey: .noteColor)) ?? d.noteColor
            counterStart = (try? c.decode(Int.self, forKey: .counterStart)) ?? d.counterStart
            blurMode = (try? c.decode(BlurMode.self, forKey: .blurMode)) ?? d.blurMode
            blurStrength = (try? c.decode(Double.self, forKey: .blurStrength)) ?? d.blurStrength
        }
    }
}
