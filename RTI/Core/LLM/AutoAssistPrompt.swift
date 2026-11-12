import Foundation

/// Builds the one user message an Auto pass sends. Pure: the caller resolves
/// the prompt texts (`PromptStore` overrides) and gathers the live inputs.
///
/// The shared JSON contract (`autoAssistCards`) comes first, then the framing
/// for the call type. Internal and personal calls get no Auto pass at all.
/// The brief goes only to calls where the user speaks (`!callType.listens`),
/// the same gate the assistant uses; guide gaps go only to research.
public enum AutoAssistPrompt {
    /// The sentence the shipped `autoAssistCards` default ends with. The
    /// builder swaps it for `languageRule`, so a meeting in Mandarin gets
    /// speakable lines instead of English only.
    static let englishOnlySentence = "Write in English."

    /// The one language rule an Auto pass follows, keyed on the meeting's
    /// language. Auto-only: Recap keeps its own rule (`recapLanguageRule`).
    /// The bilingual lines do not count toward the contract's 25-word cap,
    /// so a Mandarin meeting never forces a choice between the cap and the
    /// Mandarin line.
    public static let languageRule = """
    Language: judge the meeting's language from the conversation itself, not from the brief or the guide. \
    A SAY or ASK card is a line the user may say aloud. In an English meeting, write it in English only. \
    When the other side speaks Mandarin, all or part of the time, put the English line first in "text", \
    then on new lines a natural, speakable Mandarin line and then its tone-marked pinyin. \
    The 25-word limit on "text" counts the English line only. \
    Write RECALL and FLAG cards and every "why" in English, with no pinyin. \
    A quoted phrase keeps its original words. Do not invent Chinese for English-only material.
    """

    /// How much transcript before the watermark a pass re-reads as context.
    public static let contextWindowMs = 3 * 60 * 1000

    /// The framing prompt for a call type, or nil when Auto does not run on it.
    public static func framing(for callType: CallType) -> PromptID? {
        switch callType {
        case .client: .autoAssistClient
        case .research: .autoAssistResearch
        case .internal, .personal: nil
        }
    }

    /// The prompt for one pass, or nil when the call type has no Auto or there
    /// is nothing new to act on.
    public static func build(
        callType: CallType,
        brief: String?,
        projectContext: String?,
        gaps: [GuideGap],
        currentQuestion: String?,
        prior: [String],
        userNotes: [String] = [],
        vault: String?,
        recentContext: String?,
        newWindow: String,
        resolve: PromptComposer.Resolver = PromptComposer.defaultResolver
    ) -> String? {
        guard let framing = framing(for: callType) else { return nil }
        let window = newWindow.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty else { return nil }

        var sections = [
            base(resolve(.autoAssistCards)),
            resolve(framing),
            "Already-surfaced (do NOT repeat):\n" + (prior.isEmpty ? "(none yet)" : prior.joined(separator: "\n")),
        ]
        if !callType.listens, let brief = trimmed(brief) {
            sections.append("Pre-meeting brief (the goal of this call; steer toward it):\n---\n\(brief)\n---")
        }
        if let projectContext = trimmed(projectContext) {
            sections.append("This meeting's project context (treat as ground truth):\n---\n\(projectContext)\n---")
        }
        if callType == .research {
            if let currentQuestion = trimmed(currentQuestion) {
                sections.append("Current guide question:\n\(currentQuestion)")
            }
            if !gaps.isEmpty {
                sections.append("Guide gaps (questions already passed, skipped or covered thinly):\n" + gaps.map(line).joined(separator: "\n"))
            }
        }
        if let vault = trimmed(vault) {
            sections.append("Relevant project vault material for what's being discussed (use for RECALL/FLAG; cite the source; do not fabricate):\n---\n\(vault)\n---")
            sections.append("To cite one of those documents, set \"sourceId\" on the card to its bracketed ID exactly as shown (for example \"S1\"). Only those IDs are accepted. A card with any other value, or none, shows no citation.")
        }
        let notes = userNotes.compactMap(trimmed)
        if !notes.isEmpty {
            sections.append("Notes the user typed during this call (authoritative; trust them over the transcript):\n" + notes.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let recentContext = trimmed(recentContext) {
            sections.append("Earlier conversation (context only; do not make cards about it):\n\(recentContext)")
        }
        sections.append("New conversation since the last pass (act on this):\n\(window)")
        return sections.joined(separator: "\n\n")
    }

    /// The JSON contract with "Write in English." replaced by `languageRule`.
    /// An edited contract without that sentence gets the rule appended, so
    /// the language rule always reaches the model once.
    public static func base(_ cards: String) -> String {
        guard cards.contains(englishOnlySentence) else {
            return cards.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + languageRule
        }
        return cards.replacingOccurrences(of: englishOnlySentence, with: languageRule)
    }

    static func line(_ gap: GuideGap) -> String {
        let chinese = gap.titleZH.map { " / \($0)" } ?? ""
        return "- [\(gap.qid)] \(gap.title)\(chinese) (\(gap.detail))"
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
