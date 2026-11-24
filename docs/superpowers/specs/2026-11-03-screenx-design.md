# ScreenX – Design-Spezifikation

Stand: 2026-11-03 · Status: zur Durchsicht

## 1. Ziel

ScreenX ist eine schnelle, leichte Screenshot-App für macOS. Sie nimmt Bereiche, Fenster oder den ganzen Bildschirm auf und bietet danach einen aufgeräumten Editor zum Verschönern (Hintergrund, Verlauf, Ecken, Schatten), Annotieren (Pfeile, Text, Notizzettel …) und zum Einsetzen in Gerätevorlagen (Mac, iPhone, iPad). Vorbilder in Funktionsumfang und Anmutung: CleanShot X, Screenshot Beautifier, Mockify. Es wird keine dieser Apps nachgebaut. Name, Grafiken und Gestaltung sind eigenständig.

**Zielgruppe:** der Eigentümer des Repos, für den Eigengebrauch. Keine Verteilung über den App Store, deshalb keine App-Sandbox.

**Erfolgskriterien**
- Vom Tastenkürzel bis zur fertigen Aufnahme im Schnellzugriff vergeht kaum spürbare Zeit (Ziel: < 300 ms nach Ende der Auswahl).
- Die App hat im Leerlauf keine spürbare Last (Menüleisten-App, kein Hintergrund-Polling).
- Ein typischer Ablauf (Aufnahme → Verlauf + Schatten → Pfeil → Kopieren) ist in unter 15 Sekunden erledigt.
- Exporte sind pixelgenau und in Retina-Auflösung.

## 2. Rahmenbedingungen

| Punkt | Festlegung |
|---|---|
| Sprache / UI | Swift 6, SwiftUI + AppKit (wo SwiftUI nicht reicht: Overlay-Fenster, Menüleiste, Panels) |
| Mindest-macOS | macOS 26 (Deployment Target). Entwickelt und getestet wird auf macOS 27. Es werden nur APIs genutzt, die auf macOS 26 verfügbar sind. |
| Aufnahme | ScreenCaptureKit (`SCScreenshotManager`, `SCShareableContent`) |
| Rendering | Core Graphics + Core Image |
| Projekt | XcodeGen (`project.yml`). Die `.xcodeproj` wird generiert und nicht eingecheckt. |
| Externe Abhängigkeiten | keine in der App. XcodeGen nur als Build-Werkzeug. |
| Signierung | lokal mit dem „Personal Team“ des Nutzers, damit die Bildschirmaufnahme-Freigabe über Neubauten hinweg erhalten bleibt. Die CI baut unsigniert. |
| Bundle-ID | `com.screenx.app` (lokal änderbar) |
| UI-Sprache | Deutsch (Strings über String Catalog, später übersetzbar) |
| Design-Entwurf | Figma: https://www.figma.com/design/Yhkpngu3GZy7vxFyyeS2fM (Editor + Schnellzugriff) |

## 3. Architektur

Menüleisten-App (`LSUIElement`), kein Dock-Symbol. Eigene Fenster gibt es nur für Editor und Einstellungen.

| Modul | Typ | Aufgabe | Abhängig von |
|---|---|---|---|
| `ScreenXCore` | Framework | Datenmodell, Layout-Berechnung, Renderer, Export, `.screenx`-Format, Vorlagen-Definitionen | Core Graphics, Core Image, ImageIO |
| `ScreenX` (App) | App-Target | Menüleiste, Einstellungen, App-Lebenszyklus | alle Module |
| `Capture` | Ordner im App-Target | ScreenCaptureKit-Aufnahme, Auswahl-Overlay, Fenster-Erkennung, Berechtigungsprüfung | ScreenCaptureKit, AppKit |
| `Hotkeys` | Ordner im App-Target | Globale Tastenkürzel über Carbon `RegisterEventHotKey` | Carbon |
| `QuickAccess` | Ordner im App-Target | Schwebendes Vorschau-Panel nach der Aufnahme | AppKit, `ScreenXCore` |
| `Editor` | Ordner im App-Target | Editor-Fenster, Werkzeuge, Inspektor, Undo | SwiftUI, `ScreenXCore` |
| `ScreenXCoreTests` | Test-Target | Unit- und Render-Tests | `ScreenXCore` |

**Grundregel:** Alles, was rechnet oder rendert, liegt in `ScreenXCore` und ist ohne Bildschirm und ohne Berechtigungen testbar. Die App-Module sind dünne UI- und Systemschichten.

### Datenfluss

