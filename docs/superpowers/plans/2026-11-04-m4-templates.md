# M4 – Gerätevorlagen: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Der Screenshot lässt sich automatisch in Geräterahmen (Laptop, Monitor, Smartphone, Tablet, Browser) oder in eigene Mockup-Bilder einsetzen, auch perspektivisch. Zusätzlich kann er mit und ohne Gerät in 3D gekippt werden.

**Architecture:** Alles Rechnende und Zeichnende liegt in `ScreenXCore`:
- Vorlagen-Modell und Katalog
- selbst gezeichnete Geräte-Vektoren
- Geometrie für Einpassen, Füllen und Kippen
- Einbindung in den Renderer
- Speicher für eigene Vorlagen

Der Renderer arbeitet in drei Schritten:
1. Er rendert den **Bildschirminhalt**: Original, Zuschnitt und Anmerkungen.
2. Er legt diesen Inhalt per `CIPerspectiveTransform` auf das `screenQuad` der Vorlage und zeichnet den Rahmen darüber.
3. Er setzt das Ergebnis wie bisher mit Hintergrund, Abstand und Schatten in die Leinwand.

Die App bekommt den Reiter „Vorlage“ im Inspektor und ein kleines Fenster zum Anlegen eigener Vorlagen.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Core Graphics, Core Image, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-03-screenx-design.md` §7 (komplett), dazu §5 (Paket, `assets/`) und §8 (fehlende Vorlage).

## Global Constraints

- Es gelten alle Constraints von M1 bis M3.
- **Mitgelieferte Vorlagen:** selbst gezeichnet, keine Apple-Grafiken, keine Markennamen in UI-Texten oder IDs.

  | Vorlage | Varianten | IDs |
  |---|---|---|
  | Laptop | Silber, Space-Schwarz | `laptop-silver`, `laptop-black` |
  | Desktop-Monitor | Silber, Schwarz | `monitor-silver`, `monitor-black` |
  | Smartphone | Hoch/Quer × Hell/Dunkel | `phone-portrait-light`, `phone-portrait-dark`, `phone-landscape-light`, `phone-landscape-dark` |
  | Tablet | Hoch/Quer × Hell/Dunkel | `tablet-portrait-light`, `tablet-portrait-dark`, `tablet-landscape-light`, `tablet-landscape-dark` |
  | Browserfenster | Hell/Dunkel, URL-Zeile editierbar | `browser-light`, `browser-dark` |

- **Vorlagen-JSON** nach Spec §7: `id`, `name`, `frame`, `screenQuad` (Reihenfolge oben links, oben rechts, unten rechts, unten links, im Koordinatensystem der Rahmengrafik), `screenCornerRadius`, `preferredAspect`.
- **Eigene Vorlagen** liegen in `~/Library/Application Support/ScreenX/Templates/<id>.json` plus Bilddatei. Benutzt ein Projekt eine eigene Vorlage, wird ihr Bild nach `assets/` im `.screenx`-Paket kopiert.
- **Einpassen:**
  - *Füllen*: beschneiden, Ausschnitt verschiebbar
  - *Einpassen*: vollständig, Füllfarbe einstellbar, Standard Schwarz
- **Hinweis zum Seitenverhältnis:** erscheint, wenn es um mehr als 15 % abweicht.
- **Kippen:** X und Y jeweils ±30°, mit und ohne Gerät.
- **Fehlende Vorlage in einem Dokument:** Hinweis anzeigen, Screenshot ohne Gerät darstellen, die Daten bleiben erhalten.

## Rulings (Abweichungen bzw. Präzisierungen gegenüber der Spec)

- **R1:** Mitgelieferte Rahmen werden im Code als Vektorpfade gezeichnet, nicht als PDF-Datei. Ergebnis und Schärfe sind gleich. Im JSON steht dann `"frame": {"builtin": "<id>"}`, bei eigenen Vorlagen `"frame": {"file": "<name>.png"}`.
- **R2:** Anmerkungen werden auf den Bildschirminhalt gezeichnet und folgen damit der Perspektive des Geräts. Sie liegen also über dem Screenshot, nicht frei über dem Rahmen.
  - Bearbeiten lassen sich Anmerkungen nur, wenn die Abbildung affin ist: rechteckiges `screenQuad` und Kippen 0/0.
  - Sonst zeigt die Optionsleiste: „Zum Bearbeiten der Anmerkungen Kippen auf 0 stellen bzw. eine gerade Vorlage wählen.“ Die Werkzeuge sind dann deaktiviert.
- **R3:** `tilt` wird ein neues Feld von `Style` (`{"x":0,"y":0}`). `Style` und `DocumentModel` dekodieren tolerant (`decodeIfPresent` mit Standardwerten), damit Projekte aus M2 und M3 sich weiter öffnen lassen.

## Review Focus

1. **Projekt aus M2/M3 ohne `tilt` und mit `"template": null` öffnen:** Es lädt unverändert. → Test `decodesPreM4Documents` (Task 1).
2. **Querformat-Screenshot (16:9) im Hochformat-Smartphone:**
   - *Füllen* beschneidet mittig, und der Ausschnitt lässt sich verschieben, ohne über das Bild hinauszugehen.
   - *Einpassen* zeigt das ganze Bild mit Füllfarbe.

   → Tests `fillCropsCenteredAndClampsOffset`, `fitLetterboxes` (Task 2).
3. **Eigene Vorlage, deren Bilddatei später gelöscht wurde:** Das Projekt öffnet trotzdem, weil das Bild im Paket unter `assets/` liegt. Fehlt auch dort, greift der Hinweis aus Spec §8. → Test `customTemplateEmbeddedInPackage` (Task 5).
4. **Kippen bei 30/30 mit sehr breitem Bild:** Die Ecken bleiben endlich, das Bild wird nicht gespiegelt und nicht abgeschnitten. Der Rahmen vergrößert sich passend. → Test `tiltCornersStayInFrontAndBounded` (Task 2).
5. **Schräge Vorlage (Quad kein Rechteck) plus Anmerkungswerkzeug:** Die Werkzeuge sind deaktiviert. Es gibt keine falsch platzierten Anmerkungen. → Test `affineMappingOnlyForRectQuadsWithoutTilt` (Task 2).

---

### Task 1: Vorlagen-Modell, Katalog und Dokumentfelder

**Files:**
- Create: `ScreenXCore/Templates/DeviceTemplate.swift`, `ScreenXCore/Templates/TemplateCatalog.swift`, `ScreenXCore/Templates/TemplatePlacement.swift`
- Modify:
  - `ScreenXCore/Style/Style.swift`: neues Feld `tilt: Tilt`, tolerantes `init(from:)`
  - `ScreenXCore/Document/DocumentModel.swift`: Feld `template: TemplatePlacement?`, das bisher fest kodierte `null` entfällt
- Test: `ScreenXCoreTests/TemplateModelTests.swift`

**Interfaces:**
- Produces:
  - `public enum TemplateFrame: Codable, Hashable, Sendable { case builtin(String), file(String) }`, als JSON `{"builtin":"…"}` bzw. `{"file":"…"}`
  - `public struct DeviceTemplate: Codable, Hashable, Sendable, Identifiable` mit den Feldern:
    - `id: String`, `name: String`, `frame: TemplateFrame`
    - `frameSize: CGSize`: Größe der Rahmengrafik in ihren eigenen Einheiten
    - `screenQuad: [CGPoint]` mit genau 4 Punkten
    - `screenCornerRadius: Double`, `preferredAspect: [Int]?`
    - `var isRectangular: Bool`: Das Quad ist achsenparallel, Toleranz 0,5
  - `public struct Tilt: Codable, Hashable, Sendable { x: Double; y: Double; static let zero }`, Werte in Grad
  - `public enum FitMode: String, Codable, Sendable { case fill, fit }`
  - `public struct TemplatePlacement: Codable, Hashable, Sendable { templateID: String; fit: FitMode; fillColor: ColorValue; offset: CGPoint /* -1…1, nur bei fill */; urlText: String? /* nur Browser */ }`
  - `public enum TemplateCatalog { static let builtins: [DeviceTemplate]; static func builtin(id: String) -> DeviceTemplate? }`
    - 14 Einträge mit den IDs aus den Global Constraints, Namen deutsch (z. B. „Smartphone hoch, dunkel“)
    - `frameSize` und `screenQuad` passen zur Zeichnung aus Task 3

    | Gerät | `frameSize` | Bildschirm (x, y, b, h) | Display-Radius | `preferredAspect` |
    |---|---|---|---|---|
    | Laptop | 3000×1900 | (330, 120, 2340, 1462) | 18 | 16:10 |
    | Monitor | 2800×2300 | (100, 100, 2600, 1462) | 0 | 16:9 |
    | Smartphone hoch | 1300×2660 | (60, 60, 1180, 2540) | 150 | 1179:2556 |
    | Tablet hoch | 1800×2440 | (90, 90, 1620, 2160) | 40 | 3:4 |
    | Browser | 2400×1500 | (0, 88, 2400, 1412) | 0 | keiner |

    Querformate sind gedreht: Breite und Höhe tauschen, das Quad wird entsprechend transformiert.
- [ ] **Step 1: Failing Tests.**
  - `catalogHas14UniqueIDs`
  - `quadsInsideFrame`: alle Quad-Punkte liegen innerhalb von `frameSize`
  - `builtinsAreRectangular`
  - `templateJSONShape`: `{"builtin":"phone-portrait-dark"}`, `screenQuad` als Array von `[x,y]`-Paaren gemäß Spec-Beispiel (eigenes Codable für die Punkte)
  - `decodesPreM4Documents`: Dokument-JSON ohne `tilt` und mit `"template": null` → `tilt == .zero`, `template == nil`
  - `placementRoundTrip`
- [ ] **Step 2: Tests laufen lassen.** Erwartet: FAIL.
- [ ] **Step 3: Implementieren.**
- [ ] **Step 4: Tests laufen lassen.** Erwartet: PASS, alle bisherigen Tests grün.
- [ ] **Step 5: Commit.** `feat(core): device template model and catalog`

### Task 2: Vorlagen-Geometrie

**Files:**
- Create: `ScreenXCore/Templates/TemplateGeometry.swift`
- Test: `ScreenXCoreTests/TemplateGeometryTests.swift`

**Interfaces:**
- Consumes: `DeviceTemplate`, `TemplatePlacement`, `Tilt`
- Produces: `public enum TemplateGeometry` mit:
  - `static func sourceRect(contentSize: CGSize, screenSize: CGSize, fit: FitMode, offset: CGPoint) -> (source: CGRect, dest: CGRect)`
    - **fill:** Ausschnitt mit dem Seitenverhältnis des Bildschirms, mittig plus `offset` × freier Bereich, begrenzt auf den Inhalt. `dest` ist der ganze Bildschirm.
    - **fit:** `source` ist der ganze Inhalt, `dest` ist eingepasst und zentriert.
  - `static func frameScale(template: DeviceTemplate, contentSize: CGSize) -> CGFloat`. Faktor, damit die Breite des Bildschirms (Quad-Bounds) der Breite des Inhalts in Pixeln entspricht. Mindestens 0,25, höchstens 4.
  - `static func aspectMismatch(contentSize: CGSize, preferred: [Int]?) -> Double?`. Relative Abweichung `|c/p − 1|`; `nil` ohne `preferredAspect`.
  - `static func recommendedAspectText(_ preferred: [Int]) -> String`. Z. B. „19,5:9“ (gekürzt, eine Nachkommastelle, deutsches Komma).
  - `static func tiltCorners(size: CGSize, tilt: Tilt) -> [CGPoint]`
    - Perspektivische Projektion: Drehung um die X- und Y-Achse mit Betrachtungsabstand `d = 2.5 × max(w, h)`.
    - Liefert die 4 Ecken (oben links, oben rechts, unten rechts, unten links) in Koordinaten, die ins positive Rechteck verschoben sind.
  - `static func isAffineEditable(template: DeviceTemplate?, tilt: Tilt) -> Bool`
  - `static func screenToContentTransform(template: DeviceTemplate, placement: TemplatePlacement, contentSize: CGSize, frameScale: CGFloat) -> CGAffineTransform?`. Nur bei affiner Abbildung, sonst `nil`. Für die Abbildung der Anmerkungen in der App.
- [ ] **Step 1: Failing Tests.**
  - `fillCropsCenteredAndClampsOffset`:
    - Inhalt 1600×900, Bildschirm 1180×2540: Ausschnittbreite = 900 × 1180/2540 ≈ 418,1, mittig bei x ≈ 590,9.
    - Mit `offset` (1, 0) liegt der Ausschnitt rechts bündig (x + w = 1600).
    - Mit `offset` (5, 0) wird auf denselben Wert begrenzt.
  - `fitLetterboxes`: Inhalt 1600×900, Bildschirm 1180×2540 → `dest` ist 1180×663,75, mittig bei y ≈ 938,1.
  - `frameScaleMatchesWidth`: Smartphone hoch, Inhalt 2360 breit → Faktor 2.
  - `aspectMismatchThreshold`:
    - 1600×900 gegen 16:9 ergibt 0
    - 1600×900 gegen 1179:2556 ergibt mehr als 0,15
    - `recommendedAspectText([1179,2556])` liefert „9:19,5“. Dafür wird auf die kleinere Seite 9 normiert, also 9 : 19,5.
  - `tiltZeroIsIdentityRect`: Kippen 0/0 → Ecken (0,0), (w,0), (w,h), (0,h).
  - `tiltCornersStayInFrontAndBounded`: 3000×500 bei 30/30 → alle Ecken endlich, Winding-Reihenfolge erhalten (Kreuzprodukt-Vorzeichen gleich), Bounds unter 3 × Originalgröße.
  - `affineMappingOnlyForRectQuadsWithoutTilt`:
    - eingebaute Vorlage ohne Kippen ergibt true
    - mit Kippen (5, 0) ergibt false
    - schräges Quad ergibt false
    - ohne Vorlage und ohne Kippen ergibt true
- [ ] **Step 2: Tests laufen lassen.** Erwartet: FAIL.
- [ ] **Step 3: Implementieren.**
- [ ] **Step 4: Tests laufen lassen.** Erwartet: PASS.
- [ ] **Step 5: Commit.** `feat(core): template fit, fill and tilt geometry`

### Task 3: Geräte-Zeichnungen

**Files:**
- Create: `ScreenXCore/Templates/DeviceArtwork.swift`, `ScreenXCore/Templates/DeviceArtwork+Shapes.swift`
- Test: `ScreenXCoreTests/DeviceArtworkTests.swift`, Snapshots `__Output__/device-<id>.png`

**Interfaces:**
- Consumes: `DeviceTemplate`, `TemplateCatalog`
- Produces: `public enum DeviceArtwork`
  - `static func draw(builtin id: String, in ctx: CGContext, size: CGSize, urlText: String?)`
    - Zeichnet den Rahmen in Koordinaten von `frameSize`, skaliert auf `size`, mit Ursprung oben links.
    - Die Bildschirmfläche bleibt transparent: Ausstanzen über einen Even-Odd-Pfad.
  - `static func image(builtin id: String, scale: CGFloat, urlText: String?) -> CGImage?`
  - Gestaltung: schlicht und modern, ohne Logos.

    | Gerät | Gestaltung |
    |---|---|
    | Laptop | abgerundeter Deckel, schmaler Rand, Kamera-Punkt, Unterteil als flaches Trapez mit Griffmulde |
    | Monitor | dünner Rand, Standfuß mit Hals und Platte |
    | Smartphone | Radius ≈ 170, gleichmäßiger Rand, Kamera-Insel als Pille oben mittig über dem Bildschirm, Seitentasten |
    | Tablet | gleichmäßiger Rand, Kamera-Punkt |
    | Browser | Titelleiste mit drei Kreisen in neutralem Grau, URL-Feld mit `urlText` (Standard „example.com“), Systemschrift |

  - Farben:

    | Variante | Gehäuse | Rand | Bildschirm-Rahmen innen |
    |---|---|---|---|
    | Silber | `#E3E4E6` | `#C9CACD` | `#111` |
    | Schwarz | `#2B2C2F` | `#1A1B1D` | `#000` |
    | Hell | `#F5F5F7` | | |
    | Dunkel | `#1D1D1F` | | |

    Leichte Verläufe sind erlaubt.
