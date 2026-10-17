import Foundation

/// Every user-tunable prompt in RTI, as one flat registry.
///
/// Prompts used to be `static let` literals scattered across `PromptCatalogue`
/// (on-demand actions) and the Auto-mode controller (a background JSON job),
/// so they could neither be surfaced in Settings nor edited without a rebuild.
/// This enum is the single source of truth for the *default* text of each one;
/// `PromptStore` (app side) layers user overrides on top and resolves them.
///
/// Pure value type in RTICore: no UserDefaults, no MainActor. The defaults here
/// are exactly the strings that previously lived at the call sites, so behaviour
/// is unchanged until a user edits one.
public enum PromptID: String, CaseIterable, Sendable {
    // System
    case systemDefault
    case listenerSystemSuffix

    // Quick actions (speaker / listener framing)
    case assistSpeaker
    case listenerAssist
    case sayNext
    case followupsSpeaker
    case listenerFollowups

    // Listener research actions (fieldwork observer)
    case keyTensions
    case probe
    case themes

    // Recap (composed: a depth clause + the shared language rule)
    case recapBrief
    case recapStandard
    case recapDetailed
    case recapLanguageRule

    // Auto mode (strict-JSON background controller)
    case autoAssistCards

    // MARK: - Grouping (for the Settings UI)

    public enum Group: String, CaseIterable, Sendable {
        case system = "System"
        case quickActions = "Quick actions"
        case listener = "Listener research"
        case recap = "Recap"
        case background = "Auto mode"
    }

    public var group: Group {
        switch self {
        case .systemDefault, .listenerSystemSuffix: .system
        case .assistSpeaker, .listenerAssist, .sayNext, .followupsSpeaker, .listenerFollowups: .quickActions
        case .keyTensions, .probe, .themes: .listener
        case .recapBrief, .recapStandard, .recapDetailed, .recapLanguageRule: .recap
        case .autoAssistCards: .background
        }
    }

    /// Short human label for the Settings list.
    public var title: String {
        switch self {
        case .systemDefault: "Default system prompt"
        case .listenerSystemSuffix: "Listener system suffix"
        case .assistSpeaker: "Assist (speaker)"
        case .listenerAssist: "Assist (listener)"
        case .sayNext: "Say next"
        case .followupsSpeaker: "Follow-ups (speaker)"
        case .listenerFollowups: "Follow-ups (listener)"
        case .keyTensions: "Key tensions"
        case .probe: "What's unsaid / probe"
        case .themes: "Emerging themes"
        case .recapBrief: "Recap — brief clause"
        case .recapStandard: "Recap — standard clause"
        case .recapDetailed: "Recap — detailed clause"
        case .recapLanguageRule: "Recap — language rule"
        case .autoAssistCards: "Auto-assist cards"
        }
    }

    /// One-line description of when this prompt runs.
    public var help: String {
        switch self {
        case .systemDefault: "Base system message when the active mode has no prompt of its own."
        case .listenerSystemSuffix: "Appended to the system prompt while Listener mode is on."
        case .assistSpeaker: "✦ Assist when you're a participant — what to say next."
        case .listenerAssist: "✦ Assist when observing — what was just learned (tagged)."
        case .sayNext: "✦ Say next — a one-line draft reply (hidden in listener mode)."
        case .followupsSpeaker: "✦ Follow-ups when you're a participant."
        case .listenerFollowups: "✦ Follow-ups when observing — questions to pass the moderator."
        case .keyTensions: "✦ Key tensions — on-demand, listener mode only."
        case .probe: "✦ What's unsaid — on-demand, listener mode only."
        case .themes: "✦ Emerging themes — on-demand, listener mode only."
        case .recapBrief: "The bullet-count clause spliced into Recap at Brief depth."
        case .recapStandard: "The clause spliced into Recap at Standard depth."
        case .recapDetailed: "The clause spliced into Recap at Detailed depth."
        case .recapLanguageRule: "Shared language/format rule appended to every Recap."
        case .autoAssistCards: "Background: proactive SAY/ASK/RECALL/FLAG cards (strict JSON)."
        }
    }

