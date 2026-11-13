import Foundation

/// Builds the one user message an Auto pass sends. Pure: the caller resolves
/// the prompt texts (`PromptStore` overrides) and gathers the live inputs.
///
/// Stable parts first, so a provider's prompt cache can reuse them from one
/// pass to the next: the JSON contract (`autoAssistCards`), the framing for
/// the call type, the one language rule, the brief, the project context, the
/// guide's section budgets and the guide position. Then the parts that change
/// every pass: surfaced cards, codebook tensions and hypotheses, signals,
/// gaps, typed notes, vault material, the earlier context, the Mandarin line
/// and the new window. Internal and personal calls get no Auto pass at all.
/// The brief goes only to calls where the user speaks (`!callType.listens`),
/// the same gate the assistant uses; guide parts go only to research.
public enum AutoAssistPrompt {
    /// The sentence older contracts ended with. The builder drops it: the
    /// language rule is its own section after the framing.
    static let englishOnlySentence = "Write in English."

    /// The one language rule an Auto pass follows, keyed on the meeting's
    /// language. Auto-only: Recap keeps its own rule (`recapLanguageRule`).
    /// The app adds pinyin itself (`AutoCardLanguage.pinyin`), so the model
    /// writes none.
    public static let languageRule = """
    Language: judge the meeting's language from the conversation itself, not from the brief or the guide. \
    Always write "text_en" in English. \
    A SAY or ASK card is a line the user may say aloud: when the other side speaks Mandarin, all or part of the time, \
    also write "text_zh", a natural, speakable Mandarin line with the same meaning. \
    In an English meeting, set "text_zh" to null. No pinyin anywhere: the app adds it. \
    Write RECALL and FLAG cards and every "why" in English. \
    A quoted phrase keeps its original words. Do not invent Chinese for English-only material.
    """

    /// Sent just before the new window when more than 30% of it is CJK
    /// (`AutoCardLanguage.isMandarin`). The controller drops a SAY or ASK
    /// card without its Mandarin line.
    public static let mandarinLine = "This conversation is mostly Mandarin: every SAY and ASK card needs \"text_zh\". A SAY or ASK card without it is dropped."

    /// Sent instead of a stale guide position: no guide pass placed the
    /// discussion in the last four minutes and the user picked no question.
    public static let guidePositionUncertainLine = "Guide position uncertain. Do not name a current guide question."

    /// How much transcript before the watermark a pass re-reads as context.
    public static let contextWindowMs = 3 * 60 * 1000

    /// Surfaced cards sent in full; older ones go as one topic line.
    public static let priorLimit = 20

    /// The framing prompt for a call type, or nil when Auto does not run on it.
    public static func framing(for callType: CallType) -> PromptID? {
        switch callType {
        case .client: .autoAssistClient
        case .research: .autoAssistResearch
        case .internal, .personal: nil
        }
    }

    /// The prompt for one pass, or nil when the call type has no Auto or there
    /// is nothing new to act on. `prior` is the last `priorLimit` surfaced
    /// cards; `priorTopics` names the older ones in one line. `codes` are the
    /// codebook's tensions and hypotheses with counts, `sectionBudgets` the
    /// guide's minute budgets, `signals` facts the code worked out (a section
    /// over budget, a silent system leg).
    public static func build(
        callType: CallType,
        brief: String?,
        projectContext: String?,
        gaps: [GuideGap],
        currentQuestion: String?,
        guidePositionUncertain: Bool = false,
        sectionBudgets: [String] = [],
        prior: [String],
        priorTopics: String? = nil,
        codes: [String] = [],
        signals: [String] = [],
        userNotes: [String] = [],
        vault: String?,
        recentContext: String?,
        mandarin: Bool = false,
        newWindow: String,
        resolve: PromptComposer.Resolver = PromptComposer.defaultResolver
    ) -> String? {
        guard let framing = framing(for: callType) else { return nil }
        let window = newWindow.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty else { return nil }

        // Stable parts.
        var sections = [base(resolve(.autoAssistCards)), resolve(framing), languageRule]
        if !callType.listens, let brief = trimmed(brief) {
            sections.append("Pre-meeting brief (the goal of this call; steer toward it):\n---\n\(brief)\n---")
        }
        if let projectContext = trimmed(projectContext) {
            sections.append("This meeting's project context (treat as ground truth):\n---\n\(projectContext)\n---")
        }
        if callType == .research {
            if !sectionBudgets.isEmpty {
                sections.append("Guide section budgets:\n" + sectionBudgets.map { "- \($0)" }.joined(separator: "\n"))
            }
            if let currentQuestion = trimmed(currentQuestion) {
                sections.append("Current guide question:\n\(currentQuestion)")
            } else if guidePositionUncertain {
                sections.append(guidePositionUncertainLine)
            }
        }

        // Parts that change every pass.
        var surfaced = "Already-surfaced (do NOT repeat, even in other words):\n" + (prior.isEmpty ? "(none yet)" : prior.joined(separator: "\n"))
        if let priorTopics = trimmed(priorTopics) {
            surfaced += "\nEarlier cards were about: \(priorTopics)"
        }
        sections.append(surfaced)
        if callType == .research {
            if !codes.isEmpty {
                sections.append("Codebook tensions and hypotheses (quote counts, never people):\n" + codes.joined(separator: "\n"))
            }
            if !signals.isEmpty {
                sections.append("Signals (facts from the app):\n" + signals.map { "- \($0)" }.joined(separator: "\n"))
            }
            if !gaps.isEmpty {
                sections.append("Guide gaps (questions already passed, skipped or covered thinly):\n" + gaps.map(line).joined(separator: "\n"))
            }
        }
        let notes = userNotes.compactMap(trimmed)
        if !notes.isEmpty {
            sections.append("Notes the user typed during this call (authoritative; trust them over the transcript):\n" + notes.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let vault = trimmed(vault) {
            sections.append("Relevant project vault material for what's being discussed (use for RECALL/FLAG; cite the source; do not fabricate):\n---\n\(vault)\n---")
            sections.append("To cite one of those documents, set \"source\" on the card to its bracketed ID exactly as shown (for example \"S1\"). Only those IDs are accepted. A RECALL with any other value, or none, is dropped.")
        }
        if let recentContext = trimmed(recentContext) {
            sections.append("Earlier conversation (context only; do not make cards about it):\n\(recentContext)")
        }
        if mandarin {
            sections.append(mandarinLine)
        }
        sections.append("New conversation since the last pass (act on this):\n\(window)")
        return sections.joined(separator: "\n\n")
    }

    /// The JSON contract without an older "Write in English." sentence:
    /// the language rule follows the framing as its own section.
    public static func base(_ cards: String) -> String {
        cards.replacingOccurrences(of: englishOnlySentence, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
