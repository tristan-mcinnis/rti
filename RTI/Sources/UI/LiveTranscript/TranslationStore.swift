import Foundation
import RTICore

/// Single source of truth for live-translation settings.
///
/// Previously every translation-capable view (`TranscriptTabView`,
/// transcript surfaces owned their own `@AppStorage`
/// copies and pushed the resulting `TranslationConfig` into
/// `SessionCoordinator.translationConfig` from `.onAppear` and `.onChange`.
/// That caused races: the last view to appear or change would overwrite the
/// others, and the three surfaces could disagree.
///
/// This store keeps the settings in one place, derived from the same
/// `UserDefaults` keys the views already use. `SessionCoordinator` observes
/// `UserDefaults.didChangeNotification` and calls `currentConfig()` to update
/// the audio pipeline. Views still read/write the same keys via `@AppStorage`,
/// but they no longer push config directly.
enum TranslationStore {
    static func currentConfig() -> TranslationConfig? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: TranslationDefaults.enabledKey) else { return nil }

        let mode = defaults.string(forKey: TranslationDefaults.modeKey) ?? "one_way"
        if mode == "two_way" {
            let languageA = defaults.string(forKey: TranslationDefaults.languageAKey) ?? "en"
            let languageB = defaults.string(forKey: TranslationDefaults.languageBKey) ?? "zh"
            guard languageA != languageB else { return nil }
            return .twoWay(languageA: languageA, languageB: languageB)
        } else {
            let target = defaults.string(forKey: TranslationDefaults.targetLanguageKey) ?? "en"
            return .oneWay(targetLanguage: target)
        }
    }
}
