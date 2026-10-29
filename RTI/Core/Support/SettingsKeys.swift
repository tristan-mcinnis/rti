import Foundation

// Every UserDefaults key the app reads or writes lives here, grouped by
// settings area. Key strings are load-bearing: a user's saved settings live
// under them, so never change a value, only add.

public enum OverlayAppearanceDefaults {
    public static let widthKey = "rti.overlay.width"
    public static let heightKey = "rti.overlay.height"
    /// `system`, `light`, or `dark`. Replaces the older light-mode bool.
    public static let appearanceModeKey = "rti.overlay.appearanceMode"
    public static let lightModeKey = "rti.overlay.lightMode"
    public static let accentColorKey = "rti.overlay.accentColor"
    public static let contrastKey = "rti.overlay.contrast"
    public static let uiFontSizeKey = "rti.overlay.uiFontSize"
    public static let reduceMotionKey = "rti.overlay.reduceMotion"
    /// When true (the default), every RTI panel sets `sharingType = .none` so it
    /// is excluded from screen capture.
    public static let invisibilityKey = "rti.invisible"
    public static let defaultWidth: Double = 700
    public static let defaultHeight: Double = 440
    /// Slate is a dark-first system; light stays first-class.
    public static let defaultAppearanceMode = RTIAppearanceMode.dark.rawValue
    public static let defaultAccentColor = "#0866D6" // House accent (light); see design-system/tokens.json
    public static let defaultContrast: Double = 60
    public static let defaultUIFontSize: Double = 14
    public static let defaultReduceMotion = RTIReduceMotionMode.system.rawValue
    // The overlay's single-row chrome and footer remain legible at 600 pt.
    // Below that, tab names and shortcut labels compress into wrapped glyphs.
    public static let widthRange: ClosedRange<Double> = 600...800
    public static let heightRange: ClosedRange<Double> = 400...900
    public static let contrastRange: ClosedRange<Double> = 35...85
    public static let uiFontSizeRange: ClosedRange<Double> = 12...18

    public static func effectiveAppearanceMode() -> RTIAppearanceMode {
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
}

public enum RTIAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum RTIReduceMotionMode: String, CaseIterable, Identifiable {
    case system
    case on
    case off

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .on: "On"
        case .off: "Off"
        }
    }
}

public enum AudioSettingsDefaults {
    /// Apple Voice-Processing I/O on the mic: acoustic echo cancellation,
    /// noise suppression, AGC. Cancels the other party's voice bleeding from
    /// the speakers into the mic, which otherwise double-transcribes.
    public static let echoCancellationKey = "rti.audio.echoCancellation"
    /// While recording, if the default mic is a Bluetooth headset, route capture
    /// to the built-in mic so the headphones stay in full-volume A2DP instead of
    /// dropping into quiet HFP "call mode". Restored on stop.
    public static let protectBluetoothVolumeKey = "rti.audio.protectBluetoothVolume"
    /// UID of the user-chosen input device, or `AudioInputDevice.systemDefaultUID`.
    public static let preferredInputUIDKey = "rti.audio.preferredInputUID"
    /// Bundle ID of the app whose audio the system tap captures; "" = global tap.
    public static let captureAppBundleIDKey = "rti.audio.captureAppBundleID"
}

public enum TranslationDefaults {
    public static let enabledKey = "rti.translation.enabled"
    public static let showOriginalKey = "rti.translation.showOriginal"
    public static let modeKey = "rti.translation.mode"
    public static let targetLanguageKey = "rti.translation.targetLanguage"
    public static let languageAKey = "rti.translation.languageA"
    public static let languageBKey = "rti.translation.languageB"
}

public enum NotesSettings {
    public static let enabledKey = "rti.analysis.notesEnabled"
    public static let intervalKey = "rti.analysis.notesIntervalSeconds"
    public static let defaultEnabled = true
    public static let defaultInterval: Double = 120
    public static let intervalRange: ClosedRange<Double> = 60...600

    /// The shared scheduler tick: the saved notes interval, else the default.
    public static var tickInterval: TimeInterval {
        let saved = UserDefaults.standard.double(forKey: intervalKey)
        return saved > 0 ? saved : defaultInterval
    }
}

public enum AutoAssistSettings {
    /// Auto mode: proactively surface project-grounded suggestion cards live.
    public static let enabledKey = "rti.analysis.autoAssistEnabled"
    public static let defaultEnabled = false
}

public enum VisualContextSettingsDefaults {
    public static let enabledKey = "rti.visualContext.enabled"
    public static let defaultEnabled = true
    public static let captureIntervalNanoseconds: UInt64 = 60 * 1_000_000_000
    public static let maximumEventCount = 240

    public static var isEnabled: Bool {
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

public enum LLMSettingsDefaults {
    public static let activeProviderIdKey = "rti.llm.activeProviderId"
    public static let smartModeKey = "rti.llm.smartMode"
    public static let primaryActionKey = "rti.llm.primaryAction"
    /// One-time flag: the shipped ⌘⏎ action became Quick recap on 2026-09-17,
    /// so an old Assist / Answer latest default is moved once.
    public static let primaryQuickRecapMigrationKey = "rti.llm.primaryQuickRecapMigrated"
    public static let listenerModeKey = "rti.llm.listenerMode"
    public static let recapDepthKey = "rti.llm.recapDepth"
}

public enum STTSettingsDefaults {
    public static let activeProviderIdKey = "rti.stt.activeProviderId"
    public static let asyncProviderIdKey = "rti.stt.asyncProviderId"
}

public enum PromptSettingsDefaults {
    public static let overridesKey = "rti.prompts.overridesV1"
    public static let baseHashesKey = "rti.prompts.baseHashesV1"
}

public enum ModeSettingsDefaults {
    public static let activeIdKey = "rti.modes.activeId"
}

public enum ScreenPrivacyDefaults {
    public static let excludedAppsKey = "screenPrivacy.excludedBundleIds"
}

public enum UISettingsDefaults {
    public static let sessionDetailDensityKey = "rti.sessionDetail.density"
    public static let paletteRecentsKey = "rti.palette.recents"
}