- [ ] **Step 1: Failing Tests.**
  - `screenAreaTransparent`: Für jede eingebaute Vorlage ist der Pixel in der Bildschirm-Mitte transparent (Alpha 0).
  - `bezelOpaque`: Ein Pixel 10 Einheiten außerhalb der linken Bildschirmkante ist deckend.
  - `writesDeviceSnapshots`: schreibt alle 14 Vorlagen als PNG.
- [ ] **Step 2–4:** RED → Implementieren → GREEN, mit Sichtprüfung der Snapshots durch den Controller.
- [ ] **Step 5: Commit.** `feat(core): vector device artwork`

### Task 4: Renderer-Integration

**Files:**
- Modify: `ScreenXCore/Render/Renderer.swift`, `ScreenXCore/Render/RenderInput` (neue Felder `template: DeviceTemplate?`, `placement: TemplatePlacement?`, `customFrameImage: CGImage?`)
- Create: `ScreenXCore/Render/DeviceCompositor.swift`
- Test: `ScreenXCoreTests/DeviceRenderTests.swift`, Snapshots `__Output__/mockup-*.png`

**Interfaces:**
- Consumes: `TemplateGeometry`, `DeviceArtwork`, `AnnotationRenderer`, `CanvasLayout`
- Produces:
  - `DeviceCompositor.compose(content: CGImage, template:, placement:, customFrame:, scale:) -> CGImage`. Bildschirminhalt per Perspektiv-Transformation ins Quad, Display-Ecken gerundet mit `screenCornerRadius × scale`, Rahmen darüber.
  - Der Renderer läuft so:
    1. `content` = Original mit Zuschnitt und Anmerkungen (Rahmen-Größe = Zuschnitt)
    2. bei gesetzter Vorlage: `compose`
    3. bei Kippen ungleich 0: `CIPerspectiveTransform` mit `tiltCorners`
    4. das Ergebnis ist das „Bild“ für `CanvasLayout`: Hintergrund, Abstand, Schatten
  - Mit Vorlage gilt `cornerRadius` nicht: Der Rahmen hat eigene Ecken. Der Schatten folgt der Alpha-Form des Geräts und wird über den Alphakanal des Bildes gezeichnet, nicht über das Rundrechteck.
  - Fehlende Vorlage (`template == nil`, aber `placement != nil`) → ohne Gerät rendern.
