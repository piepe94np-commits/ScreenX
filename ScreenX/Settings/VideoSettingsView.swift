import AppKit
import AVFoundation
import ScreenXCore
import SwiftUI

/// Reiter „Video“ (Figma-Rahmen 6): Profilliste links, Editor des gewählten Profils rechts,
/// darunter die allgemeinen Video-Einstellungen.
struct VideoSettingsView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var selectedID: String?
    @State private var confirmingReset = false
    @State private var connectedMicrophones: [MicrophoneEntry] = []

    /// Die Schätzung im Editor gilt immer für diese Quellgröße.
    private static let estimateSource = CGSize(width: 1920, height: 1080)

    private var profiles: [RecordingProfile] { coordinator.settings.recordingProfiles }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
            Divider()
            Form {
                if let profile = selectedProfileBinding {
                    ProfileEditor(profile: profile, estimate: estimateText(for: profile.wrappedValue))
                }
                generalSection
            }
            .formStyle(.grouped)
        }
        .onAppear {
            ensureSelection()
            connectedMicrophones = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
            ).devices.map { MicrophoneEntry(id: $0.uniqueID, name: $0.localizedName) }
        }
        .onChange(of: profiles) { ensureSelection() }
        .confirmationDialog(
            String(localized: "Mitgelieferte Profile zurücksetzen?"),
            isPresented: $confirmingReset
        ) {
            Button(String(localized: "Zurücksetzen"), role: .destructive) { resetBuiltins() }
            Button(String(localized: "Abbrechen"), role: .cancel) {}
        } message: {
            Text(String(localized: "Die mitgelieferten Profile erhalten wieder ihre ursprünglichen Werte. Eigene Profile bleiben erhalten."))
        }
    }

    // MARK: - Profilliste

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedID) {
                Section(String(localized: "Profile")) {
                    ForEach(profiles) { profile in
                        row(for: profile)
                            .tag(profile.id)
                            .contextMenu { contextMenu(for: profile) }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 4) {
                Button { addProfile() } label: { Image(systemName: "plus") }
                    .help(String(localized: "Neues Profil"))
                Button { if let selectedID { deleteProfile(id: selectedID) } } label: { Image(systemName: "minus") }
                    .help(profiles.count > 1
                          ? String(localized: "Profil löschen")
                          : String(localized: "Das letzte Profil kann nicht gelöscht werden."))
                    .disabled(selectedID == nil || profiles.count <= 1)
                Button { if let selectedID { duplicateProfile(id: selectedID) } } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help(String(localized: "Duplizieren"))
                .disabled(selectedID == nil)
                Spacer()
                Button(String(localized: "Zurücksetzen")) { confirmingReset = true }
                    .help(String(localized: "Mitgelieferte zurücksetzen"))
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func row(for profile: RecordingProfile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .opacity(profile.id == coordinator.settings.defaultProfileID ? 1 : 0)
                .accessibilityHidden(profile.id != coordinator.settings.defaultProfileID)
                .help(String(localized: "Standardprofil"))
            Text(profile.name)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func contextMenu(for profile: RecordingProfile) -> some View {
        Button(String(localized: "Als Standard")) { coordinator.settings.defaultProfileID = profile.id }
            .disabled(profile.id == coordinator.settings.defaultProfileID)
        Button(String(localized: "Duplizieren")) { duplicateProfile(id: profile.id) }
        Divider()
        Button(String(localized: "Löschen"), role: .destructive) { deleteProfile(id: profile.id) }
            .disabled(profiles.count <= 1)
    }

    // MARK: - Allgemein

    private var generalSection: some View {
        Section(String(localized: "Allgemein")) {
            Picker(String(localized: "Countdown"), selection: $coordinator.settings.countdown) {
                ForEach(CountdownSetting.allCases, id: \.self) { setting in
                    Text(setting.label).tag(setting)
                }
            }

            Toggle(String(localized: "Mitteilungen ausblenden"), isOn: $coordinator.settings.hideNotifications)

            Picker(String(localized: "Mikrofon"), selection: $coordinator.settings.microphoneDeviceID) {
                Text(String(localized: "Systemstandard")).tag(String?.none)
                ForEach(microphones) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
            }

            LabeledContent(String(localized: "Kürzel Video")) {
                VideoHotkeyRecorderView(coordinator: coordinator)
            }
        }
    }

    /// Angeschlossene Mikrofone; ein gespeichertes, gerade nicht angeschlossenes Gerät bleibt wählbar.
    private var microphones: [MicrophoneEntry] {
        var devices = connectedMicrophones
        if let stored = coordinator.settings.microphoneDeviceID, !devices.contains(where: { $0.id == stored }) {
            devices.append(MicrophoneEntry(id: stored, name: String(localized: "Nicht angeschlossenes Gerät")))
        }
        return devices
    }

    private struct MicrophoneEntry: Identifiable {
        let id: String
        let name: String
    }

    // MARK: - Profile bearbeiten

    private var selectedProfileBinding: Binding<RecordingProfile>? {
        guard let id = selectedID, let current = profiles.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { coordinator.settings.recordingProfiles.first { $0.id == id } ?? current },
            set: { newValue in
                guard let index = coordinator.settings.recordingProfiles.firstIndex(where: { $0.id == id }) else { return }
                coordinator.settings.recordingProfiles[index] = newValue
            }
        )
    }

    private func estimateText(for profile: RecordingProfile) -> String {
        if profile.output == .gif {
            let size = RecordingEstimate.targetSize(source: Self.estimateSource, resolution: profile.resolution)
            let mb = RecordingEstimate.gifMegabytes(size: size, fps: profile.fps, seconds: 10)
            let number = mb.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "de_DE")))
            return String(localized: "≈ \(number) MB pro 10 s")
        }
        return RecordingEstimate.text(
            megabytesPerMinute: RecordingEstimate.megabytesPerMinute(profile: profile, source: Self.estimateSource))
    }

    private func ensureSelection() {
        if let selectedID, profiles.contains(where: { $0.id == selectedID }) { return }
        selectedID = profiles.first { $0.id == coordinator.settings.defaultProfileID }?.id ?? profiles.first?.id
    }

    private func addProfile() {
        let profile = RecordingProfile(id: UUID().uuidString, name: String(localized: "Neues Profil"))
        coordinator.settings.recordingProfiles.append(profile)
        selectedID = profile.id
    }

    private func duplicateProfile(id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var copy = profiles[index]
        copy.id = UUID().uuidString
        copy.name = String(localized: "\(copy.name) Kopie")
        coordinator.settings.recordingProfiles.insert(copy, at: index + 1)
        selectedID = copy.id
    }

    /// Das letzte Profil bleibt. War das gelöschte der Standard, wird das erste verbleibende Standard.
    private func deleteProfile(id: String) {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var settings = coordinator.settings
        settings.recordingProfiles.remove(at: index)
        if settings.defaultProfileID == id {
            settings.defaultProfileID = settings.recordingProfiles[0].id
        }
        coordinator.settings = settings
        if selectedID == id {
            selectedID = settings.recordingProfiles[min(index, settings.recordingProfiles.count - 1)].id
        }
    }

    /// Mitgelieferte Profile erhalten ihre ursprünglichen Werte (fehlende kommen in der
    /// mitgelieferten Reihenfolge wieder dazu), eigene Profile bleiben unverändert.
    private func resetBuiltins() {
        var list = coordinator.settings.recordingProfiles
        for (offset, builtin) in RecordingProfile.builtins.enumerated() {
            if let index = list.firstIndex(where: { $0.id == builtin.id }) {
                list[index] = builtin
            } else {
                list.insert(builtin, at: min(offset, list.count))
            }
        }
        coordinator.settings.recordingProfiles = list
    }
}

