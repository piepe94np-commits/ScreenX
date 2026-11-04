# M3 – Anmerkungen: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Im Editor lassen sich Pfeile, Formen, Linien, Text, Notizzettel, Zähler, Unschärfe/Verpixeln und Marker hinzufügen, auswählen, verschieben, skalieren, drehen und löschen. Dazu kommt ein nicht-destruktiver Zuschnitt. Alle Aktionen lassen sich rückgängig machen.

**Architecture:**
- Anmerkungen sind Werte im `DocumentModel`, gespeichert in Pixelkoordinaten des **Originals**.
- `ScreenXCore` enthält:
  - das Modell
  - die gesamte Geometrie: Hit-Test, Griffe, Einrasten, Abbildung zwischen Ansicht und Original
  - das Zeichnen. Der `Renderer` zeichnet Anmerkungen; Arbeitsfläche und Export sind damit identisch.
- Die App bekommt:
  - einen Werkzeug-Zustand
  - eine Interaktionsschicht (AppKit-`NSView`) über der Vorschau
  - eine kontextabhängige Optionsleiste
- Jede Änderung läuft über `EditorViewModel.apply` bzw. `applyLive`. Undo funktioniert dadurch automatisch.

**Tech Stack:** Swift 6, AppKit + SwiftUI, Core Graphics, Core Text, Core Image, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-03-screenx-design.md`. Für M3 relevant ist §6, dazu §5 (Format, Zuschnitt).

## Global Constraints

- Alle Constraints von M1 und M2 gelten weiter: macOS 26, Swift 6, keine Abhängigkeiten, deutsche Texte im String Catalog, CI-Verifikation, `.superpowers/` nie committen.
- Werkzeuge und Tasten:

  | Werkzeug | Taste |
  |---|---|
  | Auswahl | V |
  | Pfeil | A |
  | Form | R |
  | Text | T |
  | Notiz | N |
  | Zähler | C |
  | Unschärfe | B |
  | Marker | H |
  | Zuschnitt | K |

  Die Linie gehört zum Werkzeug Form.
- Bedienung im Editor:
  - ⌫ löscht, ⌘D dupliziert
  - ⌘] und ⌘[ verschieben die Ebene nach vorne bzw. hinten
  - Esc hebt die Auswahl auf bzw. bricht ein laufendes Werkzeug ab
  - ⇧ lässt Pfeile und Linien in 45°-Schritten einrasten und hält Formen proportional
- Optionen pro Werkzeug:
  - **Pfeil:** gerade oder gebogen (ein Kontrollpunkt); Spitze gefüllt, offen oder beidseitig
  - **Form:** Rechteck, abgerundetes Rechteck, Ellipse oder Linie; Kontur oder gefüllt
  - **Text:** Größe, Farbe, fett, optionale Hintergrund-Box
  - **Notiz:** 5 Farben, mehrzeilig, leichter Schatten
  - **Zähler:** fortlaufend ab einstellbarem Startwert
  - **Unschärfe:** weichzeichnen oder verpixeln, Stärke einstellbar
  - **Marker:** halbtransparent, Mischmodus Multiplizieren
  - **Zuschnitt:** nicht-destruktiv
- Farbpalette mit 8 Farben: `#FF3B30`, `#FF9500`, `#FFCC00`, `#34C759`, `#0A84FF`, `#AF52DE`, `#FFFFFF`, `#1D1D1F`, dazu ein Farbwähler.
  - Standardfarbe `#FF3B30`, Standard-Strichstärke 6 px (Original).
  - Zuletzt genutzte Farbe und Stärke gelten für alle Werkzeuge.
- Notizfarben: `#FFE066` (gelb), `#FFB3C7` (rosa), `#B5EAD7` (grün), `#A0C4FF` (blau), `#FFD6A5` (orange).
- Anmerkungen liegen in Pixelkoordinaten des Originals mit Ursprung oben links. Sie bleiben gültig, wenn sich Abstand, Format oder Zuschnitt ändern. Der Zuschnitt verschiebt nur die sichtbare Fläche.

