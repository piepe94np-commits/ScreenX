import AVFoundation

/// Microphone access for recordings (`NSMicrophoneUsageDescription`, entitlement `device.audio-input`).
enum MicrophonePermission {
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Asks the system on first use; afterwards returns the stored decision without a prompt.
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        default:
            false
        }
    }
}
