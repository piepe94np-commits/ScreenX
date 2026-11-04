import CoreGraphics
import Foundation
import Testing
@testable import ScreenXCore

struct TemplateModelTests {
    @Test func catalogHas14UniqueIDs() {
        let ids = TemplateCatalog.builtins.map(\.id)
        #expect(ids.count == 14)
        #expect(Set(ids).count == 14)
        let expected: Set = [
            "laptop-silver", "laptop-black", "monitor-silver", "monitor-black",
            "phone-portrait-light", "phone-portrait-dark", "phone-landscape-light", "phone-landscape-dark",
            "tablet-portrait-light", "tablet-portrait-dark", "tablet-landscape-light", "tablet-landscape-dark",
            "browser-light", "browser-dark",
        ]
        #expect(Set(ids) == expected)
        for template in TemplateCatalog.builtins {
            #expect(template.frame == .builtin(template.id))
            #expect(TemplateCatalog.builtin(id: template.id) == template)
        }
        #expect(TemplateCatalog.builtin(id: "nope") == nil)
        #expect(TemplateCatalog.builtin(id: "phone-portrait-dark")?.name == "Smartphone hoch, dunkel")
    }

    @Test func quadsInsideFrame() {
        for template in TemplateCatalog.builtins {
            #expect(template.screenQuad.count == 4)
            for p in template.screenQuad {
                #expect(p.x >= 0 && p.x <= template.frameSize.width, "\(template.id)")
                #expect(p.y >= 0 && p.y <= template.frameSize.height, "\(template.id)")
            }
        }
    }

    @Test func landscapeIsRotatedPortrait() throws {
        let portrait = try #require(TemplateCatalog.builtin(id: "tablet-portrait-dark"))
        let landscape = try #require(TemplateCatalog.builtin(id: "tablet-landscape-dark"))
        #expect(landscape.frameSize == CGSize(width: 2440, height: 1800))
        #expect(landscape.screenBounds == CGRect(x: 2440 - 90 - 2160, y: 90, width: 2160, height: 1620))
        #expect(landscape.screenQuad[0] == CGPoint(x: 190, y: 90))
        #expect(landscape.screenQuad[2] == CGPoint(x: 2350, y: 1710))
        #expect(landscape.preferredAspect == [4, 3])
        #expect(portrait.preferredAspect == [3, 4])
        #expect(TemplateCatalog.builtin(id: "phone-landscape-light")?.preferredAspect == [2556, 1179])
    }

    @Test func builtinsAreRectangular() {
        for template in TemplateCatalog.builtins {
            #expect(template.isRectangular, "\(template.id)")
        }
        var skewed = TemplateCatalog.builtins[0]
        skewed.screenQuad[1].y += 20
        #expect(!skewed.isRectangular)
        var nearly = TemplateCatalog.builtins[0]
        nearly.screenQuad[1].y += 0.4
        #expect(nearly.isRectangular)
    }

    @Test func templateJSONShape() throws {
        let template = try #require(TemplateCatalog.builtin(id: "phone-portrait-dark"))
        let data = try JSONEncoder().encode(template)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["id"] as? String == "phone-portrait-dark")
        let frame = try #require(root["frame"] as? [String: Any])
        #expect(frame.count == 1)
        #expect(frame["builtin"] as? String == "phone-portrait-dark")
        let quad = try #require(root["screenQuad"] as? [[Double]])
        #expect(quad == [[60, 60], [1240, 60], [1240, 2600], [60, 2600]])
        #expect(root["screenCornerRadius"] as? Double == 150)
        #expect(root["preferredAspect"] as? [Int] == [1179, 2556])
        #expect(try JSONDecoder().decode(DeviceTemplate.self, from: data) == template)

        // Spec §7 example (custom frame file, no frameSize).
        let spec = """
        {
          "id": "phone-portrait-dark",
          "name": "Smartphone hoch, dunkel",
          "frame": { "file": "phone-portrait-dark.pdf" },
          "screenQuad": [[60, 52], [1239, 52], [1239, 2608], [60, 2608]],
          "screenCornerRadius": 55,
          "preferredAspect": [1179, 2556]
        }
        """
        let decoded = try JSONDecoder().decode(DeviceTemplate.self, from: Data(spec.utf8))
        #expect(decoded.frame == .file("phone-portrait-dark.pdf"))
        #expect(decoded.screenQuad == [CGPoint(x: 60, y: 52), CGPoint(x: 1239, y: 52),
                                       CGPoint(x: 1239, y: 2608), CGPoint(x: 60, y: 2608)])
        #expect(decoded.screenCornerRadius == 55)
        #expect(decoded.isRectangular)

        let badQuad = Data(#"{"id":"x","name":"x","frame":{"file":"a.png"},"screenQuad":[[0,0],[1,0]]}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DeviceTemplate.self, from: badQuad) }
    }

    @Test func decodesPreM4Documents() throws {
        let json = """
        {
          "version": 1,
          "original": { "file": "original.png", "pixelWidth": 3024, "pixelHeight": 1964, "scale": 2 },
          "crop": null,
          "style": {
            "background": { "type": "gradient", "stops": [{"color": "#FF9A6B", "location": 0}, {"color": "#7B5CFF", "location": 1}], "angle": 135 },
            "padding": 64, "cornerRadius": 12,
            "shadow": { "strength": 50, "offsetY": null, "blur": null, "opacity": null },
            "keepWindowShadow": false,
            "aspect": "auto", "alignment": "center"
          },
          "template": null,
          "annotations": []
        }
        """
        let model = try JSONDecoder().decode(DocumentModel.self, from: Data(json.utf8))
        #expect(model.style.tilt == .zero)
        #expect(model.template == nil)
        #expect(model.style.padding == 64)
        #expect(model.original.pixelWidth == 3024)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let out = String(decoding: try encoder.encode(model), as: UTF8.self)
        #expect(out.contains("\"template\":null"))
        #expect(out.contains("\"tilt\":{\"x\":0,\"y\":0}"))
    }

    @Test func placementRoundTrip() throws {
        let placement = TemplatePlacement(templateID: "browser-dark", fit: .fit,
                                          fillColor: try #require(ColorValue(hex: "#112233")),
                                          offset: CGPoint(x: -0.5, y: 0.25), urlText: "example.com/docs")
        let data = try JSONEncoder().encode(placement)
        #expect(try JSONDecoder().decode(TemplatePlacement.self, from: data) == placement)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["fit"] as? String == "fit")
        #expect(root["fillColor"] as? String == "#112233")
        let offset = try #require(root["offset"] as? [String: Any])
        #expect(offset["x"] as? Double == -0.5)

        let defaults = TemplatePlacement(templateID: "phone-portrait-dark")
        #expect(defaults.fillColor.hex == "#000000")
        let minimal = Data(#"{"templateID":"phone-portrait-dark"}"#.utf8)
        #expect(try JSONDecoder().decode(TemplatePlacement.self, from: minimal) == defaults)

        var style = Style.default
        style.tilt = Tilt(x: 12, y: -8)
        let model = DocumentModel(original: OriginalInfo(pixelWidth: 10, pixelHeight: 10, scale: 1),
                                  style: style, template: placement)
        let decoded = try JSONDecoder().decode(DocumentModel.self, from: JSONEncoder().encode(model))
        #expect(decoded == model)
        #expect(decoded.template == placement)
        #expect(decoded.style.tilt == Tilt(x: 12, y: -8))
    }
}