## Review Focus

1. **Zuschnitt nachträglich verkleinern, sodass Anmerkungen außerhalb liegen:** Sie werden nicht gelöscht. Sie erscheinen wieder, wenn der Zuschnitt vergrößert wird. → Test `annotationsOutsideCropKeptButClipped` (Task 3).
2. **Klick auf eine Stelle, an der mehrere Anmerkungen überlappen:** Die oberste (zuletzt gezeichnete) wird gewählt. → Test `hitTestTopmostWins` (Task 2).
3. **Sehr dünner Pfeil oder dünne Linie:** Sie lassen sich trotzdem treffen, mit einer Toleranz von mindestens 8 Ansichtspunkten unabhängig vom Zoom. → Test `hitTestLineTolerance` (Task 2).
4. **Projekt aus M2 (`annotations: []`, ohne Anmerkungen) öffnen und wieder speichern:** Das funktioniert ohne Fehler. → Test `decodesM2Document` (Task 1).
5. **Zähler löschen und neu setzen:** Die nächste Nummer ist das Maximum plus 1, ausgehend vom Startwert. Es gibt keine doppelten Nummern. → Test `nextCounterNumber` (Task 2).

---

### Task 1: Anmerkungs-Modell

**Files:**
- Create: `ScreenXCore/Annotations/Annotation.swift`, `ScreenXCore/Annotations/AnnotationPalette.swift`
- Modify: `ScreenXCore/Document/DocumentModel.swift`. Das Feld `annotations: [Annotation]` wird mit `decodeIfPresent` gelesen und ist sonst `[]`. Es ersetzt das bisher fest geschriebene leere Array.
- Test: `ScreenXCoreTests/AnnotationModelTests.swift`

**Interfaces:**
- Consumes: `ColorValue` (M2)
- Produces:
  - `public enum ArrowHead: String, Codable, Sendable, CaseIterable { case filled, open, double }`
  - `public enum ShapeKind: String, Codable, Sendable, CaseIterable { case rectangle, roundedRectangle, ellipse, line }`
  - `public enum BlurMode: String, Codable, Sendable, CaseIterable { case blur, pixelate }`
  - `public enum AnnotationKind: Codable, Hashable, Sendable` mit diesen Fällen:
    - `arrow(start: CGPoint, end: CGPoint, control: CGPoint?, head: ArrowHead)`
    - `shape(kind: ShapeKind, rect: CGRect, filled: Bool)`. Bei `.line` sind Start und Ende die gegenüberliegenden Ecken von `rect`, auch bei negativer Breite oder Höhe; `rect` wird dafür nicht standardisiert.
    - `text(frame: CGRect, string: String, fontSize: Double, bold: Bool, background: ColorValue?)`
    - `note(frame: CGRect, string: String, noteColor: ColorValue)`
    - `counter(center: CGPoint, number: Int, radius: Double)`
    - `blur(rect: CGRect, mode: BlurMode, strength: Double)`
    - `highlight(rect: CGRect)`
  - JSON mit `"type"` = `"arrow"`, `"shape"`, `"text"`, `"note"`, `"counter"`, `"blur"`, `"highlight"`
  - `public struct Annotation: Codable, Hashable, Sendable, Identifiable { id: UUID; kind: AnnotationKind; color: ColorValue; strokeWidth: Double; rotation: Double /* Bogenmaß, um das Zentrum der Bounds */ }`
  - `public enum AnnotationPalette { static let colors: [ColorValue]; static let noteColors: [ColorValue]; static let defaultColor: ColorValue; static let defaultStrokeWidth: Double = 6 }`
  - `DocumentModel.annotations: [Annotation]`