/// Editor eines Profils: alle Felder und die Schätzung für 1920×1080.
private struct ProfileEditor: View {
    @Binding var profile: RecordingProfile
    let estimate: String

    var body: some View {
        Section(String(localized: "Profil")) {
            TextField(String(localized: "Name"), text: $profile.name)

            Picker(String(localized: "Auflösung"), selection: $profile.resolution) {
                ForEach(VideoResolution.allCases, id: \.self) { Text($0.label).tag($0) }
            }

            Picker(String(localized: "Bildrate"), selection: $profile.fps) {
                ForEach(RecordingProfile.allowedFPS, id: \.self) { fps in
                    Text(String(localized: "\(fps) fps")).tag(fps)
                }
            }

            Picker(String(localized: "Qualität"), selection: $profile.quality) {
                ForEach(VideoQuality.allCases, id: \.self) { Text($0.label).tag($0) }
            }

            Picker(String(localized: "Format"), selection: $profile.codec) {
                ForEach(VideoCodec.allCases, id: \.self) { Text($0.longLabel).tag($0) }
            }
            .disabled(profile.output == .gif)

            LabeledContent(String(localized: "Ton")) {
                HStack(spacing: 14) {
                    Toggle(String(localized: "Systemton"), isOn: $profile.systemAudio)
                    Toggle(String(localized: "Mikrofon"), isOn: $profile.microphone)
                }
                .toggleStyle(.checkbox)
            }
            .disabled(profile.output == .gif)

            LabeledContent(String(localized: "Extras")) {
                HStack(spacing: 14) {
                    Toggle(String(localized: "Mauszeiger"), isOn: $profile.showsCursor)
                    Toggle(String(localized: "Klicks hervorheben"), isOn: $profile.highlightClicks)
                }
                .toggleStyle(.checkbox)
            }

            Picker(String(localized: "Ausgabe"), selection: $profile.output) {
                Text(String(localized: "Video (MP4)")).tag(RecordingOutput.video)
                Text(verbatim: "GIF").tag(RecordingOutput.gif)
            }
            .pickerStyle(.segmented)

            LabeledContent(String(localized: "Geschätzt (1920×1080)")) {
                Text(estimate)
                    .bold()
                    .monospacedDigit()
            }
        }
    }
}

