import Foundation

extension Notification.Name {
    static let rtiToggleOverlay = Notification.Name("rti.toggleOverlay")
    static let rtiClearChat = Notification.Name("rti.clearChat")
    static let rtiOverlayDidBecomeKey = Notification.Name("rti.overlayDidBecomeKey")
    static let rtiOverlaySizeChanged = Notification.Name("rti.overlaySizeChanged")
    /// Posted when the light/dark setting flips so the live panel re-applies its
    /// NSAppearance immediately.
    static let rtiOverlayAppearanceChanged = Notification.Name("rti.overlayAppearanceChanged")
    static let rtiShowLiveTranscript = Notification.Name("rti.showLiveTranscript")
    static let rtiShowLogs = Notification.Name("rti.showLogs")
    static let rtiSelectSessionsControlTab = Notification.Name("rti.selectSessionsControlTab")
    /// Posted after a "Clear Current Chat" action so any open auxiliary
    /// panel windows dismiss themselves.
    static let rtiHideAuxiliaryPanels = Notification.Name("rti.hideAuxiliaryPanels")
    /// Posted when a session stops, so per-session UI state (e.g. an unsent
    /// draft in the composer) can reset before the next meeting.
    static let rtiSessionDidStop = Notification.Name("rti.sessionDidStop")
}

enum OverlayAppearanceDefaults {
    static let widthKey = "rti.overlay.width"
    static let heightKey = "rti.overlay.height"
    static let opacityKey = "rti.overlay.opacity"
    /// When true, the overlay renders in light mode (white panel, black text).
    static let lightModeKey = "rti.overlay.lightMode"
    /// When true (the default), every RTI panel sets `sharingType = .none` so it
    /// is excluded from screen capture.
    static let invisibilityKey = "rti.invisible"
    static let defaultWidth: Double = 700
    static let defaultHeight: Double = 440
    static let defaultOpacity: Double = 0.90
    static let widthRange: ClosedRange<Double> = 320...800
    static let heightRange: ClosedRange<Double> = 400...900
    static let opacityRange: ClosedRange<Double> = 0.10...1.00
}

enum AudioSettingsDefaults {
    /// Apple Voice-Processing I/O on the mic: acoustic echo cancellation,
    /// noise suppression, AGC. Cancels the other party's voice bleeding from
    /// the speakers into the mic, which otherwise double-transcribes.
    static let echoCancellationKey = "rti.audio.echoCancellation"
    /// While recording, if the default mic is a Bluetooth headset, route capture
    /// to the built-in mic so the headphones stay in full-volume A2DP instead of
    /// dropping into quiet HFP "call mode". Restored on stop.
    static let protectBluetoothVolumeKey = "rti.audio.protectBluetoothVolume"
}

enum TranslationDefaults {
    static let enabledKey = "rti.translation.enabled"
    static let showOriginalKey = "rti.translation.showOriginal"
    static let modeKey = "rti.translation.mode"
    static let targetLanguageKey = "rti.translation.targetLanguage"
    static let languageAKey = "rti.translation.languageA"
    static let languageBKey = "rti.translation.languageB"
}

enum AnalysisSettingsDefaults {
    static let notesEnabledKey = "rti.analysis.notesEnabled"
    static let notesIntervalKey = "rti.analysis.notesIntervalSeconds"
    static let guideEnabledKey = "rti.analysis.guideEnabled"
    static let findingsEnabledKey = "rti.analysis.findingsEnabled"
    static let defaultInterval: Double = 120
    static let intervalRange: ClosedRange<Double> = 60...600
}