- [ ] **Step 1: Failing Tests.**
  - `roundTripAllKinds`: Jeder Fall übersteht Kodieren und Dekodieren unverändert.
  - `jsonTypeDiscriminator`: Ein Pfeil kodiert zu `"type":"arrow"`.
  - `decodesM2Document`: JSON aus M2 mit `"annotations":[]` → leeres Array. JSON ganz ohne das Feld → ebenfalls leeres Array.
  - `paletteValues`: 8 Farben, 5 Notizfarben, Standardfarbe `#FF3B30`.
- [ ] **Step 2: Tests laufen lassen.** Erwartet: FAIL.
- [ ] **Step 3: Implementieren.**
- [ ] **Step 4: Tests laufen lassen.** Erwartet: PASS, alle M2-Paket-Tests weiterhin grün.
- [ ] **Step 5: Commit.** `feat(core): annotation model`

### Task 2: Anmerkungs-Geometrie

**Files:**
- Create: `ScreenXCore/Annotations/AnnotationGeometry.swift`, `ScreenXCore/Annotations/CanvasMapping.swift`
- Test: `ScreenXCoreTests/AnnotationGeometryTests.swift`

**Interfaces:**
- Consumes: `Annotation`, `CanvasLayout`, `Style`
- Produces:
  - `public enum Handle: Hashable, Sendable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end, control, rotate }`
  - `public enum AnnotationGeometry`:
    - `static func bounds(_ a: Annotation, textMeasure: (Annotation) -> CGSize = …) -> CGRect`. Achsenparallele Bounds im Original **ohne** Rotation. Text und Notiz verwenden ihren `frame`.
    - `static func hitTest(_ p: CGPoint, in annotations: [Annotation], tolerance: CGFloat) -> UUID?`
      - Die oberste Anmerkung gewinnt, also die letzte im Array.
      - Linien, Pfeile und gebogene Pfeile: Abstand zur Linie bzw. Kurve ≤ `tolerance + strokeWidth/2`. Bei der Kurve: Abstand zu 32 abgetasteten Punkten.
      - Gefüllte Formen, Text, Notiz, Zähler, Unschärfe und Marker: Treffer im Inneren.
      - Konturformen: Treffer nur auf dem Rand (± Toleranz).
      - Der Punkt wird vorher mit `-rotation` um das Zentrum zurückgedreht.
    - `static func handles(for a: Annotation) -> [Handle: CGPoint]`
      - Pfeile und Linien: `start`, `end`, bei gebogenem Pfeil zusätzlich `control`.
      - Zähler: keine Griffe.
      - Alle anderen: 8 Rahmen-Griffe plus `rotate`, 30 px über der oberen Mitte.
    - `static func moved(_ a: Annotation, by d: CGVector) -> Annotation`
    - `static func resized(_ a: Annotation, handle: Handle, to p: CGPoint, proportional: Bool) -> Annotation`. Der gegenüberliegende Griff bleibt fest.
    - `static func rotated(_ a: Annotation, toward p: CGPoint, snap: Bool) -> Annotation`. Mit `snap` in 15°-Schritten.
    - `static func snapAngle(from s: CGPoint, to e: CGPoint) -> CGPoint`. 45°-Schritte, die Länge bleibt erhalten.
    - `static func constrainedRect(from s: CGPoint, to e: CGPoint, proportional: Bool) -> CGRect`. Proportional heißt: Quadrat mit der längeren Seite, ausgerichtet in Zugrichtung.
    - `static func nextCounterNumber(in annotations: [Annotation], start: Int) -> Int` = max(start, höchste vorhandene Nummer + 1)
  - `public struct CanvasMapping: Sendable`:
    - `init(layout: CanvasLayout, crop: CGRect?, viewScale: CGFloat)`. `viewScale` = Ansichtspunkte pro Pixel des Rahmens.
    - `func toOriginal(_ viewPoint: CGPoint) -> CGPoint`, `func toView(_ originalPoint: CGPoint) -> CGPoint`
    - Ansicht: Ursprung oben links, die Arbeitsfläche liegt bei (0,0).

