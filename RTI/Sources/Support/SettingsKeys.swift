import AppKit
import Foundation

// Every UserDefaults key the app reads or writes lives here, grouped by
// settings area. Key strings are load-bearing: a user's saved settings live
// under them, so never change a value, only add.

enum OverlayAppearanceDefaults {
    static let widthKey = "rti.overlay.width"
    static let heightKey = "rti.overlay.height"
    /// `system`, `light`, or `dark`. Replaces the older light-mode bool.
    static let appearanceModeKey = "rti.overlay.appearanceMode"
    static let lightModeKey = "rti.overlay.lightMode"
    static let accentColorKey = "rti.overlay.accentColor"
    static let contrastKey = "rti.overlay.contrast"
    static let uiFontSizeKey = "rti.overlay.uiFontSize"
    static let reduceMotionKey = "rti.overlay.reduceMotion"
    /// When true (the default), every RTI panel sets `sharingType = .none` so it
    /// is excluded from screen capture.
    static let invisibilityKey = "rti.invisible"
    static let defaultWidth: Double = 700
    static let defaultHeight: Double = 440
    /// Slate is a dark-first system; light stays first-class.
    static let defaultAppearanceMode = RTIAppearanceMode.dark.rawValue
    static let defaultAccentColor = "#0866D6" // House accent (light); see design-system/tokens.json
    static let defaultContrast: Double = 60
    static let defaultUIFontSize: Double = 14
    static let defaultReduceMotion = RTIReduceMotionMode.system.rawValue
    // The overlay's single-row chrome and footer remain legible at 600 pt.
    // Below that, tab names and shortcut labels compress into wrapped glyphs.
    static let widthRange: ClosedRange<Double> = 600...800
    static let heightRange: ClosedRange<Double> = 400...900
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
        return RTIAppearanceMode(rawValue: defaultAppearanceMode) ?? .dark
    }

    /// The NSAppearance every RTI window (and `NSApp`) should carry, per the
    /// Settings theme. `nil` means "follow the system".
    static func nsAppearance() -> NSAppearance? {
        switch effectiveAppearanceMode() {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Apply the configured appearance app-wide. Called at launch and whenever
    /// the setting changes, so every window follows without per-window code.
    @MainActor
    static func applyAppAppearance() {
        NSApp.appearance = nsAppearance()
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
    /// UID of the user-chosen input device, or `AudioInputDevice.systemDefaultUID`.
    static let preferredInputUIDKey = "rti.audio.preferredInputUID"
    /// Bundle ID of the app whose audio the system tap captures; "" = global tap.
    static let captureAppBundleIDKey = "rti.audio.captureAppBundleID"
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

enum LLMSettingsDefaults {
    static let activeProviderIdKey = "rti.llm.activeProviderId"
    static let smartModeKey = "rti.llm.smartMode"
    static let primaryActionKey = "rti.llm.primaryAction"
    /// One-time flag: the shipped ⌘⏎ action became Quick recap on 2026-09-17,
    /// so an old Assist / Answer latest default is moved once.
    static let primaryQuickRecapMigrationKey = "rti.llm.primaryQuickRecapMigrated"
    static let listenerModeKey = "rti.llm.listenerMode"
    static let recapDepthKey = "rti.llm.recapDepth"
}

enum STTSettingsDefaults {
    static let activeProviderIdKey = "rti.stt.activeProviderId"
    static let asyncProviderIdKey = "rti.stt.asyncProviderId"
}

enum PromptSettingsDefaults {
    static let overridesKey = "rti.prompts.overridesV1"
    static let baseHashesKey = "rti.prompts.baseHashesV1"
}

enum ModeSettingsDefaults {
    static let activeIdKey = "rti.modes.activeId"
}

enum ScreenPrivacyDefaults {
    static let excludedAppsKey = "screenPrivacy.excludedBundleIds"
}

enum UISettingsDefaults {
    static let sessionDetailDensityKey = "rti.sessionDetail.density"
    static let paletteRecentsKey = "rti.palette.recents"
}
