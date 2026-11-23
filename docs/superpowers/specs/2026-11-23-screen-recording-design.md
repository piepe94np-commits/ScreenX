# ScreenX – Bildschirmaufnahme (Video & GIF) – Design

Stand: 2026-11-23 · Status: zur Durchsicht · Meilenstein M5
Baut auf: `docs/superpowers/specs/2026-11-03-screenx-design.md` (M1–M4; dort §11 „Bildschirmvideo / GIF-Aufnahme“)

## 1. Ziel und Warum

ScreenX bekommt Videoaufnahme vom Bildschirm. Der Nutzer will damit vor allem **Meetings und Präsentationen aufzeichnen**, gelegentlich auch kurze Clips und GIFs.

Sein wichtigster Punkt: **Auflösung, Bildrate und Qualität vor der Aufnahme festlegen**, damit Aufnahmen nicht unnötig groß werden. Viele andere Tools können das nicht. ScreenX zeigt deshalb vor dem Start eine **Größenschätzung (MB pro Minute)**.

**Erfolgskriterien**
- Ein einstündiges Meeting (1080p, 15–30 fps, Ton) läuft stabil durch und ergibt eine Datei in der vorher geschätzten Größenordnung (±25 %).
- Bild und Ton bleiben über eine Stunde synchron (Abweichung < 100 ms).
- Bricht die App oder der Mac ab, ist das bis dahin Aufgenommene abspielbar.
- Vom Tastenkürzel bis zum Start der Aufnahme sind höchstens Auswahl und Countdown nötig, also keine weiteren Dialoge.

## 2. Ziele, Nicht-Ziele, Anti-Ziele

**Ziele**
- Video von Bereich, Fenster oder ganzem Bildschirm
- Ton: Systemton (andere Meeting-Teilnehmer) und Mikrofon, einzeln schaltbar
- Aufnahmeprofile mit Auflösung, Bildrate, Qualität und Codec, mit Größenschätzung; eigene Profile speicherbar
- Pause und Fortsetzen ohne Lücke im Video
- Nach der Aufnahme: Vorschaukarte wie bei Screenshots, schlichtes Kürzen (Anfang und Ende, wie Vorschau/QuickTime), GIF-Export eines Ausschnitts
- GIF-Profil für kurze Clips

**Nicht-Ziele (M5)**
- Webcam-Einblendung
- Schnitte in der Mitte, Text, Anmerkungen oder Zoom-Effekte im Video
- Hochladen oder Teilen-Links, Streaming
- Transkription oder Untertitel
- Mehrere Bildschirme gleichzeitig in einem Video

**Anti-Ziele (würde als Fehlschlag gelten, auch wenn es technisch läuft)**
- Dateien, die unbemerkt viel größer werden als angezeigt
- Eine lange Aufnahme geht verloren (Absturz, voller Speicher, Fehler beim Abschluss)
- ScreenX-Steuerelemente, der Aufnahmerahmen oder die Vorschaukarte erscheinen im Video
- Ton läuft dem Bild davon

## 3. Rahmenbedingungen

Es gelten alle Rahmenbedingungen von M1–M4:
- Swift 6, macOS 26, keine Abhängigkeiten
- deutsche Strings im String Catalog
- CI-Verifikation, ScreenXCore testbar ohne Bildschirm

Neu:

| Punkt | Festlegung |
|---|---|
| Aufnahme | ScreenCaptureKit `SCStream` (Bild, Systemton, Mikrofon über `captureMicrophone`) |
| Kodierung | `AVAssetWriter` (H.264 / HEVC Video, AAC Ton) |
| Kürzen | `AVPlayerView` mit eingebauter Trim-Oberfläche, Export per `AVAssetExportSession` Passthrough |
| GIF | ImageIO (`CGImageDestination`), Bilder aus `AVAssetImageGenerator` |
| Berechtigungen | Bildschirmaufnahme (vorhanden). Neu: Mikrofon (`NSMicrophoneUsageDescription`, Abfrage beim ersten Einschalten) |
| Design | Figma, gleiche Datei wie M1–M4: https://www.figma.com/design/Yhkpngu3GZy7vxFyyeS2fM?node-id=13-2 (8 Rahmen „M5 Video“) |

## 4. Gewählter Ansatz

Betrachtet wurden drei Wege:

| Ansatz | Bewertung |
|---|---|
| **A: Eigene Pipeline** – `SCStream` liefert Bilder und Ton, ScreenX kodiert selbst mit `AVAssetWriter` | **Gewählt.** Volle Kontrolle über Auflösung, Bildrate, Bitrate und Codec. Damit stimmt die Größenschätzung. Pause ohne Lücke, absturzsichere Dateien und Ton-Mischung sind möglich. Nachteil: mehr Code (Synchronisation, Zeitstempel). |
| B: `SCRecordingOutput` – macOS schreibt die Datei | Abgelehnt. Die Bitrate ist nicht einstellbar, die Größe also nur grob steuerbar. Das widerspricht dem Hauptziel. Keine Pause. |
| C: `AVCaptureScreenInput` | Abgelehnt. Kein Systemton, deshalb für Meetings unbrauchbar. |

Der Nutzer hat A gewählt.

**GIF** wird nicht direkt aufgenommen. Das GIF-Profil nimmt intern ein kleines Video auf und wandelt es am Ende um. So gibt es nur eine Aufnahmetechnik.

## 5. Ablauf

```
⌥⇧6 (oder Menü „Video aufnehmen …“)
  ─▶ Aufnahme-Leiste (schwebend, unten mittig)
       Modus [Bereich | Fenster | Bildschirm] · Profil ▾ · 🎙 Mikrofon ▾ · 🔊 Systemton · ≈ 45 MB/min · [Aufnehmen]
  ─▶ Auswahl wie bei Screenshots (Overlay / Fenster-Hervorhebung / Bildschirm unter dem Zeiger)
  ─▶ Countdown 3-2-1 (einstellbar: aus / 3 s / 5 s; Esc bricht ab)
  ─▶ Aufnahme läuft
       Menüleiste: ● 12:34 (rot)  →  Klick: Stopp · Pause/Fortsetzen · Verwerfen · aktuelle Größe
       Bereichsmodus: gestrichelter Rahmen um den Bereich (nicht im Video)
       ⌥⇧6 erneut = Stopp
  ─▶ Datei fertigstellen (Ton mischen, siehe §7) – Menüleiste zeigt „Wird gesichert …“
  ─▶ Vorschaukarte (unten links, wie Screenshots): Vorschaubild + Dauer + Größe
       Öffnen · Kürzen · Im Finder zeigen · Löschen · Herausziehen als Datei
  ─▶ Kürzen-Fenster (optional): Zeitleiste mit Griffen, Wiedergabe, „Sichern“, „Als GIF …“
```

Die Aufnahme-Leiste merkt sich Modus, Profil und Ton-Schalter der letzten Aufnahme. Mit ↩ startet sie direkt. Eigene Kürzel pro Modus (z. B. „Bildschirm-Video sofort starten“) sind in den Einstellungen belegbar, standardmäßig aber leer.

## 6. Aufnahmeprofile und Größenkontrolle

**Profil** = Name + folgende Einstellungen:

| Einstellung | Werte |
|---|---|
| Auflösung | Original, 1440p, 1080p, 720p, 480p (begrenzt die **längere** Seite des Inhalts auf 2560 / 1920 / 1280 / 854. Seitenverhältnis bleibt, Maße gerade. Nie hochskalieren.) |
| Bildrate | 60, 30, 24, 15, 10 fps |
| Qualität | Hoch, Mittel, Klein |
| Codec | HEVC (kleiner), H.264 (läuft überall) |
| Mauszeiger | an / aus |
| Klicks hervorheben | an / aus |
| Ton | Systemton an/aus, Mikrofon an/aus (das Mikrofon-**Gerät** ist global, siehe §10) |
| Ausgabe | Video (MP4) oder GIF |

**Mitgelieferte Profile** (änderbar; Standard: „Meeting“)

| Profil | Auflösung | fps | Qualität | Codec | Ton | Ausgabe |
|---|---|---|---|---|---|---|
| Meeting | 1080p | 24 | Mittel | HEVC | System + Mikro | MP4 |
| Präsentation | 1080p | 15 | Mittel | HEVC | Mikro | MP4 |
| Demo (scharf) | Original | 60 | Hoch | HEVC | aus | MP4 |
| GIF | 480p | 10 | Klein | H.264 | aus | GIF |

**Bitrate (Video)** = Breite × Höhe × fps × Faktor:

| Qualität | H.264 | HEVC |
|---|---|---|
| Hoch | 0,10 | 0,06 |
| Mittel | 0,06 | 0,036 |
| Klein | 0,035 | 0,021 |

Die Bitrate ist auf 0,25–40 Mbit/s begrenzt und wird an `AVVideoAverageBitRateKey` übergeben. Ton: AAC 128 kbit/s stereo, 48 kHz.

**Größenschätzung** = (Video-Bitrate + Ton-Bitrate) × 60 s / 8, angezeigt als „≈ 45 MB/min · ≈ 2,6 GB/h“.