- [ ] **Step 1: Failing Tests.**
  - `hitTestTopmostWins`: Zwei überlappende gefüllte Rechtecke → die ID des zweiten.
  - `hitTestLineTolerance`: Linie (0,0) → (100,0), Stärke 1, Toleranz 8. Punkt (50,7) trifft, Punkt (50,12) trifft nicht.
  - `hitTestOutlineOnlyBorder`: Konturrechteck (0,0,100,100), Stärke 4, Toleranz 4. Mitte (50,50) trifft nicht, (2,50) trifft.
  - `hitTestRotated`: Gefülltes Rechteck (0,0,100,20), um 90° gedreht. Punkt (50,50) trifft (gedreht liegt er im Inneren), Punkt (90,10) trifft nicht.
  - `snapAngle45`: Von (0,0) nach (100,10) → (≈100,5, 0). Von (0,0) nach (70,72) → x == y.
  - `constrainedSquare`: Von (0,0) nach (30,80), proportional → (0,0,80,80).
  - `resizeKeepsOpposite`: Rechteck (10,10,100,50), Griff `bottomRight` auf (210,110) → (10,10,200,100).
  - `moveArrow`: Pfeil (0,0) → (10,10) mit Kontrollpunkt (5,0), verschoben um (5,5) → alle drei Punkte verschoben.
  - `nextCounterNumber`:
    - Zähler 1, 2, 5 bei Start 1 → 6
    - kein Zähler bei Start 3 → 3
    - Zähler 1 bei Start 10 → 10
  - `canvasMappingRoundTrip`:
    - Layout aus Inhalt 1000×500 und Abstand 64, ohne Zuschnitt, `viewScale` 0,5. Der Ansichtspunkt (32 + 50, 32 + 25) wird zu Original (100, 50).
    - Mit Zuschnitt (200,100,…) wird derselbe Ansichtspunkt zu (300, 150).
    - `toView(toOriginal(p)) ≈ p`.
- [ ] **Step 2: Tests laufen lassen.** Erwartet: FAIL.
- [ ] **Step 3: Implementieren.**
- [ ] **Step 4: Tests laufen lassen.** Erwartet: PASS.
- [ ] **Step 5: Commit.** `feat(core): annotation geometry and canvas mapping`

### Task 3: Anmerkungen zeichnen

**Files:**
- Create: `ScreenXCore/Annotations/AnnotationRenderer.swift`, `ScreenXCore/Annotations/ArrowPath.swift`
- Modify: `ScreenXCore/Render/Renderer.swift`, `ScreenXCore/Render/RenderInput` (bekommt `annotations: [Annotation] = []`)
- Test: `ScreenXCoreTests/AnnotationRenderTests.swift`, Snapshots unter `__Output__/annotations-*.png`