- [ ] **Step 1: Failing Tests.**
  - `mockupContainsScreenshotInScreen`: Smartphone hoch, Inhalt einfarbig blau → Pixel in der Bildschirm-Mitte (umgerechnet) ist blau, Pixel auf dem Rand ist Gehäusefarbe.
  - `fitUsesFillColor`: *Einpassen* mit Füllfarbe rot, 16:9-Inhalt im Hochformat → Pixel oben im Bildschirm ist rot.
  - `tiltChangesShape`: Ohne Vorlage, Kippen (0, 20) → die Ecke oben links der Leinwand-Bildfläche ist Hintergrund, nicht Bild.
  - `missingTemplateRendersPlain`.
  - `shadowFollowsDeviceAlpha`: Schatten 100 bei Vorlage → Pixel unter dem Gerät ist dunkler als der Hintergrund.
  - `writesMockupSnapshots`: Laptop, Smartphone, Tablet quer, Browser, gekippt 15/−10.
- [ ] **Step 2–4:** RED → Implementieren → GREEN.
- [ ] **Step 5: Commit.** `feat(core): render screenshots into device templates`

### Task 5: Eigene Vorlagen und Einbettung im Paket

**Files:**
- Create: `ScreenXCore/Templates/CustomTemplateStore.swift`
- Modify: `ScreenXCore/Document/ScreenXPackage.swift` (`assets/` lesen und schreiben, `LoadedDocument.customTemplate`, `customFrameImage`)
- Test: `ScreenXCoreTests/CustomTemplateTests.swift`

