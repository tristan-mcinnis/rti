import Foundation

// Every UserDefaults key the app reads or writes lives here, grouped by
// settings area. Key strings are load-bearing: a user's saved settings live
// under them, so never change a value, only add.

public enum OverlayAppearanceDefaults {
    /// `system`, `light`, or `dark`. Replaces the older light-mode bool.
    public static let appearanceModeKey = "rti.overlay.appearanceMode"
    public static let lightModeKey = "rti.overlay.lightMode"
    public static let contrastKey = "rti.overlay.contrast"
    public static let uiFontSizeKey = "rti.overlay.uiFontSize"
    /// An explicit opt-in for hiding RTI's own titled windows from compatible capture clients.
    public static let invisibilityKey = "rti.invisible"

    public static func hidesWindowsFromScreenCapture(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: invisibilityKey)
    }

    public static let defaultWidth: Double = 700
    public static let defaultHeight: Double = 440
    /// A fresh profile follows macOS until the user selects a specific appearance.
    public static let defaultAppearanceMode = RTIAppearanceMode.system.rawValue
    public static let defaultContrast: Double = 60
    public static let defaultUIFontSize: Double = 15
    // The overlay's single-row chrome and footer remain legible at 600 pt.
    // Below that, tab names and shortcut labels compress into wrapped glyphs.
    public static let widthRange: ClosedRange<Double> = 600...800
    public static let heightRange: ClosedRange<Double> = 400...900
    public static let contrastRange: ClosedRange<Double> = 35...85
    public static let uiFontSizeRange: ClosedRange<Double> = 12...18

    public static func effectiveAppearanceMode(in defaults: UserDefaults = .standard) -> RTIAppearanceMode {
        if let raw = defaults.string(forKey: appearanceModeKey),
           let mode = RTIAppearanceMode(rawValue: raw) {
            return mode
        }
        if defaults.object(forKey: lightModeKey) != nil {
            return defaults.bool(forKey: lightModeKey) ? .light : .dark
        }
        return .system
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
    /// Unset until the user flips a toggle. Never registered as a default,
    /// so "unset" stays distinct from a stored false.
    public static let enabledKey = "rti.analysis.autoAssistEnabled"
    /// One-time flag: Auto became on by default (Band 2, 2026-11). A stored
    /// false from the opt-in era is removed once, so the new default reaches
    /// an existing install; a toggle set after that stays.
    public static let defaultOnMigrationKey = "rti.analysis.autoAssistDefaultOnMigrated"
    /// Show tone-marked pinyin under a card's Mandarin line. Per user: on by
    /// default (the owner is not a native speaker); a native speaker turns
    /// it off in Settings > General.
    public static let pinyinKey = "rti.analysis.autoAssistPinyin"
    public static let defaultShowsPinyin = true

    public static func showsPinyin(stored: Bool?) -> Bool {
        stored ?? defaultShowsPinyin
    }

    public static func showsPinyin(defaults: UserDefaults = .standard) -> Bool {
        showsPinyin(stored: defaults.object(forKey: pinyinKey) as? Bool)
    }

    /// Run once at launch. In the opt-in era every install that had ever
    /// shown the toggle stored false, so a stored false then is not a choice
    /// against the new default. A stored true agrees with it and stays.
    /// Marks the flag on every first run, so a false the user sets later
    /// is kept.
    public static func migrateOptInEraValue(in defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: defaultOnMigrationKey) else { return }
        defaults.set(true, forKey: defaultOnMigrationKey)
        if let stored = defaults.object(forKey: enabledKey) as? Bool, !stored {
            defaults.removeObject(forKey: enabledKey)
        }
    }

    /// Auto has a pass only on client and research calls. On internal and
    /// personal calls it never runs, whatever the toggle says.
    public static func runs(on callType: CallType) -> Bool {
        callType == .client || callType == .research
    }

    /// With no stored toggle, Auto is on wherever it runs.
    public static func defaultEnabled(for callType: CallType) -> Bool {
        runs(on: callType)
    }

    /// The one predicate every surface uses (tab, menu, switches, controller).
    /// On a call type where Auto runs, a toggle the user has set wins;
    /// otherwise the call type decides. Off where Auto never runs.
    public static func isActive(for callType: CallType, stored: Bool?) -> Bool {
        runs(on: callType) && (stored ?? defaultEnabled(for: callType))
    }

    public static func isActive(for callType: CallType, defaults: UserDefaults = .standard) -> Bool {
        isActive(for: callType, stored: defaults.object(forKey: enabledKey) as? Bool)
    }

    /// Live help (the rail beside the transcript, or its strip) shows when
    /// Auto runs on this call, or a guide is active on a research call. The
    /// rail draws the guide's question and gaps only on research calls, so a
    /// guide on any other call type keeps its own tab and brings no rail.
    /// The Live page, the kept ⌘3 "Live Help" item and its palette row all
    /// ask this one question.
    public static func liveHelpApplies(for callType: CallType, stored: Bool?, guideActive: Bool) -> Bool {
        isActive(for: callType, stored: stored) || (guideActive && callType == .research)
    }
}

public enum VisualContextSettingsDefaults {
    public static let captureIntervalNanoseconds: UInt64 = 60 * 1_000_000_000
    public static let maximumEventCount = 240

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

public enum CallTypeDefaults {
    public static let activeKey = "rti.call.type"
}

public enum ScreenPrivacyDefaults {
    public static let excludedAppsKey = "screenPrivacy.excludedBundleIds"
}

public enum UISettingsDefaults {
    public static let paletteRecentsKey = "rti.palette.recents"
}

/// The Prepare page's two disclosures ("More options", and "Codebook and
/// stimulus" on research calls) stay as the user left them.
public enum SetupPageSettings {
    public static let moreOptionsExpandedKey = "rti.setup.moreOptionsExpanded"
    public static let researchExtrasExpandedKey = "rti.setup.codebookStimulusExpanded"
}

/// RTI Lite (2026-11-14): the default workspace. One live surface (transcript,
/// a context rail with the guide position, what to go back to and one
/// question to ask, and an ask bar) with Sessions, Chats and Settings behind
/// one menu. Live notes and the live codebook do not run in Lite: the
/// `/meeting` skill and the findings skills do that work after the call, so
/// a research call makes about a third of the model calls. Off restores the
/// full workspace; nothing is deleted either way.
public enum RTILiteSettings {
    public static let enabledKey = "rti.lite.enabled"
    /// Scheduler task ids that do not run in Lite.
    public static let skippedTasks: Set<String> = ["notes", "researchCodebook", "researchCodebookSynthesis"]

    /// The app registers `true` at launch (AppDelegate); unregistered code
    /// such as tests sees the full workspace.
    public static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// Whether a scheduled task runs under the current workspace.
    public static func runs(task id: String, in defaults: UserDefaults = .standard) -> Bool {
        !(isOn(in: defaults) && skippedTasks.contains(id))
    }
}