```
Tastenkürzel ─▶ Capture (Overlay / Fenster / Vollbild)
              ─▶ CGImage + Metadaten (Skalierung, Fenstertitel)
              ─▶ ScreenXDocument (Original + zuletzt genutzter Stil)
              ─▶ QuickAccess-Panel  ──(Bearbeiten)──▶ Editor
                       │                                  │
                       └──(Kopieren/Sichern)──▶ Renderer ◀┘
                                                  │
                                         PNG/JPEG/Zwischenablage/.screenx
```

## 4. Teil 1 – Aufnahme

**Modi**
- **Vollbild:** der Bildschirm, auf dem sich der Mauszeiger befindet.
- **Bereich:** Pro Bildschirm ein randloses, transparentes Overlay-Fenster über allen anderen Fenstern. Es zeigt ein Fadenkreuz, eine Lupe (Pixel-Ansicht um den Zeiger) und die Auswahlgröße in Pixeln. Mit ⇧ wird die Auswahl quadratisch, mit Leertaste lässt sie sich verschieben, Esc bricht ab.
- **Fenster:** Das Fenster unter dem Mauszeiger wird hervorgehoben, ein Klick nimmt es auf. Wahlweise mit transparentem Hintergrund und Systemschatten (Einstellung).

**Standard-Tastenkürzel** (alle in den Einstellungen änderbar)

| Aktion | Kürzel |
|---|---|
| Vollbild | ⌥⇧3 |
| Bereich | ⌥⇧4 |
| Fenster | ⌥⇧5 |

Die System-Kürzel ⌘⇧3/4/5 bleiben unangetastet.

**Nach der Aufnahme** (Einstellung, Standard = Schnellzugriff)
- **Schnellzugriff:** Panel unten links mit Vorschau. Beim Überfahren erscheinen Kopieren, Sichern, Bearbeiten und Schließen. Die Vorschau lässt sich per Drag & Drop als Datei in andere Apps ziehen. Das Panel verschwindet nach 6 s (einstellbar; Anheften verhindert das). Mehrere Aufnahmen stapeln sich.
- **Editor direkt öffnen.**

**Menüleiste:** Aufnahme-Aktionen, „Letzte Aufnahme bearbeiten“, „Datei öffnen …“, Einstellungen, Beenden.

**Berechtigung:** Beim Start und vor jeder Aufnahme wird die Bildschirmaufnahme-Freigabe geprüft (`CGPreflightScreenCaptureAccess`). Fehlt sie, öffnet sich ein Hinweisfenster mit Button zu Systemeinstellungen → Datenschutz → Bildschirmaufnahme.

## 5. Teil 2 – Editor und Verschönern

**Fensteraufbau** (siehe Figma-Entwurf)
- **Oben:** Werkzeugleiste mit den Werkzeugen (Teil 3), Rückgängig/Wiederholen sowie den Aktionen „Kopieren“ und „Sichern“.
- **Mitte:** Arbeitsfläche mit Zoom (Einpassen, 50–400 %) und Anzeige der Ausgabegröße in Pixeln.
- **Rechts:** Inspektor (300 pt) mit den Reitern **Stil**, **Vorlage** und **Export**. Abschnitte lassen sich einklappen.

**Nicht-destruktives Modell:** Das Originalbild bleibt unverändert. Stil, Vorlage, Zuschnitt und Anmerkungen sind Daten im Dokument und werden bei jeder Änderung neu gerendert. Arbeitsfläche und Export verwenden denselben Renderer.

**Reiter „Stil“**

| Einstellung | Werte | Standard |
|---|---|---|
| Hintergrund | Verlauf (12 Vorlagen + eigener aus 2–3 Farbstopps mit Winkel), Farbe, Bild, Unscharfer Screenshot, Keiner (transparent) | Verlauf, Vorlage 1 |
| Abstand | 0–400 px (bezogen auf die Originalgröße) | 64 |
| Eckenradius | 0–60 px | 12 |
| Schatten | Stärke 0–100. Ausklappbar: Versatz Y, Weichheit, Deckkraft | 50 |
| Fensterleiste | Systemschatten des aufgenommenen Fensters behalten ja/nein (nur bei Fensteraufnahmen) | nein |
| Format | Auto, 16:9, 4:3, 1:1, 9:16, 3:2 | Auto |
| Position | 9-Punkt-Ausrichtung innerhalb des Formats | Mitte |

**Stil-Vorlagen:** Die aktuelle Kombination lässt sich unter einem Namen speichern. Der zuletzt genutzte Stil wird auf neue Aufnahmen angewendet (abschaltbar).