Die Maße beziehen sich auf die gewählte Quelle: Bereich in Pixeln, Fenstergröße bzw. Bildschirm in nativer Auflösung. Vor der Auswahl rechnet die Leiste mit dem Bildschirm unter dem Zeiger; nach der Auswahl wird die Schätzung mit den echten Maßen aktualisiert.

Bildschirminhalte sind meist statisch, deshalb liegt die tatsächliche Größe oft **unter** der Schätzung. Das ist gewollt: Die Schätzung ist eine Obergrenze-Richtung und wird nie deutlich überschritten.

Für GIF zeigt die Schätzung „≈ x MB pro 10 s“ und beruht auf einem Erfahrungswert pro Pixel und Bild.

Während der Aufnahme zeigt das Menü die aktuelle Dateigröße.

**Was gilt wann** *(Entwickler-Entscheidung)*
- Das gewählte Profil liefert alle Werte.
- Ton-Schalter und Schnelländerungen in der Leiste gelten nur für die nächste Aufnahme.
- `lastRecordingSetup` merkt sich Modus, Profil-ID und die beiden Ton-Schalter. Beim nächsten Öffnen der Leiste sind sie wieder so gesetzt.
- Wechselt man das Profil, übernehmen die Schalter die Werte des neuen Profils.
- Schnelländerungen an Auflösung, fps, Qualität und Codec werden nicht gemerkt, außer mit „Als Profil sichern“.
- Das Mikrofon-Gerät ist eine einzige globale Einstellung (`microphoneDeviceID`), nicht pro Profil.

## 7. Aufnahme-Pipeline (Core-Teil testbar)

```
SCStream ─┬─ .screen      CMSampleBuffer (BGRA, bereits auf Zielauflösung skaliert via SCStreamConfiguration.width/height)
          ├─ .audio       Systemton
          └─ .microphone  Mikrofon
                │
        RecordingSession (App)  ── Pause/Fortsetzen, Status, Fehler
                │
        VideoFileWriter (ScreenXCore)
          · AVAssetWriter, QuickTime-Container (.mov) mit movieFragmentInterval = 10 s (absturzsicher)
          · 1 Videospur + bis zu 2 Tonspuren (System, Mikro)
          · Zeitstempel: erster Video-Frame = 0; Pausen werden herausgerechnet (Offset-Summe)
          · verwirft Audio vor dem ersten Video-Frame
                │
        Fertigstellen (ScreenXCore)
          · Umschreiben in die endgültige .mp4 (Video Passthrough); dabei bei 2 Tonspuren Mischen zu 1 Spur
            (AVAssetReader + AVAssetReaderAudioMixOutput → AAC). Erst danach wird die .mov gelöscht.
            Schlägt das fehl, bleibt die .mov (abspielbar, ggf. 2 Tonspuren) mit Hinweis erhalten.
          · GIF-Profil: Umwandlung (§9), Zwischen-Video danach gelöscht
```

- **Skalierung** übernimmt ScreenCaptureKit (`width`/`height`, `scalesToFit`). `minimumFrameInterval` = 1/fps.
- **Statische Bildschirme:** SCStream liefert bei unverändertem Inhalt keine neuen Frames. Der Writer schreibt nur, was kommt; Player halten das letzte Bild. Am Ende wird der letzte Frame bis zum Stoppzeitpunkt verlängert (Session-Ende = Stoppzeit), damit die Dauer stimmt.
- **Mauszeiger:** `showsCursor`.
- **Ausschluss:** Alle ScreenX-Fenster (Leiste, Rahmen, Countdown, Vorschaukarten, Klick-Kreise siehe unten) werden über `SCContentFilter` ausgeschlossen. Ausnahme: Klick-Kreise **sollen** ins Video und werden deshalb nicht ausgeschlossen.
- **Klicks hervorheben** (nur Bereich- und Bildschirm-Modus; im Fenster-Modus ist die Option ausgegraut mit Hinweis, weil die Fensteraufnahme nur das Fenster selbst enthält): globaler Maus-Monitor (`NSEvent.addGlobalMonitorForEvents`, Linksklick). Ein transparentes, klickdurchlässiges Fenster zeigt an der Klickstelle einen kurzen Kreis (≈ 0,4 s, halbtransparent). Er ist auch auf dem Bildschirm sichtbar und erscheint so im Video. Es wird kein Frame nachbearbeitet. Technisch: ein dauerhaft geöffnetes Overlay-Fenster pro Bildschirm, das im Filter über `exceptingWindows` ausdrücklich eingeschlossen wird.
- **Mitteilungen ausblenden** (Option, Standard an für Bildschirm-Modus): `com.apple.notificationcenterui` wird ausgeschlossen. Taucht die App erst später in `SCShareableContent` auf (kein Banner beim Start), wird der Filter während der Aufnahme per `updateContentFilter` nachgezogen. Das ist auf macOS 26 zu prüfen und nicht garantiert; im Zweifel steht es so in der Checkliste.
- **Fenster-Modus:** `SCContentFilter(desktopIndependentWindow:)`. Das Fenster wird auch verdeckt oder verschoben aufgenommen. Ändert es die Größe, wird der Inhalt in die festen Zielmaße eingepasst (Letterbox). Minimiert friert das Bild ein, der Ton läuft weiter. Wird das Fenster geschlossen, endet die Aufnahme regulär mit Hinweis.
- **Speicherplatz:** Vor dem Start mindestens 1 GB frei, sonst Warnung mit „Trotzdem starten“. Während der Aufnahme alle 10 s prüfen. Unter 300 MB: Aufnahme sauber beenden und Mitteilung zeigen.
- **Fehler:** Stream- oder Writer-Fehler beenden die Aufnahme, das bis dahin Geschriebene wird fertiggestellt und als Karte gezeigt, dazu eine Fehlermeldung.