**Interfaces:**
- Produces:
  - `public final class CustomTemplateStore: @unchecked Sendable`:
    - `init(directory: URL)`, Standard `~/Library/Application Support/ScreenX/Templates`
    - `func all() -> [DeviceTemplate]`
    - `func add(name: String, imageData: Data, imageExtension: String, quad: [CGPoint]) throws -> DeviceTemplate`
      - `id` = `custom-<UUID>`, `frameSize` = Pixelgröße des Bildes
      - `screenCornerRadius` 0, `preferredAspect` aus den Quad-Bounds
    - `func delete(id:) throws`, `func image(for: DeviceTemplate) -> CGImage?`
  - Paket: Ist `template` eine eigene Vorlage, werden ihr JSON und Bild beim Schreiben nach `assets/<id>.json` und `assets/<file>` kopiert. Beim Lesen kommen sie bevorzugt aus `assets/`, ersatzweise aus dem Store.
- [ ] **Step 1: Failing Tests.**
  - `addListDelete`
  - `quadValidation`: 4 Punkte nötig, sonst Fehler
  - `customTemplateEmbeddedInPackage`: Speichern, Store-Ordner löschen, wieder öffnen → Vorlage und Bild sind vorhanden.
  - `builtinNotEmbedded`: Für eine eingebaute Vorlage legt das Paket keine Datei in `assets/` an.
