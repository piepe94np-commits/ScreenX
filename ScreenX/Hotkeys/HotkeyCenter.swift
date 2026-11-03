import Carbon.HIToolbox
import ScreenXCore

/// Registers the global capture hotkeys via Carbon. Hotkey ID = index in `CaptureMode.allCases`.
@MainActor
final class HotkeyCenter {
    /// 'SCRX'
    private static let signature: FourCharCode = 0x5343_5258

    private let handler: @MainActor (CaptureMode) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []

    init(handler: @escaping @MainActor (CaptureMode) -> Void) {
        self.handler = handler

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
                let index = Int(hotKeyID.id)
                guard CaptureMode.allCases.indices.contains(index) else {
                    return OSStatus(eventNotHandledErr)
                }
                let mode = CaptureMode.allCases[index]
                let center = Unmanaged<HotkeyCenter>.fromOpaque(userData)
                // Carbon delivers application-target hotkey events on the main thread.
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
    func register(_ hotkeys: [CaptureMode: KeyCombo]) -> [CaptureMode: HotkeyError] {
        unregisterAll()
        var errors: [CaptureMode: HotkeyError] = [:]
        for (index, mode) in CaptureMode.allCases.enumerated() {
            guard let combo = hotkeys[mode] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode,
                Self.carbonModifiers(combo.modifiers),
                EventHotKeyID(signature: Self.signature, id: UInt32(index)),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if let error = HotkeyError.from(status: status, combo: combo) {
                errors[mode] = error
            } else if let ref {
                hotKeyRefs.append(ref)
            }
        }
        return errors
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
