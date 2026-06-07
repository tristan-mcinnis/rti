import AppKit
import AVFoundation
import CoreGraphics

/// Thin wrapper over the macOS privacy checks RTI needs, so onboarding and the
/// session start path can show/grant them consistently.
enum AppPermissions {
    enum State {
        case granted
        case denied
        case notDetermined
    }

    // MARK: - Microphone (required — live transcription)

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: - Screen Recording (optional — Smart Screenshot OCR)

    /// CoreGraphics can't distinguish "denied" from "not yet asked" — both
    /// preflight as false — so screen recording is modelled as granted vs
    /// needs-action.
    static var screenRecording: State {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    /// Triggers the system grant prompt the first time; afterwards macOS
    /// requires a manual toggle in System Settings (so we also expose the
    /// deep link). Returns the immediate preflight result.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