**Interfaces:**
- Consumes: `Annotation`, `AnnotationGeometry`, Renderer-Kontext (Ursprung oben links)
- Produces:
  - `public enum AnnotationRenderer { static func draw(_ annotations: [Annotation], in ctx: CGContext, original: CGImage, originToCanvas: CGAffineTransform, clipRect: CGRect) }`
  - `originToCanvas` bildet Original-Pixel auf Rahmen-Pixel ab: Zuschnitt-Versatz plus `imageRect.origin`.
  - Anmerkungen werden auf `clipRect` beschnitten. Das ist das abgerundete Bild-Rechteck, damit Unschärfe und Marker innerhalb des Screenshots bleiben.
  - Ausnahme: Pfeile, Text, Notizen und Zähler dürfen über den Bildrand hinausragen. Sie werden nur auf den Rahmen beschnitten.
  - Zeichnen im Detail:
    - **Pfeil:** Linie bzw. quadratische Bézierkurve. Die Spitze ist ein Dreieck mit der Länge `max(18, 4×strokeWidth)` und einem Öffnungswinkel von 28°, gefüllt oder als offene Linie. `double` zeichnet Spitzen an beiden Enden. Die Linie endet an der Basis der Spitze.
    - **Form:** Kontur oder Füllung; abgerundetes Rechteck mit Radius `min(w,h) × 0.15`.
    - **Text:** Core Text, Systemschrift in `fontSize` (fett optional). Hintergrund-Box mit 6 px Innenabstand und Radius 6; Umbruch auf `frame.width`.
    - **Notiz:** gefülltes Rechteck in `noteColor`, Radius 4, Schatten (0, 4) mit Weichheit 12 und Schwarz bei 18 % Deckkraft, Text 16 px Innenabstand in `#3A2F00`, Schriftgröße 15 × Skalierung des Originals.
    - **Zähler:** gefüllter Kreis in `color`, Zahl fett weiß, Schriftgröße `radius × 1.1`.
    - **Unschärfe:**
      - Ausschnitt `rect` aus dem Original nehmen.
      - Weichzeichnen: `CIGaussianBlur` mit `strength`, Ränder per `clampedToExtent`.
      - Verpixeln: `CIPixellate` mit Blockgröße `max(4, strength)`.
      - Ergebnis an `rect` zeichnen.
    - **Marker:** Füllung in `color` mit 40 % Deckkraft, Mischmodus `.multiply`.
    - **Rotation:** um das Zentrum der Bounds.

- [ ] **Step 1: Failing Tests.** Leinwand: weiß, Abstand 0, Schatten 0. Original 200×100, weiß.
  - `arrowDrawsColor`: Pfeil von (20,50) nach (180,50), rot, Stärke 6 → Pixel (100,50) ist rot.
  - `filledShape`: Gefülltes Rechteck (10,10,50,50), blau → Pixel (35,35) ist blau.
  - `outlineShapeHollow`: Konturrechteck (10,10,50,50) → Pixel (35,35) ist weiß, Pixel (10,35) ist farbig.
  - `counterDrawsCircle`: Zähler bei (100,50) mit Radius 20 → Pixel (100,40) hat die Farbe.
  - `blurChangesPixels`: Original mit schwarzem Streifen bei x = 100…102. Unschärfe (80,0,40,100) mit Stärke 10 → Pixel (101,50) ist heller als 30, der Streifen wurde also weichgezeichnet.
  - `pixelateBlocks`: Originalverlauf, Verpixeln mit Blockgröße 20 → Pixel (0,0) und (10,10) sind gleich.
  - `highlightMultiplies`: Marker in Gelb auf weißem Grund → Pixel ist gelblich, nicht weiß.
  - `annotationsOutsideCropKeptButClipped`: Zuschnitt (0,0,100,100), gefülltes Rechteck bei (150,10,20,20) → nicht im Bild, aber nach dem Kodieren und Dekodieren noch im Modell.
  - `rotationApplied`: Gefülltes Rechteck (90,40,20,20) um 45° gedreht → Pixel (100,50), die Mitte, ist farbig.
  - `writesAnnotationSnapshots`: eine Szene mit allen Arten nach `__Output__/annotations-all.png`.
- [ ] **Step 2: Tests laufen lassen.** Erwartet: FAIL.
- [ ] **Step 3: Implementieren.** Im `Renderer` nach dem Bild `AnnotationRenderer.draw` aufrufen.
- [ ] **Step 4: Tests laufen lassen.** Erwartet: PASS, alle bisherigen Renderer-Tests grün.
- [ ] **Step 5: Commit.** `feat(core): draw annotations in renderer`

### Task 4: Werkzeug-Zustand, Werkzeugleiste und Optionsleiste

**Files:**
- Create: `ScreenX/Editor/Tools/EditorTool.swift`, `ScreenX/Editor/Tools/ToolSettings.swift`, `ScreenX/Editor/Tools/ToolOptionsBar.swift`, `ScreenX/Editor/Tools/ColorPaletteView.swift`
- Modify: `ScreenX/Editor/EditorToolbar.swift`, `ScreenX/Editor/EditorViewModel.swift` (Auswahl-Zustand)