**Dateiname:** `ScreenX Aufnahme JJJJ-MM-TT um HH.MM.SS.mp4` bzw. `.gif` im bestehenden Speicherort. Während der Aufnahme heißt die Datei gleich, aber mit `.mov`.

**Wiederherstellen nach Absturz** *(Entwickler-Entscheidung)*: Beim Start sucht ScreenX im Speicherort nach übrig gebliebenen `ScreenX Aufnahme … .mov` ohne zugehörige `.mp4`. Gefundene Dateien bietet es per Mitteilung an: „Unvollständige Aufnahme gefunden – fertigstellen?“. Fertigstellen läuft wie oben.

**Mikrofon-Berechtigung:** Zusätzlich zu `NSMicrophoneUsageDescription` braucht die App das Hardened-Runtime-Entitlement `com.apple.security.device.audio-input`. Die App bekommt dafür eine `.entitlements`-Datei.

## 8. Oberflächen

Alle neuen Oberflächen werden vorab in Figma gestaltet (Seite „M5 Video“) und folgen dem Stil von M1–M4 (Systemmaterialien, SF Symbols, deutsche Texte).

1. **Aufnahme-Leiste** (schwebendes Panel, unten mittig auf dem Bildschirm unter dem Zeiger)
   - Segmente Bereich / Fenster / Bildschirm
   - Profil-Menü mit „Profile bearbeiten …“
   - Mikrofon-Schalter mit Gerätemenü, Systemton-Schalter
   - Größenschätzung
   - „Aufnehmen“ (↩), Schließen (Esc)
   - Ein Klick auf die Schätzung klappt die Profildetails zum schnellen Anpassen aus: Auflösung, fps, Qualität, Codec. Solche Änderungen gelten nur für diese Aufnahme, außer man wählt „Als Profil sichern“.
2. **Countdown** – großer, halbtransparenter Kreis mit Zahl in der Mitte des Aufnahmebereichs.
3. **Aufnahmerahmen** (Bereichsmodus) – gestrichelte Linie außen um den Bereich.
4. **Menüleiste während der Aufnahme** – das Symbol wird zu rotem Punkt + Laufzeit. Das Menü enthält Stopp (⌥⇧6), Pause/Fortsetzen, Verwerfen (mit Rückfrage) und eine Infozeile „1080p · 24 fps · 312 MB“. In der Pause blinkt die Laufzeit.
5. **Vorschaukarte Video** – Vorschaubild, Dauer-Badge, Größe. Beim Überfahren erscheinen Öffnen, Kürzen, Im Finder, Löschen. Herausziehen ergibt die Datei. Gleiche Stapel- und Ausblendlogik wie Screenshots.
6. **Kürzen-Fenster** – `AVPlayerView` im Trim-Modus. Die Trim-Leiste bringt eigene Knöpfe „Kürzen/Abbrechen“ mit; erst nach Bestätigen steht der Bereich fest. Danach zeigt das Fenster die Leiste aus dem Figma-Entwurf mit Bereich, Größe, dazu „Sichern“ (neue Datei „… gekürzt.mp4“, Option „Original ersetzen“) und „Als GIF …“. Letzteres öffnet ein Blatt mit Breite, fps und Größenschätzung.
7. **Einstellungen → neuer Reiter „Video“**
   - Standardprofil, Profilliste (anlegen, bearbeiten, duplizieren, löschen, mitgelieferte zurücksetzen)
   - Countdown, Mitteilungen ausblenden, Mikrofon-Standardgerät
   - Kürzel „Video aufnehmen“ (Standard ⌥⇧6)

