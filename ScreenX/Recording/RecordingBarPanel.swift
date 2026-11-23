import AppKit
import AVFoundation
import Observation
import ScreenXCore
import SwiftUI

/// Zustand der Aufnahme-Leiste. Schnelländerungen am Profil gelten nur für die nächste Aufnahme,
/// außer sie werden mit „Als Profil sichern …“ gespeichert.
@MainActor @Observable
final class RecordingBarModel {
    var mode: CaptureMode
    private(set) var profileID: String
    /// Arbeitskopie des gewählten Profils, mit den Schnelländerungen.
    var profile: RecordingProfile
    var systemAudio: Bool
    var microphone: Bool
    var expanded = false
    /// Globale Einstellung, hier nur gespiegelt.
    var hideNotifications: Bool {
        didSet { if hideNotifications != oldValue { update { $0.hideNotifications = hideNotifications } } }
    }
    /// Globales Mikrofon-Gerät (`nil` = Systemstandard).
    var microphoneDeviceID: String? {
        didSet { if microphoneDeviceID != oldValue { update { $0.microphoneDeviceID = microphoneDeviceID } } }
    }
    private(set) var profiles: [RecordingProfile]
    /// Pixelmaße der Quelle für die Schätzung: vor der Auswahl der Bildschirm unter dem Zeiger.
    let sourceSize: CGSize
    let microphones: [MicrophoneDevice]

    @ObservationIgnored var onStart: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onEditProfiles: (() -> Void)?
    /// Nach einem modalen Dialog: die Leiste wieder zum Key-Fenster machen.
    @ObservationIgnored var onRefocus: (() -> Void)?
    @ObservationIgnored private let link: SettingsLink

    struct MicrophoneDevice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    init(link: SettingsLink, sourceSize: CGSize) {
        self.link = link
        self.sourceSize = sourceSize
        let settings = link.get()
        let setup = settings.lastRecordingSetup
        let profile = settings.profile(id: setup?.profileID ?? settings.defaultProfileID)
        mode = setup?.mode ?? .area
        profileID = profile.id
        self.profile = profile
        if let setup, setup.profileID == profile.id {
            systemAudio = setup.systemAudio
            microphone = setup.microphone
        } else {
            systemAudio = profile.systemAudio
            microphone = profile.microphone
        }
        hideNotifications = settings.hideNotifications
        microphoneDeviceID = settings.microphoneDeviceID
        profiles = settings.recordingProfiles
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Profilwechsel: alle Werte und die Ton-Schalter folgen dem neuen Profil.
    func select(profileID id: String) {
        let settings = link.get()
        let profile = settings.profile(id: id)
        let setup = settings.setup(applying: profile, mode: mode)
        profileID = profile.id
        self.profile = profile
        systemAudio = setup.systemAudio
        microphone = setup.microphone
    }

    /// Das Profil, mit dem aufgenommen wird. Klicks werden im Fenster-Modus nie hervorgehoben.
    var effectiveProfile: RecordingProfile {
        var result = profile
        result.systemAudio = systemAudio
        result.microphone = microphone
        if mode == .window { result.highlightClicks = false }
        return result
    }

    var setup: RecordingSetup {
        RecordingSetup(mode: mode, profileID: profileID, systemAudio: systemAudio, microphone: microphone)
    }

    var microphoneName: String {
        if let microphoneDeviceID, let device = microphones.first(where: { $0.id == microphoneDeviceID }) {
            return device.name
        }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? String(localized: "Mikrofon")
    }

    // MARK: - Schätzung

    var targetSize: CGSize {
        RecordingEstimate.targetSize(source: sourceSize, resolution: profile.resolution)
    }

    private var estimateParts: (perMinute: String, perHour: String) {
        let text = RecordingEstimate.text(
            megabytesPerMinute: RecordingEstimate.megabytesPerMinute(profile: effectiveProfile, source: sourceSize))
        let parts = text.components(separatedBy: " · ")
        return (parts.first ?? text, parts.count > 1 ? parts[1] : "")
    }