**Interfaces:**
- Produces:
  - `enum EditorTool: CaseIterable { case select, arrow, shape, text, note, counter, blur, highlight, crop }`
    - `var key: Character` (V A R T N C B H K), `var symbolName: String` (SF Symbols), `var title: String` (deutsch)
  - `@MainActor @Observable final class ToolSettings` mit diesen Eigenschaften:
    - `color`, `strokeWidth`
    - `arrowCurved`, `arrowHead`
    - `shapeKind`, `shapeFilled`
    - `fontSize` (Standard 32), `textBold`, `textBackground: ColorValue?`
    - `noteColor`
    - `counterStart` (Standard 1)
    - `blurMode`, `blurStrength` (Standard 12)
  - Persistiert in `UserDefaults` unter dem Key `"toolSettings.v1"` (Codable-Abbild).
  - `EditorViewModel` bekommt:
    - `var tool: EditorTool = .select`
    - `var selection: Set<UUID>`
    - `func select(_ id: UUID?, extend: Bool)`
    - `func deleteSelection()`, `func duplicateSelection()` (Versatz +20 px)
    - `func bringForward()`, `func sendBackward()`
    - jede Aktion über `apply` mit deutschem Aktionsnamen
- [ ] **Step 1: Werkzeugleiste.** Werkzeug-Buttons wie im Figma-Entwurf (Icon + Text), der aktive ist hervorgehoben. Tooltip mit Taste. Tasten ohne Modifier wechseln das Werkzeug, solange keine Textbearbeitung aktiv ist.
- [ ] **Step 2: Optionsleiste.** Eine schmale Leiste unter der Werkzeugleiste zeigt nur die Optionen des aktiven Werkzeugs bzw. der ausgewählten Anmerkung. Werden bei einer Auswahl Optionen geändert, wirken sie auf die Auswahl (über `apply`).
- [ ] **Step 3: App-Build in CI.** Erwartet: grün.
- [ ] **Step 4: Commit.** `feat: editor tools, toolbar and options bar`

### Task 5: Interaktion auf der Arbeitsfläche

**Files:**
- Create: `ScreenX/Editor/Interaction/AnnotationInteractionView.swift`, `ScreenX/Editor/Interaction/SelectionOverlayLayer.swift`, `ScreenX/Editor/Interaction/DragOperation.swift`
- Modify: `ScreenX/Editor/CanvasView.swift`