- [ ] **Step 2–4:** RED → Implementieren → GREEN.
- [ ] **Step 5: Commit.** `feat(core): custom templates and package embedding`

### Task 6: Reiter „Vorlage“ im Inspektor

**Files:**
- Create: `ScreenX/Editor/Inspector/TemplateSection.swift`, `ScreenX/Editor/Inspector/TemplateThumbnail.swift`, `ScreenX/Editor/Inspector/TiltControl.swift`
- Modify:
  - `ScreenX/Editor/Inspector/InspectorView.swift`: Reiter-Reihenfolge Stil | Vorlage | Export
  - `ScreenX/Editor/EditorViewModel.swift`: Vorlage auflösen, Werkzeuge sperren
  - `ScreenX/Editor/Interaction/AnnotationInteractionView.swift`: Sperre und Abbildung über `screenToContentTransform`
  - `ScreenX/Editor/Tools/ToolOptionsBar.swift`: Hinweistext
- **Inhalt:**
  - Raster mit Vorschaubildern:
    - „Ohne Gerät“
    - Gruppen Laptop, Monitor, Smartphone, Tablet, Browser mit den Varianten als kleine Auswahl unter der Gruppe
    - „Eigene“ mit den Vorlagen aus dem Store und „+ Eigene Vorlage …“ (öffnet Task 7)
  - Einpassen: Segmente Füllen | Einpassen, Füllfarbe (bei Einpassen), bei Füllen zwei Regler für den Ausschnitt (X/Y −1…1)
  - Browser: Textfeld für die URL
  - Kippen: zwei Regler X/Y −30…30° mit Zurücksetzen, auch ohne Gerät aktiv
  - Hinweis bei `aspectMismatch` > 0,15: „Für dieses Gerät besser im Format <Text> aufnehmen.“
  - Fehlende Vorlage im Dokument → gelber Hinweis „Vorlage nicht gefunden – Screenshot wird ohne Gerät gezeigt.“