    private var gifText: String {
        let size = targetSize
        let mb = RecordingEstimate.gifMegabytes(size: size, fps: profile.fps, seconds: 10)
        let number = mb.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "de_DE")))
        return String(localized: "≈ \(number) MB pro 10 s")
    }

    /// Fett in der Leiste, z. B. „≈ 38 MB/min“.
    var estimateTitle: String {
        profile.output == .gif ? gifText : estimateParts.perMinute
    }

    /// Z. B. „1080p · 24 fps · HEVC · ≈ 2,3 GB/h“.
    var estimateSubtitle: String {
        let format = profile.output == .gif ? "GIF" : profile.codec.shortLabel
        var parts = [profile.resolution.label, "\(profile.fps) fps", format]
        if profile.output != .gif { parts.append(estimateParts.perHour) }
        return parts.joined(separator: " · ")
    }

    /// Fußzeile der Details, z. B. „≈ 38 MB pro Minute“.
    var detailTitle: String {
        guard profile.output != .gif else { return gifText }
        return estimateParts.perMinute.replacingOccurrences(of: " MB/min", with: String(localized: " MB pro Minute"))
    }

    /// Z. B. „· 1 Stunde ≈ 2,3 GB · Quelle 2940×1912 → 1920×1248“.
    var detailSubtitle: String {
        let source = "\(Int(sourceSize.width))×\(Int(sourceSize.height))"
        let target = "\(Int(targetSize.width))×\(Int(targetSize.height))"
        let sourceText = String(localized: "Quelle \(source) → \(target)")
        guard profile.output != .gif else { return "· \(sourceText)" }
        let perHour = estimateParts.perHour.replacingOccurrences(of: "/h", with: "")
        return "· " + String(localized: "1 Stunde \(perHour)") + " · " + sourceText
    }

    // MARK: - Als Profil sichern

    func saveAsProfile() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Als Profil sichern")
        alert.informativeText = String(localized: "Name des neuen Profils:")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = profile.name
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Sichern"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        defer { onRefocus?() }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
        var newProfile = effectiveProfile
        newProfile.id = UUID().uuidString
        newProfile.name = name
        newProfile.highlightClicks = profile.highlightClicks
        update { $0.recordingProfiles.append(newProfile) }
        profiles = link.get().recordingProfiles
        profileID = newProfile.id
        profile = newProfile
    }

    private func update(_ change: (inout AppSettings) -> Void) {
        var settings = link.get()
        change(&settings)
        link.set(settings)
    }
}

// MARK: - Panel

/// Schwebende Aufnahme-Leiste unten mittig auf dem Bildschirm unter dem Zeiger. Nicht aktivierend,
/// wird aber Key: ↩ startet, Esc schließt.
@MainActor
final class RecordingBarPanel {
    let model: RecordingBarModel
    private let panel: BarPanel
    private var screenFrame: CGRect = .zero

    init(model: RecordingBarModel) {
        self.model = model
        panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.onReturn = { [weak model] in model?.onStart?() }
        panel.onEscape = { [weak model] in model?.onClose?() }
        let hosting = NSHostingView(rootView: RecordingBarView(model: model) { [weak self] size in
            // Nicht mitten im SwiftUI-Layout das Fenster verändern.
            Task { @MainActor in self?.layout(size: size) }
        })
        // Die Fenstergröße setzt `layout(size:)`, nicht Auto Layout.
        hosting.sizingOptions = []
        panel.contentView = hosting
        model.onRefocus = { [weak self] in self?.panel.makeKeyAndOrderFront(nil) }
    }

