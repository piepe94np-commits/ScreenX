# M5 – Bildschirmaufnahme (Video & GIF): Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ScreenX nimmt Bereich, Fenster oder Bildschirm als Video auf, mit System- und Mikrofonton. Auflösung, Bildrate, Qualität und Codec stehen vorher fest, ebenso eine Größenschätzung. Danach gibt es eine Vorschaukarte, schlichtes Kürzen und einen GIF-Export.

**Architecture:**
- **ScreenXCore** enthält alles Testbare ohne Bildschirm:
  - Profile und Größenrechnung
  - Zeitachse mit Pausen
  - `VideoFileWriter` (AVAssetWriter, fragmentierte `.mov`)
  - Fertigstellen (`.mov` → `.mp4` mit Ton-Mischung)
  - Kürzen-Export
  - GIF-Kodierung
- **Die App** steuert ScreenCaptureKit-Streams (Bild, Systemton, Mikrofon; im Fenster-Modus ein zweiter reiner Ton-Stream) und speist den Writer. Dazu kommen die Oberflächen nach Figma: Leiste, Countdown, Rahmen, Klick-Kreise, Menüleistenzustand, Videokarte, Kürzen-Fenster, Einstellungen „Video“.

**Tech Stack:** Swift 6, ScreenCaptureKit (`SCStream`), AVFoundation (`AVAssetWriter`, `AVAssetReader`, `AVAssetExportSession`, `AVPlayerView`), ImageIO, SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-23-screen-recording-design.md` (freigegeben). Figma: https://www.figma.com/design/Yhkpngu3GZy7vxFyyeS2fM?node-id=13-2 (8 Rahmen). Grundlage: `docs/superpowers/specs/2026-11-03-screenx-design.md`.

## Global Constraints

- Es gelten alle Constraints von M1–M4:
  - macOS 26, Swift 6 mit strikter Concurrency, keine Abhängigkeiten
  - deutsche Texte im String Catalog `ScreenX/Resources/Localizable.xcstrings`
  - Verifikation über die CI, `.superpowers/` nie committen
  - neue Core-Typen sind `public` und, wo möglich, `Sendable`
- Kürzel „Video aufnehmen“: Standard **⌥⇧6**. Ein erneuter Druck während der Aufnahme stoppt sie. Die Screenshot-Kürzel ⌥⇧3/4/5 funktionieren auch während der Aufnahme.
- Auflösungsstufen begrenzen die **längere** Seite:
  - Original: keine Grenze
  - 1440p: 2560
  - 1080p: 1920
  - 720p: 1280
  - 480p: 854

  Das Seitenverhältnis bleibt, Breite und Höhe werden gerade gerundet, es wird nie hochskaliert.
- Bildraten: 60, 30, 24, 15, 10 fps. Qualität: Hoch, Mittel, Klein. Codec: HEVC, H.264.
- Bitrate = B × H × fps × Faktor:

  | Qualität | H.264 | HEVC |
  |---|---|---|
  | Hoch | 0,10 | 0,06 |
  | Mittel | 0,06 | 0,036 |
  | Klein | 0,035 | 0,021 |

  Die Bitrate wird auf 250 000…40 000 000 bit/s begrenzt.
- Ton: AAC, 128 000 bit/s, stereo, 48 kHz.
- Schätzung: MB/min = (Video-Bitrate + Ton-Bitrate × Anzahl aktiver Tonquellen nach dem Mischen, also 1, wenn Ton an ist) × 60 / 8 / 1 000 000. Anzeige „≈ 38 MB/min · ≈ 2,3 GB/h“ mit deutschem Dezimalkomma.
- Mitgelieferte Profile:

  | ID | Name | Auflösung | fps | Qualität | Codec | Systemton | Mikro | Ausgabe |
  |---|---|---|---|---|---|---|---|---|
  | `meeting` | Meeting | 1080p | 24 | Mittel | HEVC | an | an | Video |
  | `presentation` | Präsentation | 1080p | 15 | Mittel | HEVC | aus | an | Video |
  | `demo` | Demo (scharf) | Original | 60 | Hoch | HEVC | aus | aus | Video |
  | `gif` | GIF | 480p | 10 | Klein | H.264 | aus | aus | GIF |

  Der Standard ist `meeting`. Mauszeiger ist überall an, Klicks hervorheben überall aus.
- Aufnahmedatei: `ScreenX Aufnahme JJJJ-MM-TT um HH.MM.SS.mov` während der Aufnahme, fertig `.mp4` bzw. `.gif`, im bestehenden Speicherort.
  - `movieFragmentInterval` 10 s
  - maximales Keyframe-Intervall 2 s
- Speicherplatz:
  - Unter 1 GB frei: Warnung vor dem Start mit „Trotzdem starten“.
  - Während der Aufnahme alle 10 s prüfen. Unter 300 MB frei: sauber beenden.
- Countdown: aus, 3 s (Standard) oder 5 s. Esc bricht ab.
- GIF:
  - Breite: Original, 800, 640, 480, 320
  - fps: 15, 10, 8
  - Endlosschleife: an
  - Warnung ab einer Schätzung über 25 MB
- Kürzen speichert als `… gekürzt.mp4`. Die Option „Original ersetzen“ ist standardmäßig aus.
- Entitlement `com.apple.security.device.audio-input`, dazu `NSMicrophoneUsageDescription` mit dem Text „ScreenX nimmt bei Videoaufnahmen auf Wunsch dein Mikrofon auf.“
- Alle ScreenX-Fenster sind vom Video ausgeschlossen. Ausnahme: die Klick-Kreis-Fenster.

## Review Focus

1. **Lange Aufnahme mit Pausen:** Bild und Ton bleiben synchron. Pausen erzeugen keine Lücke und kein eingefrorenes Bild. Die Dauer entspricht der Summe der aktiven Abschnitte. → Test `pausesLeaveNoGapAndKeepAudioInSync` (Task 3) und `writerPauseResume` (Task 4).
2. **Abbruch mitten in der Aufnahme** (App beendet, ohne `finishWriting`): Die `.mov` ist bis zum letzten Fragment lesbar, und das Fertigstellen macht daraus eine `.mp4`. → Test `unfinishedMovIsReadableAndFinalizes` (Task 5).
3. **Statischer Bildschirm** (minutenlang keine neuen Frames): Die Videodauer reicht trotzdem bis zum Stoppzeitpunkt. → Test `lastFrameHeldUntilStop` (Task 4).
4. **Ungerade oder winzige Quellmaße** (z. B. ein Bereich von 301×7 px, ein Fenster schmaler als die Stufe): Die Maße werden gerade, mindestens 2×2 und nie größer als die Quelle. → Test `targetSizeEvenNeverUpscaledMinimum` (Task 1).
5. **Ein Ton-Stream liefert früher oder später als das Bild** (Systemton vor dem ersten Frame, Mikro mit Versatz): Ton vor dem ersten Video-Frame wird verworfen, der Rest landet an der richtigen Zeit. → Test `audioBeforeFirstFrameDroppedAndAligned` (Task 3).

---

### Task 1: Aufnahmeprofile und Größenrechnung

**Files:**
- Create: `ScreenXCore/Recording/RecordingProfile.swift`, `ScreenXCore/Recording/RecordingEstimate.swift`
- Test: `ScreenXCoreTests/RecordingProfileTests.swift`

**Interfaces:**
- Produces:
  - `public enum VideoResolution: String, Codable, CaseIterable, Sendable { case original, p1440, p1080, p720, p480; var maxLongSide: Int? }`
  - `public enum VideoQuality: String, Codable, CaseIterable, Sendable { case high, medium, small }`
  - `public enum VideoCodec: String, Codable, CaseIterable, Sendable { case hevc, h264 }`
  - `public enum RecordingOutput: String, Codable, Sendable { case video, gif }`
  - `public struct RecordingProfile: Codable, Hashable, Sendable, Identifiable` mit diesen Feldern: `id: String`, `name: String`, `resolution`, `fps: Int`, `quality`, `codec`, `showsCursor: Bool`, `highlightClicks: Bool`, `systemAudio: Bool`, `microphone: Bool`, `output: RecordingOutput`.
    - Tolerantes `init(from:)`: fehlende Felder bekommen Standardwerte. Ein ungültiger `fps`-Wert wird auf den nächsten erlaubten Wert gesetzt.
    - `static let builtins: [RecordingProfile]` und `static let defaultID = "meeting"`.
  - `public enum RecordingEstimate` mit:
    - `static func targetSize(source: CGSize, resolution: VideoResolution) -> CGSize`
    - `static func videoBitrate(size: CGSize, fps: Int, quality: VideoQuality, codec: VideoCodec) -> Int`
    - `static func megabytesPerMinute(profile: RecordingProfile, source: CGSize) -> Double`
    - `static func text(megabytesPerMinute: Double) -> String`, liefert z. B. „≈ 38 MB/min · ≈ 2,3 GB/h“
    - `static func gifMegabytes(size: CGSize, fps: Int, seconds: Double) -> Double`, Erfahrungswert 0,08 Byte pro Pixel und Bild; der Wert darf nach den Tests in Task 6 angepasst werden

- [ ] **Step 1: Failing Tests.**
  - `builtinsMatchSpec`: vier Profile mit den IDs und Werten aus den Global Constraints; `defaultID == "meeting"`.
  - `targetSizeEvenNeverUpscaledMinimum`:
    - 2940×1912 bei p1080 → 1920×1248. Die Höhe 1248,65 wird auf eine gerade Zahl abgerundet.
    - 1000×600 bei p1080 → 1000×600, also nicht hochskaliert.
    - 301×7 bei original → 300×6.
    - 1×1 → 2×2.
    - 1912×2940 (hochkant) bei p720 → 832×1280, die längere Seite ist begrenzt.
  - `bitrateFormulaAndClamp`:
    - 1920×1080, 24 fps, medium, hevc → 1 791 590 (±1).
    - 7680×4320, 60 fps, high, h264 → 40 000 000.
    - 320×240, 10 fps, small, hevc → 250 000.
  - `estimateText`: 38,2 → „≈ 38 MB/min · ≈ 2,3 GB/h“; 0,4 → „≈ 0,4 MB/min · ≈ 24 MB/h“.
  - `estimateIncludesAudioOnce`: Meeting-Profil, Quelle 1920×1080. Ergebnis = (1 791 590 + 128 000) × 60 / 8 / 1e6 ≈ 14,4.
  - `profileTolerantDecoding`: `{"id":"x","name":"X"}` dekodiert mit Standardwerten; `"fps":25` wird zu 24.
- [ ] **Step 2: Tests laufen lassen.** Erwartet: FAIL.
- [ ] **Step 3: Implementieren.** Rundung auf gerade Werte: `max(2, Int(v / 2) * 2)` nach der Skalierung.
- [ ] **Step 4: Tests laufen lassen.** Erwartet: PASS.
- [ ] **Step 5: Commit.** `feat(core): recording profiles and size estimate`

### Task 2: Einstellungen für Video

**Files:**
- Modify: `ScreenXCore/Settings/AppSettings.swift`
- Create: `ScreenXCore/Recording/RecordingSetup.swift`
- Test: `ScreenXCoreTests/VideoSettingsTests.swift`

**Interfaces:**
- Consumes: `RecordingProfile` (Task 1), `CaptureMode`, `KeyCombo`
- Produces:
  - `public enum CountdownSetting: Int, Codable, CaseIterable, Sendable { case off = 0, three = 3, five = 5 }`
  - `public struct RecordingSetup: Codable, Hashable, Sendable { mode: CaptureMode; profileID: String; systemAudio: Bool; microphone: Bool }`
  - Neue Felder in `AppSettings`, alle tolerant mit `decodeIfPresent` dekodiert:
    - `videoHotkey: KeyCombo?`, Standard ⌥⇧6
    - `recordingProfiles: [RecordingProfile]`, Standard `builtins`
    - `defaultProfileID: String`
    - `countdown: CountdownSetting`, Standard `.three`
    - `hideNotifications: Bool`, Standard `true`
    - `microphoneDeviceID: String?`
    - `lastRecordingSetup: RecordingSetup?`
  - `func profile(id: String) -> RecordingProfile`: liefert das gefundene Profil, sonst das Standardprofil, sonst `builtins[0]`.
  - `func setup(applying profile: RecordingProfile, mode: CaptureMode) -> RecordingSetup`: Profilwechsel; die Ton-Schalter kommen aus dem Profil.

- [ ] **Step 1: Failing Tests.**
  - `decodesPreM5Settings`: Settings-JSON aus M4 ohne Video-Felder ergibt die Standardwerte aus den Interfaces; die bestehenden Felder bleiben unverändert.
  - `videoSettingsRoundTrip`
  - `profileLookupFallsBack`: unbekannte ID → Standardprofil; leere Profilliste → `builtins[0]`.
  - `lossyProfileList`: ein kaputtes Profil in der Liste lässt die anderen stehen.
  - `profileSwitchResetsAudioToggles`
- [ ] **Step 2–4:** RED → Implementieren → GREEN, alle bisherigen Settings-Tests grün.
- [ ] **Step 5: Commit.** `feat(core): video recording settings`

### Task 3: Aufnahme-Zeitachse (Pausen und Synchronisation)

**Files:**
- Create: `ScreenXCore/Recording/RecordingTimeline.swift`
- Test: `ScreenXCoreTests/RecordingTimelineTests.swift`

**Interfaces:**
- Produces: `public struct RecordingTimeline: Sendable`, eine reine Zeitrechnung auf `CMTime` in Host-Zeit:
  - `mutating func video(at hostTime: CMTime) -> CMTime?`
    - Der erste Aufruf setzt den Ursprung.
    - Liefert die Ausgabezeit, oder `nil` während einer Pause.
  - `mutating func audio(at hostTime: CMTime, duration: CMTime) -> CMTime?`
    - `nil` vor dem ersten Video-Frame und während einer Pause.
    - Ein Puffer, der die Pausengrenze schneidet, wird ganz verworfen.
  - `mutating func pause(at hostTime: CMTime)`, `mutating func resume(at hostTime: CMTime)`
  - `func outputTime(forStopAt hostTime: CMTime) -> CMTime`: das Session-Ende, damit der letzte Frame bis zum Stopp gehalten wird.
  - `var isPaused: Bool`, `var activeDuration: CMTime`

- [ ] **Step 1: Failing Tests.**
  - `firstVideoFrameIsZero`
  - `pausesLeaveNoGapAndKeepAudioInSync`:
    - Ablauf: Video ab Sekunde 10. Pause bei 12, Fortsetzen bei 20, Stopp bei 23.
    - Erwartet:
      - Ein Frame bei 21 liefert 3 s.
      - Ton bei 21 liefert 3 s.
      - Ein Frame bei 15 liefert `nil`.
      - `outputTime(forStopAt: 23)` liefert 5 s.
  - `audioBeforeFirstFrameDroppedAndAligned`:
    - Ton bei 9,5 liefert `nil`.
    - Mikro bei 10,04 liefert 0,04 s.
  - `multiplePauses`: zwei Pausen, die Offsets summieren sich.
  - `pauseWhilePausedIsNoOp`
- [ ] **Step 2–4:** RED → Implementieren → GREEN.
- [ ] **Step 5: Commit.** `feat(core): recording timeline with pause`

### Task 4: VideoFileWriter

**Files:**
- Create: `ScreenXCore/Recording/VideoFileWriter.swift`, `ScreenXCore/Recording/VideoWriterSettings.swift`
- Test: `ScreenXCoreTests/VideoFileWriterTests.swift`, mit einem Hilfsmittel für synthetische Puffer in `ScreenXCoreTests/Support/SyntheticMedia.swift`

**Interfaces:**
- Consumes: `RecordingProfile`, `RecordingEstimate.videoBitrate`, `RecordingTimeline`
- Produces:
  - `public struct VideoWriterSettings: Sendable { size: CGSize; fps: Int; codec: VideoCodec; bitrate: Int; audioTracks: Int /* 0…2 */ }` mit `init(profile:targetSize:)`.
    - `audioTracks` = Systemton + Mikro.
    - Keyframe-Intervall 2 s, Erwartungswert der Bildrate = `fps`.
  - `public final class VideoFileWriter: @unchecked Sendable` (serielle Queue intern):
    - `init(url: URL, settings: VideoWriterSettings) throws`. Erzeugt eine `.mov` mit `movieFragmentInterval` 10 s und `shouldOptimizeForNetworkUse = false`.
    - `func appendVideo(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime)`
    - `func appendAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrackKind)`; `public enum AudioTrackKind: Sendable { case system, microphone }`. Der Zeitstempel wird über die Zeitachse umgerechnet.
    - `func pause(at:)`, `func resume(at:)`
    - `var bytesWritten: Int64` (Dateigröße)
    - `func finish(stopAt hostTime: CMTime) async throws -> URL`. Setzt das Session-Ende auf `outputTime(forStopAt:)`.
    - `public enum VideoWriterError: Error { case cannotCreate, writerFailed(String) }`. Der deutsche `LocalizedError`-Text kommt in den Catalog.

- [ ] **Step 1: Failing Tests.** Alle arbeiten mit synthetischen BGRA-Frames (Farbwechsel pro Sekunde) und einem Sinuston in 1024er-Blöcken bei 48 kHz.
  - `writesPlayableMovH264`: 3 s, 30 fps, 640×360. Prüfungen per `AVURLAsset`:
    - Dauer ≈ 3 s (±0,1)
    - Videospur 640×360, Codec `avc1`
    - eine AAC-Tonspur
  - `writesHEVC`: wie oben mit Codec `hvc1`. Mit `.enabled(if:)` überspringen, wenn kein HEVC-Hardware-Encoder verfügbar ist (`VTIsHardwareDecodeSupported`/Encoder-Check).
  - `writerPauseResume`: 2 s aufnehmen, 5 s Pause, 2 s aufnehmen. Dauer ≈ 4 s; das Bild bei 2,5 s ist die Farbe nach dem Fortsetzen.
  - `lastFrameHeldUntilStop`: Frames nur von 0 bis 1 s, Stopp bei 4 s. Dauer ≈ 4 s.
  - `twoAudioTracks`: System und Mikro ergeben 2 Tonspuren.
  - `bitrateRoughlyRespected`: 10 s Rauschbild bei 640×360/30/medium/h264. Dateigröße ≤ 1,5 × Schätzung.
- [ ] **Step 2–4:** RED → Implementieren → GREEN.
  - Ton-Eingaben mit `expectsMediaDataInRealTime = true`.
  - Puffer verwerfen, wenn `isReadyForMoreMediaData` false ist, und mitzählen.
- [ ] **Step 5: Commit.** `feat(core): fragmented video file writer`

### Task 5: Fertigstellen und Wiederherstellen

**Files:**
- Create: `ScreenXCore/Recording/RecordingFinalizer.swift`
- Test: `ScreenXCoreTests/RecordingFinalizerTests.swift`

**Interfaces:**
- Consumes: Ausgabe von `VideoFileWriter`
- Produces: `public enum RecordingFinalizer`:
  - `static func finalize(mov: URL) async throws -> URL`
    - Schreibt die `.mp4` daneben: Video als Passthrough, Ton aus allen Spuren gemischt zu einer AAC-Spur mit 128 kbit/s (`AVAssetReaderAudioMixOutput`).
    - Löscht die `.mov` erst nach Erfolg. Im Fehlerfall bleibt sie erhalten, und der Fehler wird geworfen.
  - `static func leftovers(in directory: URL) -> [URL]`: `ScreenX Aufnahme *.mov` ohne gleichnamige `.mp4`.
  - `static func finalURL(for mov: URL) -> URL`

- [ ] **Step 1: Failing Tests.**
  - `finalizeMixesTwoTracks`: `.mov` mit 2 Tonspuren ergibt eine `.mp4` mit 1 Tonspur und gleicher Dauer (±0,1 s); die `.mov` ist gelöscht.
  - `finalizeVideoOnly`: ohne Ton ergibt eine `.mp4` ohne Tonspur.
  - `unfinishedMovIsReadableAndFinalizes`:
    - Writer 25 s schreiben lassen und nie `finish` aufrufen; das Writer-Objekt wird verworfen.
    - Danach ist die `.mov` als Asset lesbar, mit einer Dauer von mindestens 20 s.
    - `finalize` liefert eine `.mp4`.
  - `leftoversFound`: Verzeichnis mit einem `.mov`/`.mp4`-Paar und einer einzelnen `.mov` → nur die einzelne.
  - `failedFinalizeKeepsMov`: eine kaputte Datei wirft einen Fehler, und die `.mov` bleibt erhalten.
- [ ] **Step 2–4:** RED → Implementieren → GREEN.
- [ ] **Step 5: Commit.** `feat(core): finalize recordings to mp4 and find leftovers`

### Task 6: Kürzen-Export und GIF

**Files:**
- Create: `ScreenXCore/Recording/TrimExporter.swift`, `ScreenXCore/Recording/GIFEncoder.swift`
- Test: `ScreenXCoreTests/TrimAndGIFTests.swift`

**Interfaces:**
- Produces:
  - `public enum TrimExporter`:
    - `static func export(source: URL, range: CMTimeRange, to destination: URL) async throws`: Passthrough-Export mit `AVAssetExportSession`.
    - `static func trimmedURL(for source: URL) -> URL`: liefert „… gekürzt.mp4“, bei Kollision mit Zähler „… gekürzt 2.mp4“.
  - `public struct GIFOptions: Sendable { width: Int?; fps: Int; loops: Bool }`, wobei `width == nil` das Original bedeutet.
  - `public enum GIFEncoder`:
    - `static func encode(source: URL, range: CMTimeRange?, options: GIFOptions, to destination: URL, progress: @Sendable (Double) -> Void) async throws`
      - Bilder über `AVAssetImageGenerator` (Toleranz 0)
      - `CGImageDestination` mit `UTType.gif`
      - Verzögerung über `kCGImagePropertyGIFUnclampedDelayTime`, Rundung auf 1/100 s mit Fehlerausgleich
      - abbrechbar über Task-Cancellation; beim Abbruch wird die Datei gelöscht
    - `static func frameDelays(fps: Int, count: Int) -> [Double]`: rein; die Summe ist auf 1/100 s genau gleich count/fps.

- [ ] **Step 1: Failing Tests.**
  - `trimKeepsRangeApprox`: Ein 10-s-Video mit Keyframes alle 2 s, gekürzt auf 2…6 s. Ergebnisdauer 4 s (±0,6 s wegen der Keyframes).
  - `trimmedURLCounter`
  - `gifFrameCountAndSize`: 3-s-Video mit 10 fps und Breite 320. Ergebnis: 30 Bilder, Breite 320, Endlosschleife (`LoopCount` 0).
  - `frameDelaysSumExact`: fps 15, 45 Bilder. Jede Verzögerung ist 0,06 oder 0,07, die Summe 3,00.
  - `gifCancelDeletesFile`
  - `gifEstimateWithinFactor2`: `RecordingEstimate.gifMegabytes` liegt beim Testclip innerhalb von Faktor 2 der echten Größe. Bei Bedarf wird der Erfahrungswert aus Task 1 angepasst und im Bericht vermerkt.
- [ ] **Step 2–4:** RED → Implementieren → GREEN.
- [ ] **Step 5: Commit.** `feat(core): trim export and gif encoder`

### Task 7: Aufnahme-Motor in der App (ScreenCaptureKit → Writer)

**Files:**
- Create: `ScreenX/Recording/RecordingEngine.swift`, `ScreenX/Recording/RecordingTarget.swift`, `ScreenX/Recording/MicrophonePermission.swift`, `ScreenX/Resources/ScreenX.entitlements`
- Modify: `project.yml` (`CODE_SIGN_ENTITLEMENTS`), `ScreenX/Resources/Info.plist` (`NSMicrophoneUsageDescription`), `ScreenX/Capture/CaptureService.swift`. Letztere Datei bekommt nur eine Hilfsfunktion für den Filter, der ScreenX ausschließt, falls sie dort schon steckt.

**Interfaces:**
- Consumes: `VideoFileWriter`, `VideoWriterSettings`, `RecordingFinalizer`, `RecordingProfile`, `RecordingEstimate.targetSize`
- Produces:
  - `enum RecordingTarget: Sendable { case display(CGDirectDisplayID), area(CGDirectDisplayID, CGRect /* Punkte, oben links */), window(CGWindowID) }`
  - `@MainActor final class RecordingEngine`:
    - `init(settings: @escaping () -> AppSettings)`
    - `func start(target: RecordingTarget, profile: RecordingProfile, systemAudio: Bool, microphone: Bool, includedWindowIDs: [CGWindowID]) async throws`
      - `includedWindowIDs` sind die Klick-Kreis-Fenster.
    - `func pause()`, `func resume()`, `func stop() async -> RecordingResult`, `func discard() async`
    - `var state: RecordingState`, beobachtbar: `idle`, `recording(started: Date)`, `paused`, `finishing`
    - `var elapsed: TimeInterval`, `var bytesWritten: Int64`
    - `var onAutoStop: ((RecordingStopReason) -> Void)?`
      - `enum RecordingStopReason { case lowDisk, streamEnded(String), writerFailed(String) }`
  - `struct RecordingResult { url: URL; duration: TimeInterval; size: Int64; warnings: [String] }`
- Verhalten nach Spec §7:
  - Bild-Stream: Filter je Modus. ScreenX ist ausgeschlossen außer `includedWindowIDs`. Bei `hideNotifications` im Bildschirm- und Bereichsmodus ist auch `com.apple.notificationcenterui` ausgeschlossen, falls vorhanden.
  - Stream-Einstellungen: `width`/`height` aus `targetSize`, `minimumFrameInterval` = 1/fps, `showsCursor`, `capturesAudio`, `captureMicrophone` und `microphoneCaptureDeviceID` aus den Settings.
  - Bereich: `sourceRect`.
  - Fenster-Modus mit Systemton: zweiter `SCStream` mit Bildschirmfilter ohne ScreenX, nur Ton, Bild 2×2 bei 1 fps, die Bild-Ausgabe wird ignoriert. Fällt er aus, kommt eine Warnung in `RecordingResult.warnings`, die Aufnahme läuft weiter.
  - Frames mit `SCFrameStatus` ungleich `.complete` werden nicht geschrieben.
  - Speicherplatz wie in den Global Constraints. Beim Stopp: `writer.finish`, danach `RecordingFinalizer.finalize`; bei GIF-Ausgabe zusätzlich `GIFEncoder.encode` und die `.mp4` löschen.
- Mikrofon: `MicrophonePermission.request() async -> Bool` über `AVCaptureDevice.requestAccess(for: .audio)`. Bei Ablehnung startet die Aufnahme ohne Mikrofon, mit Warnung.

- [ ] **Step 1: Implementieren.**
- [ ] **Step 2: App-Build in CI.** Erwartet: grün, keine Warnungen; die Entitlements-Datei ist im Build referenziert (im Log prüfen).
- [ ] **Step 3: Commit.** `feat: recording engine with ScreenCaptureKit streams`

### Task 8: Aufnahme-Ablauf und Oberflächen

**Files:**
- Create:
  - `ScreenX/Recording/RecordingBarPanel.swift` (Leiste und ausklappbare Profildetails, Figma-Rahmen 1/1b)
  - `ScreenX/Recording/CountdownWindow.swift`
  - `ScreenX/Recording/RecordingFrameWindow.swift`
  - `ScreenX/Recording/ClickHighlighter.swift`
  - `ScreenX/Recording/RecordingCoordinator.swift`
- Modify:
  - `ScreenX/App/AppCoordinator.swift`
  - `ScreenX/App/MenuBarContent.swift` mit dem Menüleistenzustand (Figma-Rahmen 3)
  - `ScreenX/Hotkeys/HotkeyCenter.swift` für das Video-Kürzel
  - `ScreenX/Capture/OverlayController.swift`: Die Auswahl wird für Video wiederverwendet, z. B. mit einer Variante, die nur das Rechteck bzw. die Fenster-ID zurückgibt und kein Bild aufnimmt.

**Interfaces:**
- Consumes: `RecordingEngine`, `AppSettings` (`lastRecordingSetup`, `profile(id:)`, `setup(applying:mode:)`, `countdown`, `videoHotkey`), `RecordingEstimate`
- Produces:
  - `@MainActor final class RecordingCoordinator`:
    - `func toggle()`: ⌥⇧6 öffnet die Leiste oder stoppt die Aufnahme.
    - `var isRecording: Bool`
    - `var onFinished: ((RecordingResult) -> Void)?` (für Task 9)
  - `OverlayController.selectAreaRect() async throws -> (CGDirectDisplayID, CGRect)?` und `selectWindowID() async throws -> CGWindowID?`
- Ablauf nach Spec §5:
  - Leiste: unten mittig auf dem Bildschirm unter dem Zeiger, nicht aktivierend, ↩ startet, Esc schließt.
  - Profil-Menü mit „Profile bearbeiten …“, das die Einstellungen im Reiter „Video“ öffnet.
  - Schätzung aktualisiert sich live. Ein Klick klappt die Profildetails aus. Schnelländerungen gelten nur für diese Aufnahme; „Als Profil sichern …“ fragt nach einem Namen.
  - Danach kommt die Auswahl je Modus, beim Bildschirm-Modus der Bildschirm unter dem Zeiger.
  - Die Speicherplatz-Warnung erscheint vor dem Countdown.
  - Countdown in der Mitte des Ziels. Rahmen gestrichelt rot, 2 pt, nur im Bereichsmodus.
  - Klick-Kreise: ein klickdurchlässiges Fenster pro Bildschirm. Kreis 36 pt, `#FF3B30` mit 35 % Deckkraft, 0,4 s Ausblenden. Nur bei `highlightClicks` und nicht im Fenster-Modus; dort ist die Option in den Details ausgegraut mit dem Hinweis „Im Fenster-Modus nicht verfügbar“.
  - Menüleiste: roter Punkt mit Laufzeit `mm:ss` bzw. `h:mm:ss`, in der Pause blinkend (1 s). Das Menü folgt Figma-Rahmen 3. „Verwerfen …“ fragt nach. Beim Fertigstellen steht dort „Wird gesichert …“.
  - `lastRecordingSetup` wird beim Start gespeichert.
  - Auto-Stopp zeigt eine Mitteilung mit dem Grund.
