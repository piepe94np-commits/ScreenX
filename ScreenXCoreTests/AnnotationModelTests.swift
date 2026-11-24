import CoreGraphics
import Foundation
import Testing
@testable import ScreenXCore

struct AnnotationModelTests {
    private let red = ColorValue(hex: "#FF3B30")!
    private let yellow = ColorValue(hex: "#FFE066")!

    private var allKinds: [AnnotationKind] {
        [
            .arrow(start: CGPoint(x: 1, y: 2), end: CGPoint(x: 30, y: 40), control: nil, head: .filled),
            .arrow(start: CGPoint(x: 1, y: 2), end: CGPoint(x: 30, y: 40), control: CGPoint(x: 5, y: 60), head: .double),
            .shape(kind: .roundedRectangle, rect: CGRect(x: 1, y: 2, width: 30, height: 40), filled: true),
            .shape(kind: .line, rect: CGRect(x: 50, y: 50, width: -20, height: -10), filled: false),
            .text(frame: CGRect(x: 0, y: 0, width: 100, height: 30), string: "Hallo ä\nWelt", fontSize: 24,
                  bold: true, background: ColorValue(hex: "#00000080")),
            .text(frame: CGRect(x: 0, y: 0, width: 100, height: 30), string: "x", fontSize: 12,
                  bold: false, background: nil),
            .note(frame: CGRect(x: 5, y: 5, width: 200, height: 120), string: "Notiz", noteColor: yellow),
            .counter(center: CGPoint(x: 9, y: 8), number: 3, radius: 18),
            .blur(rect: CGRect(x: 1, y: 1, width: 50, height: 50), mode: .pixelate, strength: 12),
            .highlight(rect: CGRect(x: 1, y: 1, width: 50, height: 20)),
        ]
    }

    @Test func roundTripAllKinds() throws {
        for kind in allKinds {
            let a = Annotation(kind: kind, color: yellow, strokeWidth: 3.5, rotation: 0.25)
            let data = try JSONEncoder().encode(a)
            #expect(try JSONDecoder().decode(Annotation.self, from: data) == a)
        }
    }

    @Test func jsonTypeDiscriminator() throws {
        let a = Annotation(kind: allKinds[0])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(a), as: UTF8.self)
        #expect(json.contains("\"type\":\"arrow\""))
        #expect(json.contains("\"control\":null"))
        #expect(json.contains("\"start\":{\"x\":1,\"y\":2}"))
    }

    @Test func decodesM2Document() throws {
        let model = DocumentModel(original: OriginalInfo(pixelWidth: 10, pixelHeight: 10, scale: 1),
                                  style: .default)
        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(DocumentModel.self, from: data).annotations == [])

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "annotations")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(DocumentModel.self, from: stripped).annotations == [])
    }

    @Test func documentRoundTripWithAnnotations() throws {
        let model = DocumentModel(original: OriginalInfo(pixelWidth: 10, pixelHeight: 10, scale: 1),
                                  style: .default, annotations: allKinds.map { Annotation(kind: $0) })
        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(DocumentModel.self, from: data) == model)
    }

    @Test func defaults() {
        let a = Annotation(kind: allKinds[0])
        #expect(a.color == red)
        #expect(a.strokeWidth == 6)
        #expect(a.rotation == 0)
    }

    @Test func paletteValues() {
        #expect(AnnotationPalette.colors.count == 8)
        #expect(AnnotationPalette.noteColors.count == 5)
        #expect(AnnotationPalette.defaultColor.hex == "#FF3B30")
        #expect(AnnotationPalette.defaultStrokeWidth == 6)
    }
}