## 9. GIF

- **Quelle:** gesamtes Video oder gekürzter Ausschnitt.
- **Optionen:** Breite (Original / 800 / 640 / 480 / 320), fps (15 / 10 / 8), Endlosschleife an.
- **Kürzen-Genauigkeit:** Passthrough schneidet an Keyframes. Der Writer setzt deshalb ein maximales Keyframe-Intervall von 2 s (`AVVideoMaxKeyFrameIntervalDurationKey`), damit Schnitte nah an der gewählten Stelle liegen.
- **Umwandlung:**
  - Bilder per `AVAssetImageGenerator` in festen Abständen (Toleranz 0)
  - `CGImageDestination` (`UTType.gif`) mit `kCGImagePropertyGIFUnclampedDelayTime`; Rundung auf 1/100 s wird über den Clip ausgeglichen, damit die Gesamtdauer stimmt
  - im Hintergrund, mit Fortschritt und abbrechbar
- **Warnung**, wenn die Schätzung über 25 MB liegt („GIF wird groß – kürzer, kleiner oder als Video teilen?“).

## 10. Einstellungen und Daten

- **`AppSettings`** bekommt tolerant dekodierte Felder:
  - `videoHotkey`
  - `recordingProfiles`
  - `defaultProfileID`
  - `countdown`
  - `hideNotifications`
  - `microphoneDeviceID`
  - `lastRecordingSetup`: Modus, Profil, Ton-Schalter

  Alte Einstellungen laden unverändert.
- **`RecordingProfile`** (Codable, Sendable) liegt in ScreenXCore, mitsamt der Bitraten- und Größenrechnung.
- Keine Projektdatei für Videos; die Ausgabe ist eine normale MP4- oder GIF-Datei.

## 11. Fehlerbehandlung

| Fall | Verhalten |
|---|---|
| Keine Bildschirm-Freigabe | vorhandenes Hinweisfenster |
| Mikrofon verweigert | Mikrofon-Schalter aus, Hinweis mit Link zu Systemeinstellungen; Aufnahme ohne Mikro möglich |
| Speicher knapp | siehe §7 |
| Stream bricht ab (z. B. Bildschirm abgesteckt, Fenster geschlossen) | Aufnahme beenden und fertigstellen, Mitteilung |
| Mischen schlägt fehl | Datei mit 2 Tonspuren behalten, Hinweis |
| App-Absturz | fragmentierte MP4 bleibt bis zum letzten Fragment (≤ 10 s Verlust) abspielbar |
| Zweite Aufnahme während einer laufenden | nicht möglich; ⌥⇧6 stoppt die laufende |
| Screenshot-Kürzel während der Aufnahme | funktionieren weiter |

## 12. Testen

- **ScreenXCore** (CI):
  - Profil-Rechnung: Maße, gerade Werte, kein Hochskalieren, Bitrate-Grenzen, Schätzung
  - Profile- und Settings-Kodierung, tolerantes Laden
  - Zeitstempel- und Pause-Logik als reine Funktion
  - `VideoFileWriter` mit synthetischen Bildern und synthetischem Ton: Datei abspielbar, Dauer, Maße, Codec, Bitrate ungefähr, Pause ohne Lücke, letzter Frame verlängert
  - Ton-Mischen und Umschreiben .mov → .mp4
  - HEVC-Tests dürfen auf CI übersprungen werden, wenn kein Hardware-Encoder da ist (CI-Runner sind VMs); H.264-Pfad wird immer getestet
  - Kürzen (Passthrough-Bereich)
  - GIF-Umwandlung: Bildzahl, Verzögerung, Maße
- **Manuell (Mac):** Checkliste `docs/checklists/M5.md`
  - 1-h-Meeting (Zoom/Teams/Meet) mit Ton beider Seiten
  - Synchronität am Ende prüfen
  - Fenster verdecken, minimieren, schließen
  - Pause, Absturz (Prozess beenden), voller Speicher simulieren
  - Größe gegen Schätzung vergleichen

## 13. Dem Entwickler überlassen

- genaue Aufteilung in Tasks und Dateien
- Implementierung der Zeitstempel-Synchronisation, solange §1-Kriterien erfüllt sind
- Darstellung der Größenschätzung im Detail (gemäß Figma)
- Erfahrungswert pro Pixel für die GIF-Schätzung (aus Tests ableiten)
