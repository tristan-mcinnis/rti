import AppKit
import Foundation

extension Notification.Name {
    static let rtiToggleOverlay = Notification.Name("rti.toggleOverlay")
    static let rtiClearChat = Notification.Name("rti.clearChat")
    static let rtiOverlayDidBecomeKey = Notification.Name("rti.overlayDidBecomeKey")
    static let rtiOverlaySizeChanged = Notification.Name("rti.overlaySizeChanged")
    /// Posted when the light/dark setting flips so the live panel re-applies its
    /// NSAppearance immediately.
    static let rtiOverlayAppearanceChanged = Notification.Name("rti.overlayAppearanceChanged")
    static let rtiShowLogs = Notification.Name("rti.showLogs")
    static let rtiSelectSessionsControlTab = Notification.Name("rti.selectSessionsControlTab")
    /// Posted (object = session folder name String) to focus the Sessions
    /// browser on a specific archived session — e.g. tapping the "summary
    /// ready" notification or the overlay's "Notes ready" control.
    static let rtiOpenSessionInBrowser = Notification.Name("rti.openSessionInBrowser")
    /// Posted when a session stops, so per-session UI state (e.g. an unsent
    /// draft in the composer) can reset before the next meeting.
    static let rtiSessionDidStop = Notification.Name("rti.sessionDidStop")
    /// Posted (object = OverlayTab rawValue String) to switch the overlay's
    /// active tab from a global hotkey or command.
    static let rtiSelectTab = Notification.Name("rti.selectTab")
    /// Posted (object = vault-relative path String, under `databases/`) to
    /// seed the overlay chat composer with an `@file` mention — e.g. the
    /// Sessions browser's "Ask about this session" action.
    static let rtiSeedChatMention = Notification.Name("rti.seedChatMention")
}

enum OverlayAppearanceDefaults {
    static let widthKey = "rti.overlay.width"
    static let heightKey = "rti.overlay.height"
    static let opacityKey = "rti.overlay.opacity"
    /// `system`, `light`, or `dark`. Replaces the older light-mode bool.
    static let appearanceModeKey = "rti.overlay.appearanceMode"
    static let lightModeKey = "rti.overlay.lightMode"
    static let accentColorKey = "rti.overlay.accentColor"
    static let contrastKey = "rti.overlay.contrast"
    static let translucentPanelKey = "rti.overlay.translucentPanel"
    /// Whether the overlay stays above other applications. Off makes it a
    /// normal-level window that can sit behind the active app.
    static let alwaysOnTopKey = "rti.overlay.alwaysOnTop"
    static let uiFontSizeKey = "rti.overlay.uiFontSize"
    static let reduceMotionKey = "rti.overlay.reduceMotion"
    /// When true (the default), every RTI panel sets `sharingType = .none` so it
    /// is excluded from screen capture.
    static let invisibilityKey = "rti.invisible"
    static let defaultWidth: Double = 700
    static let defaultHeight: Double = 440
    static let defaultOpacity: Double = 1.00
    static let defaultAppearanceMode = RTIAppearanceMode.system.rawValue
    static let defaultAccentColor = "#339CFF"
    static let defaultContrast: Double = 60
    static let defaultTranslucentPanel = false
    static let defaultAlwaysOnTop = true
    static let defaultUIFontSize: Double = 14
    static let defaultReduceMotion = RTIReduceMotionMode.system.rawValue
    static let widthRange: ClosedRange<Double> = 320...800
    static let heightRange: ClosedRange<Double> = 400...900
    static let opacityRange: ClosedRange<Double> = 0.10...1.00
    static let contrastRange: ClosedRange<Double> = 35...85
    static let uiFontSizeRange: ClosedRange<Double> = 12...18

    static func effectiveAppearanceMode() -> RTIAppearanceMode {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: appearanceModeKey),
           let mode = RTIAppearanceMode(rawValue: raw) {
            return mode
        }
        if defaults.object(forKey: lightModeKey) != nil {
            return defaults.bool(forKey: lightModeKey) ? .light : .dark
        }
        return .system
    }

    static func effectiveReduceMotion() -> Bool {
        let raw = UserDefaults.standard.string(forKey: reduceMotionKey) ?? defaultReduceMotion
        let mode = RTIReduceMotionMode(rawValue: raw) ?? .system
        switch mode {
        case .system:
            return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        case .on:
            return true
        case .off:
            return false
        }
    }
}

enum RTIAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum RTIReduceMotionMode: String, CaseIterable, Identifiable {
    case system
    case on
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .on: "On"
        case .off: "Off"
        }
    }
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
    /// Auto mode: proactively surface project-grounded suggestion cards live.
    static let autoAssistEnabledKey = "rti.analysis.autoAssistEnabled"
    static let defaultNotesEnabled = true
    static let defaultGuideEnabled = false
    static let defaultFindingsEnabled = false
    static let defaultAutoAssistEnabled = false
    static let defaultInterval: Double = 120
    static let intervalRange: ClosedRange<Double> = 60...600
}

enum VisualContextSettingsDefaults {
    static let enabledKey = "rti.visualContext.enabled"
    static let defaultEnabled = true
    static let captureIntervalNanoseconds: UInt64 = 60 * 1_000_000_000
    static let maximumEventCount = 240

    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}
