import Foundation

/// What the welcome window still needs before RTI can record, and the line
/// that says so. Pure, so the footnote and the Get Started state are pinned
/// by tests rather than read off a screenshot.
public struct OnboardingChecklist: Equatable, Sendable {
    /// A macOS privacy grant as the welcome window shows it.
    public enum Access: Equatable, Sendable {
        case granted
        /// Refused once: only System Settings can change it now.
        case denied
        case notAsked
    }

    /// Both provider keys (transcription and assistant) are saved.
    public var keysSaved: Bool
    public var microphone: Access
    /// Optional: RTI records and answers without it.
    public var screenRecording: Access

    public init(keysSaved: Bool, microphone: Access, screenRecording: Access) {
        self.keysSaved = keysSaved
        self.microphone = microphone
        self.screenRecording = screenRecording
    }

    /// Get Started turns on when both keys and the microphone are in place.
    /// Screen Recording never blocks it.
    public var isReady: Bool {
        keysSaved && microphone == .granted
    }

    /// One short line under the setup cards: what is missing, or that all
    /// is set.
    public var footnote: String {
        switch (keysSaved, microphone) {
        case (true, .granted):
            "All set. ⌘⇧R starts your first recording."
        case (false, .granted):
            "Save both API keys to finish."
        case (true, .denied):
            "Allow the microphone in System Settings to finish."
        case (true, .notAsked):
            "Allow the microphone to finish."
        case (false, _):
            "Save both API keys and allow the microphone to finish."
        }
    }
}