    func show(on screen: NSScreen) {
        screenFrame = screen.visibleFrame
        if let size = panel.contentView?.fittingSize { layout(size: size) }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    /// Unten mittig, 40 pt über dem unteren Rand; wächst beim Ausklappen nach oben.
    private func layout(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let origin = CGPoint(x: (screenFrame.midX - size.width / 2).rounded(), y: screenFrame.minY + 40)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }
}

private final class BarPanel: NSPanel {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch event.keyCode {
            case 36, 76:
                onReturn?()
                return
            case 53:
                onEscape?()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - Ansicht

private struct RecordingBarView: View {
    @Bindable var model: RecordingBarModel
    let onResize: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.expanded {
                RecordingDetailsView(model: model)
                Divider().padding(.vertical, 10)
            }
            bar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.08)))
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onResize)
    }

    private var separator: some View {
        Rectangle().fill(Color.black.opacity(0.12)).frame(width: 1)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Picker(String(localized: "Modus"), selection: $model.mode) {
                Label(String(localized: "Bereich"), systemImage: "rectangle.dashed").tag(CaptureMode.area)
                Label(String(localized: "Fenster"), systemImage: "macwindow").tag(CaptureMode.window)
                Label(String(localized: "Bildschirm"), systemImage: "display").tag(CaptureMode.fullscreen)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Divider().frame(height: 26)

            Menu {
                ForEach(model.profiles) { profile in
                    Button(profile.name) { model.select(profileID: profile.id) }
                }
                Divider()
                Button(String(localized: "Profile bearbeiten …")) { model.onEditProfiles?() }
            } label: {
                HStack(spacing: 3) {
                    Text(String(localized: "Profil:"))
                    Text(model.profile.name).bold()
                }
            }
            .fixedSize()

            Pill {
                Menu {
                    Picker(String(localized: "Mikrofon"), selection: $model.microphoneDeviceID) {
                        Text(String(localized: "Systemstandard")).tag(String?.none)
                        ForEach(model.microphones) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(model.microphoneName, systemImage: "mic")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                Toggle(String(localized: "Mikrofon"), isOn: $model.microphone)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            Pill {
                Label(String(localized: "Systemton"), systemImage: "speaker.wave.2")
                Toggle(String(localized: "Systemton"), isOn: $model.systemAudio)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            Button {
                model.expanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.estimateTitle).font(.system(size: 14, weight: .bold))
                    Text(model.estimateSubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .leading) { separator }
            .overlay(alignment: .trailing) { separator }

            RecordButton { model.onStart?() }

            Button {
                model.onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Schließen (Esc)"))
        }
        .fixedSize()
    }
}

/// Profildetails (Figma 1b): Auflösung, Bildrate, Qualität, Format und Extras für diese Aufnahme.
private struct RecordingDetailsView: View {
    @Bindable var model: RecordingBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    label(String(localized: "Auflösung"))
                    Picker(String(localized: "Auflösung"), selection: $model.profile.resolution) {
                        ForEach(VideoResolution.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .segmented()
                }
                GridRow {
                    label(String(localized: "Bildrate"))
                    Picker(String(localized: "Bildrate"), selection: $model.profile.fps) {
                        ForEach(RecordingProfile.allowedFPS, id: \.self) { fps in
                            Text(fps == RecordingProfile.allowedFPS.last ? "\(fps) fps" : "\(fps)").tag(fps)
                        }
                    }
                    .segmented()
                }
                GridRow {
                    label(String(localized: "Qualität"))
                    Picker(String(localized: "Qualität"), selection: $model.profile.quality) {
                        ForEach(VideoQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .segmented()
                }
                GridRow {
                    label(String(localized: "Format"))
                    Picker(String(localized: "Format"), selection: $model.profile.codec) {
                        ForEach(VideoCodec.allCases, id: \.self) { Text($0.longLabel).tag($0) }
                    }
                    .segmented()
                }
                GridRow(alignment: .top) {
                    label(String(localized: "Extras"))
                    HStack(alignment: .top, spacing: 16) {
                        Toggle(String(localized: "Mauszeiger"), isOn: $model.profile.showsCursor)
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(String(localized: "Klicks hervorheben"), isOn: highlightClicks)
                                .disabled(model.mode == .window)
                            if model.mode == .window {
                                Text(String(localized: "Im Fenster-Modus nicht verfügbar"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Toggle(String(localized: "Mitteilungen ausblenden"), isOn: $model.hideNotifications)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Divider().padding(.top, 14).padding(.bottom, 12)

            HStack(spacing: 8) {
                Text(model.detailTitle).font(.system(size: 15, weight: .bold))
                Text(model.detailSubtitle).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Button(String(localized: "Als Profil sichern …")) { model.saveAsProfile() }
                RecordButton { model.onStart?() }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    /// Im Fenster-Modus immer aus.
    private var highlightClicks: Binding<Bool> {
        Binding(
            get: { model.mode != .window && model.profile.highlightClicks },
            set: { model.profile.highlightClicks = $0 }
        )
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }
}

private extension View {
    func segmented() -> some View {
        pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}

/// Weißer Hintergrund mit Rand, wie die Pillen im Entwurf.
private struct Pill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.14)))
            .fixedSize()
    }
}

/// Roter „Aufnehmen ↩“-Knopf.
private struct RecordButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(.white).frame(width: 9, height: 9)
                Text(String(localized: "Aufnehmen ↩")).fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color(nsColor: RecordingColors.red), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - Bezeichnungen

extension VideoResolution {
    var label: String {
        switch self {
        case .original: String(localized: "Original")
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }
}

extension VideoQuality {
    var label: String {
        switch self {
        case .high: String(localized: "Hoch")
        case .medium: String(localized: "Mittel")
        case .small: String(localized: "Klein")
        }
    }
}

extension VideoCodec {
    var shortLabel: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        }
    }

    var longLabel: String {
        switch self {
        case .hevc: String(localized: "HEVC (kleiner)")
        case .h264: String(localized: "H.264 (überall)")
        }
    }
}