- [ ] **Step 1: Implementieren.**
- [ ] **Step 2: App-Build in CI.** Erwartet: grün.
- [ ] **Step 3: Commit.** `feat: recording bar, countdown and menu bar state`

### Task 9: Videokarte, Kürzen-Fenster und Wiederherstellen

**Files:**
- Create: `ScreenX/QuickAccess/VideoQuickAccessItemView.swift`, `ScreenX/Recording/TrimWindow.swift`, `ScreenX/Recording/GIFExportSheet.swift`
- Modify: `ScreenX/QuickAccess/QuickAccessController.swift`. Der Controller bekommt `func show(recording: RecordingResult)`; die bestehende Stapel- und Ausblendlogik wird wiederverwendet. `ScreenX/App/AppCoordinator.swift` sucht beim Start nach Resten.

**Interfaces:**
- Consumes: `RecordingCoordinator.onFinished`, `TrimExporter`, `GIFEncoder`, `GIFOptions`, `RecordingEstimate.gifMegabytes`, `RecordingFinalizer.leftovers/finalize`
- Produces: `@MainActor enum TrimWindow { static func show(url: URL) }`
- Verhalten:
  - **Karte** (Figma-Rahmen 4):
    - Vorschaubild über `AVAssetImageGenerator` bei 1 s, Badge mit Dauer und Größe; GIF-Karten zeigen „GIF · Dauer · Größe“.
    - Beim Überfahren: Öffnen (`NSWorkspace.open`), Kürzen, Im Finder, Löschen. Löschen fragt nicht nach und legt die Datei in den Papierkorb.
    - Herausziehen ergibt die Datei selbst, keine Kopie.
    - GIF-Karten haben kein „Kürzen“.
  - **Kürzen-Fenster** (Figma-Rahmen 5):
    - `AVPlayerView` mit `beginTrimming`.
    - Nach dem Bestätigen erscheint die Leiste mit Bereich, Länge, Größe proportional geschätzt, „Original ersetzen“, „Als GIF …“, „Abbrechen“, „Sichern“.
    - Sichern läuft über `TrimExporter` und zeigt danach eine neue Karte. Mit „Original ersetzen“ wird nach Erfolg das Original in den Papierkorb gelegt und die neue Datei auf den Originalnamen umbenannt.
  - **GIF-Blatt** (Figma-Rahmen 5b): Optionen, Live-Schätzung, Warnung über 25 MB, Fortschritt, Abbrechen; danach eine GIF-Karte.
  - **Wiederherstellen:** Gibt es beim Start Reste, erscheint die Mitteilung „Unvollständige Aufnahme gefunden“ mit „Fertigstellen“ und „Später“. Fertigstellen läuft im Hintergrund und zeigt danach eine Karte.