**Interfaces:**
- Consumes: `AnnotationGeometry`, `CanvasMapping`, `EditorViewModel` (`apply` / `applyLive` / `beginContinuousChange` / `endContinuousChange`, `selection`, `tool`), `ToolSettings`
- Produces: eine `NSView`, die exakt über der Vorschau liegt und Maus- und Tastenereignisse verarbeitet.
  - Ziehen mit einem Zeichenwerkzeug erzeugt eine Anmerkung. Live-Vorschau über `applyLive`, beim Loslassen ein Undo-Schritt „Pfeil hinzufügen“ usw.
    - Sehr kleine Züge unter 4 px werden verworfen.
    - Ausnahme Zähler: Ein Klick setzt den Zähler mit `nextCounterNumber` und Radius `max(14, strokeWidth × 3)`.
    - Text und Notiz erzeugen auch per Klick einen Standardrahmen (Text 300×fontSize×1,4, Notiz 220×160) und öffnen sofort die Textbearbeitung (Task 6).
  - Auswahl:
    - Klick → `hitTest` mit Toleranz `8 / viewScale`
    - ⇧-Klick erweitert die Auswahl
    - Klick ins Leere hebt die Auswahl auf
    - Rahmen-Auswahl durch Ziehen im Leeren
  - Ausgewählte Anmerkungen:
    - gestrichelte Bounds, Griffe als 8 pt große Kreise, Rotationsgriff mit Linie
    - Ziehen verschiebt bzw. skaliert; ⇧ hält proportional bzw. rastet ein
  - Pfeile per Shift nach `snapAngle`, Formen per `constrainedRect`.
  - Cursor: Fadenkreuz bei Zeichenwerkzeugen, Pfeil bei Auswahl, Größenänderungs-Cursor über Griffen.
  - Tasten: ⌫/Entf löschen, ⌘D, ⌘], ⌘[, Esc, Pfeiltasten verschieben um 1 px (mit ⇧ um 10 px).
- [ ] **Step 1: Implementieren.**
- [ ] **Step 2: App-Build in CI.** Erwartet: grün.
- [ ] **Step 3: Commit.** `feat: annotation canvas interaction`

### Task 6: Textbearbeitung und Zuschnitt-Werkzeug

**Files:**
- Create: `ScreenX/Editor/Interaction/InlineTextEditor.swift`, `ScreenX/Editor/Interaction/CropInteraction.swift`
- Modify: `ScreenX/Editor/Interaction/AnnotationInteractionView.swift`

**Interfaces:**
- Consumes: `EditorViewModel`, `CanvasMapping`, `DocumentModel.crop`
- Produces:
  - **Textbearbeitung:** Ein `NSTextView` liegt über dem Text- bzw. Notizrahmen, skaliert auf die Ansicht. Schrift und Farbe entsprechen der Darstellung.
    - Doppelklick auf Text oder Notiz bearbeitet sie.
    - ⌘↩ oder ein Klick daneben übernimmt die Änderung als einen Undo-Schritt „Text bearbeiten“.
    - Esc bricht ab. Wird eine neue Anmerkung mit leerem Text abgebrochen, wird sie entfernt.
    - Die Rahmenhöhe wächst mit dem Inhalt (Messung über Core Text).
  - **Zuschnitt (K):**
    - Zeigt das ganze Original mit dem aktuellen Zuschnitt-Rahmen; der Bereich außerhalb ist zu 50 % abgedunkelt.
    - 8 Griffe, der Rahmen ist verschiebbar, ⇧ hält das Seitenverhältnis.
    - ↩ oder „Fertig“ übernimmt die Änderung als einen Undo-Schritt „Zuschneiden“. Esc verwirft.
    - Button „Zurücksetzen“ setzt `crop = nil`.
    - Mindestgröße 16×16 px.
- [ ] **Step 1: Implementieren.**
- [ ] **Step 2: App-Build in CI.** Erwartet: grün.
- [ ] **Step 3: Commit.** `feat: inline text editing and crop tool`

### Task 7: Manuelle Checkliste M3

**Files:**
- Create: `docs/checklists/M3.md`

- [ ] **Step 1:** Checkliste schreiben. Punkte:
  1. Jedes Werkzeug per Taste und per Klick wählbar.
  2. Pfeil gerade, gebogen und mit doppelter Spitze; ⇧ rastet in 45° ein.
  3. Formen inkl. Linie, gefüllt oder als Kontur; ⇧ hält sie proportional.
  4. Text mit Größe, fett und Hintergrund; Notiz in 5 Farben, mehrzeilig.
  5. Zähler zählen weiter, auch nach dem Löschen eines Zählers; Startwert einstellbar.
  6. Unschärfe und Verpixeln verdecken Text zuverlässig, auch im Export.
  7. Marker wirkt wie ein Textmarker.
  8. Auswahl, Verschieben, Größe ändern, Drehen, ⌘D, ⌫, Ebenenreihenfolge, Pfeiltasten.
  9. Zuschnitt verkleinern und wieder vergrößern: Anmerkungen bleiben erhalten.
  10. ⌘Z / ⇧⌘Z über alle Aktionen; ein Zug ergibt genau einen Schritt.
  11. Exportiertes Bild ist identisch mit der Vorschau.
  12. Projekt mit Anmerkungen speichern und wieder öffnen.
- [ ] **Step 2: Commit.** `docs: M3 manual test checklist`