- Alle Änderungen laufen über `apply`, Regler über `begin`/`live`/`end`.
- [ ] **Step 1: Implementieren.**
- [ ] **Step 2: App-Build in CI.** Erwartet: grün.
- [ ] **Step 3: Commit.** `feat: template inspector, tilt and annotation gating`

### Task 7: Fenster für eigene Vorlagen

**Files:**
- Create: `ScreenX/Templates/CustomTemplateWindow.swift`, `ScreenX/Templates/QuadPickerView.swift`

**Interfaces:**
- Consumes: `CustomTemplateStore`
- Produces: `CustomTemplateWindow.show(store:onSave:)`
  - Ablagebereich „PNG oder PDF hierher ziehen“ oder „Datei wählen …“. PDF wird mit 2× gerastert und als PNG gespeichert.
  - Danach zeigt das Fenster das Bild eingepasst und den Hinweis „Klicke die vier Ecken des Displays an (oben links beginnend, im Uhrzeigersinn)“.
  - Die Punkte erscheinen nummeriert und lassen sich verschieben.
  - „Zurücksetzen“, Namensfeld, „Sichern“ (aktiv bei 4 Punkten und Name).
  - Beim Sichern: `store.add` und `onSave(template)`.
- [ ] **Step 1: Implementieren.**
- [ ] **Step 2: App-Build in CI.** Erwartet: grün.
- [ ] **Step 3: Commit.** `feat: custom template creator`

### Task 8: Manuelle Checkliste M4

**Files:**
- Create: `docs/checklists/M4.md`

- [ ] **Step 1:** Checkliste schreiben. Punkte:
  1. Jede der 14 Vorlagen sieht sauber aus und bleibt beim Zoomen scharf.
  2. Screenshot sitzt exakt im Display, die Display-Ecken sind gerundet.
  3. Füllen und Einpassen funktionieren, der Ausschnitt ist verschiebbar, die Füllfarbe wirkt.
  4. Der Hinweis zum Seitenverhältnis erscheint z. B. bei 16:9 im Hochformat-Smartphone.
  5. Kippen mit und ohne Gerät; der Schatten folgt der Form.
  6. Anmerkungen ohne Kippen auf geradem Gerät bearbeitbar, mit Kippen gesperrt (Hinweis), Anmerkungen bleiben sichtbar.
  7. Eigene Vorlage aus einem PNG-Mockup anlegen, auswählen, ein Projekt speichern, die Vorlage aus dem Store löschen, das Projekt wieder öffnen: alles noch da.
  8. Der Export entspricht der Vorschau.
  9. Browser-URL editierbar.
- [ ] **Step 2: Commit.** `docs: M4 manual test checklist`
