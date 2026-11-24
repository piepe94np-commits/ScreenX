import Carbon.HIToolbox
import ScreenXCore

/// Registers the global hotkeys via Carbon. Hotkey ID = index in `CaptureMode.allCases`, or `videoID` for
/// "Video aufnehmen".
@MainActor
final class HotkeyCenter {
    /// 'SCRX'
    private static let signature: FourCharCode = 0x5343_5258

    private static let videoID: UInt32 = 100

    private let handler: @MainActor (CaptureMode) -> Void
    private let videoHandler: @MainActor () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []

    init(handler: @escaping @MainActor (CaptureMode) -> Void, videoHandler: @escaping @MainActor () -> Void) {
        self.handler = handler
        self.videoHandler = videoHandler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let center = Unmanaged<HotkeyCenter>.fromOpaque(userData)
                if hotKeyID.id == HotkeyCenter.videoID {
                    // Carbon delivers application-target hotkey events on the main thread.
                    MainActor.assumeIsolated {
                        center.takeUnretainedValue().videoHandler()
                    }
                    return noErr
                }
                let index = Int(hotKeyID.id)
                guard CaptureMode.allCases.indices.contains(index) else {
                    return OSStatus(eventNotHandledErr)
                }
                let mode = CaptureMode.allCases[index]
                MainActor.assumeIsolated {
                    center.takeUnretainedValue().handler(mode)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    isolated deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// Replaces all existing registrations. A failing hotkey does not affect the others.
    /// `video` is the "Video aufnehmen" hotkey (`nil` = none).
    func register(_ hotkeys: [CaptureMode: KeyCombo], video: KeyCombo?)
        -> (modes: [CaptureMode: HotkeyError], video: HotkeyError?) {
        unregisterAll()
        var errors: [CaptureMode: HotkeyError] = [:]
        for (index, mode) in CaptureMode.allCases.enumerated() {
            guard let combo = hotkeys[mode] else { continue }
            errors[mode] = register(combo, id: UInt32(index))
        }
        let videoError = video.flatMap { register($0, id: Self.videoID) }
        return (errors, videoError)
    }

    private func register(_ combo: KeyCombo, id: UInt32) -> HotkeyError? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            Self.carbonModifiers(combo.modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let error = HotkeyError.from(status: status, combo: combo) { return error }
        if let ref { hotKeyRefs.append(ref) }
        return nil
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private static func carbonModifiers(_ modifiers: KeyModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