- [ ] **Step 1: Implementieren.**
- [ ] **Step 2: App-Build in CI.** Erwartet: grün.
- [ ] **Step 3: Commit.** `feat: video quick access, trim window and gif export`

### Task 10: Einstellungen „Video“ und Checkliste

**Files:**
- Create: `ScreenX/Settings/VideoSettingsView.swift`, `docs/checklists/M5.md`
- Modify: `ScreenX/Settings/SettingsView.swift` (neuer Reiter „Video“, Figma-Rahmen 6)

**Interfaces:**
- Consumes: `AppSettings` Video-Felder, `RecordingProfile`, `RecordingEstimate`, `HotkeyRecorderView`
- Verhalten:
  - **Profilliste:** Anlegen, Duplizieren, Löschen (das letzte Profil ist nicht löschbar), „Mitgelieferte zurücksetzen“. Der Stern markiert den Standard, „Als Standard“ im Kontextmenü.
  - **Editor:** alle Profilfelder, Schätzung für 1920×1080.
  - **Allgemein:** Countdown, Mitteilungen ausblenden, Mikrofon-Gerät (`AVCaptureDevice.DiscoverySession` für Audio, „Systemstandard“ = `nil`), Kürzel Video.
  - Kürzel-Konflikte wie bei M1 prüfen.
- **Checkliste M5:** alle Punkte aus Spec §12 „Manuell“, dazu:
  - Ton beider Seiten bei Zoom, Teams und Meet
  - Fenster-Modus mit Systemton: die anderen Teilnehmer sind zu hören
  - Klick-Kreise im Video
  - Mitteilungen ausgeblendet
  - Größe gegenüber der Schätzung bei 10 min 1080p/24
  - Wiederherstellen nach `kill -9`
  - Speicherplatz knapp mit einem Disk-Image
  - Kürzen und GIF
  - Screenshot-Kürzel während der Aufnahme
  - ScreenX-Fenster nie im Video
- [ ] **Step 1: Implementieren.**
- [ ] **Step 2: App-Build in CI.** Erwartet: grün.
- [ ] **Step 3: Commit.** `feat: video settings tab` und `docs: M5 manual test checklist`