    /// True when the controller that runs this prompt parses its output as JSON,
    /// so deleting the JSON-shape instruction silently breaks the feature. The
    /// Settings editor warns when an override drops a required token.
    public var isJSONContract: Bool {
        self == .autoAssistCards
    }

    /// Substrings the default relies on for downstream parsing/format. If an
    /// override removes one, the editor flags it (warn, never block).
    public var requiredTokens: [String] {
        isJSONContract ? ["JSON"] : []
    }

    /// The canonical default text — exactly what shipped before this registry
    /// existed. `PromptStore` returns an override when one is set, else this.
    public var defaultText: String {
        PromptDefaults.text(for: self)
    }

    /// Stable content hash of the default, used to detect when a shipped default
    /// has changed since the user last edited their override (FNV-1a, stable
    /// across runs unlike `Hashable`).
    public var defaultHash: String {
        PromptDefaults.fnv1a(defaultText)
    }
}

/// The default prompt bodies, kept out of `PromptID` so the enum stays a thin
/// index. Shared clauses are factored to constants where the text is byte
/// identical across prompts; where the wording legitimately differs per prompt
/// (e.g. the pinyin examples), the full text is inlined to preserve behaviour.
public enum PromptDefaults {
    public static func text(for id: PromptID) -> String {
        switch id {
        case .systemDefault:
            """
            You are RTI, a real-time meeting assistant. The user is in an active conversation.
            Keep responses short (under 120 words), direct, and actionable. Use simple markdown
            where it helps (bullets, **bold** for key terms). If you don't know something, say so briefly.

            If the transcript context starts with a "## User notes" block, treat those notes as
            authoritative corrections from the user (e.g. name spellings, identity clarifications).
            Prefer them over what appears in the raw transcript.
            """

        case .listenerSystemSuffix:
            "The user is a PASSIVE LISTENER in this meeting — observing, not speaking. Never draft lines for them to say; frame help as observations, flags, and questions they could pass to whoever is leading."

        case .assistSpeaker:
            "Based on the recent conversation, suggest what I should say or ask next (the suggested line itself should be in the conversation's language). Be concise — max 3 short lines of framing in ENGLISH."

        case .listenerAssist:
            """
            I'm a researcher passively observing this session. Surface what I just LEARNED — not what to say (I never speak). Glanceable in 5 seconds, not a paragraph.

            Flag the single most significant thing in the recent conversation. Output EXACTLY two lines with a BLANK LINE between them (so they render as separate lines, not one run-on):

            **[TAG]** <one line: what was said or revealed; include the key verbatim with its speaker if there is one>

            **Matters:** <one line: why this is significant for the research objective>

            TAG is one of: FINDING (a clear insight or need), TENSION (views split within the group), CONTRADICTION (someone contradicts themselves or earlier consensus), NEW THREAD (an unexpected topic worth attention), MISSED (the discussion moved past something important without probing it).

            Reply in ENGLISH. Original-language terms ALWAYS as term (pinyin, English meaning) — e.g. 得体 (détǐ, appropriate) — never bare Chinese. Max ~25 words per line. Keep the blank line between the two lines. No preamble, nothing else.
            """

        case .sayNext:
            "Given the conversation so far, draft exactly one short reply I could say next, in the language the conversation is being held in. One line, natural, in my voice. No preamble."

        case .followupsSpeaker:
            "List 3 thoughtful follow-up questions I could ask the other person right now, written in the conversation's language with an ENGLISH gloss in parentheses. Bullet points, one line each."

        case .listenerFollowups:
            "I'm a passive listener. List 3 sharp questions the discussion leader could ask right now to deepen the conversation — questions I could quietly pass along, each in the conversation's language with an ENGLISH gloss in parentheses. Bullet points, one line each."

        case .keyTensions:
            """
            I'm a researcher observing this session (I never speak). Surface the KEY TENSIONS so far — points where participants disagree, where one person's view cuts against another's, or where someone is visibly torn.

            Output up to 3 bullets, most significant first. Each bullet ONE line:
            - **<the tension in 4–8 words>** — who holds which side, with the key verbatim if there is one.

            If there's no real tension yet, say "No clear tension yet — views still converging." Reply in ENGLISH. Original-language terms ALWAYS as term (pinyin, English meaning) — never bare Chinese. No preamble.
            """

        case .probe:
            """
            I'm a researcher observing this session (I never speak). Surface what's been LEFT UNSAID or under-explored — the threads a good moderator should probe next.

            Output up to 3 bullets, each ONE line:
            - **<what to probe in 4–8 words>** — the question I'd quietly pass to the moderator, written in the conversation's language with an ENGLISH gloss in parentheses.

            Reply in ENGLISH framing. Bare Chinese never — term (pinyin, English meaning). No preamble.
            """

        case .themes:
            """
            I'm a researcher observing this session (I never speak). Name the EMERGING THEMES across the conversation so far — the recurring needs, attitudes, or patterns starting to cohere, not one-off remarks.

            Output up to 4 bullets, each ONE line:
            - **<theme in 3–6 words>** — the evidence (who said what), 1 line.

            Reply in ENGLISH. Original-language terms ALWAYS as term (pinyin, English meaning) — never bare Chinese. No preamble.
            """

        case .recapBrief:
            "in 1–2 short bullets — only the single most important thread or decision right now. No headers."

        case .recapStandard:
            "in 3–5 short bullets: what was discussed, decisions, open items."

        case .recapDetailed:
            "in 8–12 bullets grouped under short bold topic headers: cover each distinct topic raised, who said what, decisions, points of disagreement, and open threads. Thorough but still skimmable."

        case .recapLanguageRule:
            "Reply in ENGLISH regardless of the conversation's language. When you keep an original-language term, ALWAYS write it as term (pinyin/romanization, English meaning) — e.g. 健身穿搭 (jiànshēn chuāndā, workout outfits) — never bare Chinese the reader might not parse."

        case .autoAssistCards:
            """
            You are sitting beside the user during a live meeting as their proactive
            "what should I do next?" rail. You see the recent conversation, the project
            this meeting is about, and relevant knowledge already in the project's
            vault. Surface only GENUINELY USEFUL, in-the-moment next moves — a few
            cards, one, or none.

            Output ONLY JSON, no prose, no markdown fences:
            {
              "cards": [
                {
                  "kind": "SAY | ASK | RECALL | FLAG",
                  "text": "<=25 words: the suggestion itself — the line to say, the question to ask, the fact to recall, or the thing to flag>",
                  "why": "<=15 words: why it's relevant right now>",
                  "source": "<the project document or transcript this draws on, or null>"
                }
              ]
            }

            KINDS:
            - SAY: a strong point, clarification, or confirmation line to say now.
            - ASK: a sharp question or follow-up worth raising before the thread moves on.
            - RECALL: a relevant fact from the project's vault — what a participant said
              in a research session, a prior finding, a report conclusion, a status
              detail — ESPECIALLY when the other party just asked about that topic.
              Only surface a RECALL when the provided vault material actually supports
              it; cite the source. Never invent a finding or a quote.
            - FLAG: a contradiction with the project record, a claim to verify, a risk,
              or an unresolved owner/date that should be pinned down.

            Rules:
            - Only NEW cards prompted by THIS window. Do NOT repeat anything in the
              already-surfaced list below.
            - High bar. If nothing in this window genuinely warrants a card, return
              {"cards": []}. Silence beats noise — the user is in a live conversation.
            - Be specific and immediately usable. Prefer cards like "Ask who owns X
              and by when" or "Confirm whether Y is now decided." No generic coaching
              ("listen actively"), no restating what was just said.
            - Ground RECALL/FLAG cards in the project context or vault material given;
              do not fabricate. Write in English.
            """
        }
    }

    /// Stable 64-bit FNV-1a hash, hex-encoded. Used to detect default drift
    /// across app versions (Swift's `Hashable` is seeded per-process).
    public static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