/// Kürzel „Video aufnehmen“. Wie bei den Screenshot-Kürzeln: mindestens einer von ⌘⌥⌃, Esc
/// bricht ab, ein Kürzel gehört höchstens einer Aktion (ein Screenshot-Modus mit demselben
/// Kürzel verliert es).
struct VideoHotkeyRecorderView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var recorder = VideoHotkeyRecorder()

    var body: some View {
        let combo = coordinator.settings.videoHotkey
        let error = coordinator.videoHotkeyError
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        recorder.start { setHotkey($0) }
                    }
                } label: {
                    Text(label(for: combo))
                        .foregroundStyle(error == nil || recorder.isRecording ? Color.primary : Color.red)
                        .frame(minWidth: 120)
                }

                Button {
                    recorder.stop()
                    coordinator.settings.videoHotkey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(String(localized: "Kürzel entfernen"))
                .disabled(combo == nil)
            }

            if let error, !recorder.isRecording {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { recorder.stop() }
    }

    /// Setzt das Video-Kürzel und nimmt es einem Screenshot-Modus mit demselben Kürzel weg.
    private func setHotkey(_ combo: KeyCombo) {
        var settings = coordinator.settings
        for (mode, existing) in settings.hotkeys where existing == combo {
            settings.hotkeys[mode] = nil
        }
        settings.videoHotkey = combo
        coordinator.settings = settings
    }

    private func label(for combo: KeyCombo?) -> String {
        if recorder.isRecording { return String(localized: "Kürzel drücken …") }
        return combo?.displayString ?? String(localized: "Kein Kürzel")
    }
}

/// Der lokale keyDown-Monitor des Video-Kürzel-Rekorders.
@MainActor
@Observable
final class VideoHotkeyRecorder {
    private(set) var isRecording = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?

    func start(onCombo: @escaping (KeyCombo) -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event, onCombo: onCombo)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        isRecording = false
    }

    private func handle(_ event: NSEvent, onCombo: (KeyCombo) -> Void) {
        if event.keyCode == 53 {  // Esc
            stop()
            return
        }
        var modifiers: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else {
            NSSound.beep()
            return
        }
        onCombo(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers))
        stop()
    }
}

extension CountdownSetting {
    var label: String {
        switch self {
        case .off: String(localized: "Aus")
        case .three, .five: String(localized: "\(rawValue) s")
        }
    }
}