**Reiter „Export“**
- Format: PNG (Standard) oder JPEG (Qualität 0–100, Standard 90)
- Skalierung: 1× oder 2× (Standard: native Auflösung der Aufnahme)
- Speicherort: Standard `~/Pictures/ScreenX`, änderbar
- Dateiname: `ScreenX JJJJ-MM-TT um HH.MM.SS.png`

**Ziele:** Zwischenablage (⌘C bzw. „Kopieren“), Datei („Sichern“, ⇧⌘S = „Sichern unter …“), Drag & Drop aus der Arbeitsfläche.

### Projektdatei `.screenx`

Ein Dokument-Paket (ein Ordner, den der Finder als eine Datei anzeigt; UTI `com.screenx.document`, konform zu `com.apple.package`):

```
Name.screenx/
├── document.json     Pflicht. Modell als JSON (siehe unten)
├── original.png      Pflicht. Unverändertes Originalbild
├── background.<ext>  Optional. Eigenes Hintergrundbild
├── assets/           Optional. Bilder eigener Vorlagen, die im Dokument genutzt werden
└── preview.png       Vorschau für Finder und Quick Look (max. 1024 px)
```

`document.json` (Auszug, Feldnamen verbindlich):

```json
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
```

- Das Format wird mit `Codable` umgesetzt. `version` wird beim Laden geprüft:
  - kleinere Version: Migration
  - größere Version: Öffnen nur zum Ansehen, mit Hinweis
- ⌘S speichert das Projekt, beim ersten Speichern mit Dialog.
- Doppelklick auf eine `.screenx`-Datei öffnet den Editor.
- Die Aufnahmen der laufenden Sitzung sind über „Letzte Aufnahme bearbeiten“ erreichbar, auch ohne gespeicherte Projektdatei.

## 6. Teil 3 – Anmerkungen

| Werkzeug | Taste | Optionen |
|---|---|---|
| Auswahl | V | Verschieben, Größe ändern, Drehen, Duplizieren (⌘D), Löschen (⌫), Ebenenreihenfolge |
| Pfeil | A | gerade / gebogen (ein Kontrollpunkt), Strichstärke, Spitze (gefüllt / offen / beidseitig) |
| Form | R | Rechteck, abgerundetes Rechteck, Ellipse, Linie; Kontur oder gefüllt |
| Text | T | Schriftgröße, Farbe, fett, optional Hintergrund-Box |
| Notiz | N | Notizzettel in 5 Farben, mehrzeiliger Text, leichter Schatten |
| Zähler | C | Nummerierte Kreise, zählen automatisch weiter (1, 2, 3 …), Startwert einstellbar |
| Unschärfe | B | Bereich weichzeichnen oder verpixeln, Stärke einstellbar |
| Marker | H | Halbtransparente Fläche (Multiplizieren) |
| Zuschnitt | K | Nicht-destruktiver Zuschnitt des Originals, jederzeit änderbar |

- Gemeinsame Farbpalette: 8 Farben plus Farbwähler. Zuletzt genutzte Farbe und Stärke gelten werkzeugübergreifend.
- Mit ⇧ rasten Pfeile und Linien in 45°-Schritten ein, Formen bleiben proportional.
- Rückgängig und Wiederholen (⌘Z / ⇧⌘Z) laufen über den `UndoManager` des Dokuments und decken alle Änderungen ab, auch Stil und Vorlage.
- Anmerkungen liegen in Koordinaten des Originalbilds. So bleiben sie beim Ändern von Abstand oder Format an ihrer Stelle.
- Unschärfe und Verpixeln lesen aus dem Originalbild und sind nicht destruktiv.

## 7. Teil 4 – Gerätevorlagen

**Mitgelieferte Vorlagen** (eigene Vektorzeichnungen, nicht von Apple):

| Vorlage | Varianten |
|---|---|
| Laptop | Silber, Space-Schwarz |
| Desktop-Monitor | Silber, Schwarz |
| Smartphone (mit Kamera-Insel) | Hoch/Quer × Hell/Dunkel |
| Tablet | Hoch/Quer × Hell/Dunkel |
| Browserfenster | Hell/Dunkel, URL-Zeile editierbar |

**Vorlagen-Definition** (JSON, im App-Bundle bzw. im Ordner `~/Library/Application Support/ScreenX/Templates/` für eigene Vorlagen):

```json
{
  "id": "phone-portrait-dark",
  "name": "Smartphone hoch, dunkel",
  "frame": { "file": "phone-portrait-dark.pdf" },
  "screenQuad": [[60, 52], [1239, 52], [1239, 2608], [60, 2608]],
  "screenCornerRadius": 55,
  "preferredAspect": [1179, 2556]
}
```

- `screenQuad` gibt die vier Display-Ecken im Koordinatensystem der Rahmengrafik an (oben links, oben rechts, unten rechts, unten links). Bilden sie kein Rechteck, wird der Screenshot per `CIPerspectiveTransform` eingepasst.
- **Eigene Vorlagen:** PNG oder PDF in die App ziehen, die vier Display-Ecken anklicken, benennen. Die Definition wird gespeichert. So lassen sich z. B. offizielle Apple-Geräte-Bilder vom Nutzer selbst einbinden.
- **Einpassen:** *Füllen* (beschneiden, Ausschnitt verschiebbar) oder *Einpassen* (vollständig, Füllfarbe einstellbar). Weicht das Seitenverhältnis um mehr als 15 % ab, erscheint ein Hinweis mit dem empfohlenen Format.
- **Kippen:** 3D-Neigung (X/Y je ±30°) per Perspektiv-Transformation, mit und ohne Gerät.
- Stil (Hintergrund, Abstand, Schatten) wirkt auf die Vorlage als Ganzes. Anmerkungen liegen darüber.

## 8. Fehlerbehandlung

| Situation | Verhalten |
|---|---|
| Keine Bildschirmaufnahme-Freigabe | Hinweisfenster mit Button zu den Systemeinstellungen, keine Aufnahme |
| Esc während der Auswahl | Abbruch ohne Meldung |
| Aufnahme schlägt fehl | Mitteilung mit Grund |
| Tastenkürzel bereits belegt | Hinweis in den Einstellungen, Kürzel bleibt unregistriert |
| Speichern/Export schlägt fehl | Meldung mit Grund. Das Dokument bleibt offen, nichts geht verloren |
| `.screenx` beschädigt oder unvollständig | Fehlermeldung, die Datei wird nicht verändert |
| `.screenx` mit höherer `version` | Öffnen nur zum Ansehen, mit Hinweis |
| Fehlende Vorlage im Dokument | Hinweis. Der Screenshot wird ohne Gerät angezeigt, die Daten bleiben erhalten |

Protokolle gehen über `os.Logger` (Subsystem `com.screenx.app`).

## 9. Testen und CI

**Automatisch (`ScreenXCoreTests`, Swift Testing)**
- Modell: `.screenx` speichern → laden → Gleichheit. Migration älterer Versionen. Ablehnung beschädigter Pakete.
- Layout: Abstand, Formate, Ausrichtung, Einpassen/Füllen, Zuschnitt, Abbildung der `screenQuad`-Punkte, Koordinaten der Anmerkungen.
- Render-Tests: Feste Szenen werden gerendert und mit Referenz-PNGs verglichen (Toleranz pro Pixel). Neue Referenzen entstehen als CI-Artefakt, werden visuell geprüft und erst dann eingecheckt.

**CI (GitHub Actions, macOS-Runner, bei jedem Push)**
1. XcodeGen installieren, `xcodegen generate`
2. `xcodebuild build` für die App (unsigniert)
3. `xcodebuild test` für `ScreenXCoreTests`
4. Gerenderte Testbilder als Artefakt hochladen

**Manuell (Nutzer, auf dem Mac):** Pro Meilenstein eine Checkliste in `docs/checklists/` mit Berechtigung, Tastenkürzeln, Overlay auf mehreren Monitoren, Retina-Schärfe, Drag & Drop und Bedienung.

## 10. Meilensteine

Jeder Meilenstein bekommt einen eigenen Implementierungsplan.

| # | Inhalt | Ergebnis |
|---|---|---|
| M1 | Projektgerüst, CI, Menüleiste, Aufnahme (alle drei Modi), Tastenkürzel, Schnellzugriff, Kopieren/Sichern | Funktionierendes Screenshot-Tool ohne Editor |
| M2 | Editor-Fenster, Renderer, Reiter Stil und Export, `.screenx`-Format | Verschönern und Projektdateien |
| M3 | Anmerkungen inkl. Undo | Vollständiger Editor |
| M4 | Gerätevorlagen, eigene Vorlagen, Kippen | Mockups |

## 11. Spätere Versionen (nicht Teil dieser Spec)

- Selbstauslöser (Timer-Aufnahme)
- Scroll-Aufnahme (lange Seiten zusammensetzen)
- Texterkennung (OCR, Text aus Bild kopieren)
- Bildschirmvideo / GIF-Aufnahme
- Mehrere Geräte in einer Szene (z. B. Mac + iPhone nebeneinander)
