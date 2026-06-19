import Foundation

/// How long a Recap (⌘⌥R / the primary action) runs. Sticky across sessions
/// — heavy Recap users (a live FGD observer hitting it every few minutes)
/// set their preferred length once instead of re-picking it each time.
///
/// Pure value type: lives in RTICore so `PromptCatalogue.recap(_:)` is fully
/// self-contained and testable without hosting the app.
public enum RecapDepth: String, CaseIterable {
    case brief, standard, detailed

    public var label: String {
        switch self {
        case .brief: "Brief (1–2 bullets)"
        case .standard: "Standard (3–5 bullets)"
        case .detailed: "Detailed (grouped, ~8–12)"
        }
    }

    /// The depth-specific clause spliced into the shared recap prompt.
    public var instruction: String {
        switch self {
        case .brief:
            "in 1–2 short bullets — only the single most important thread or decision right now. No headers."
        case .standard:
            "in 3–5 short bullets: what was discussed, decisions, open items."
        case .detailed:
            "in 8–12 bullets grouped under short bold topic headers: cover each distinct topic raised, who said what, decisions, points of disagreement, and open threads. Thorough but still skimmable."
        }
    }
}

/// The catalogue of assistant prompts, as pure data + pure selection logic.
///
/// Previously these lived as ~48 string literals interleaved with dispatch
/// inside `LLMController` (@MainActor), so the prompt *content* and the logic
/// that *selects* among variants (listener vs speaker, recap depth, summary
/// mode) could not be reached by a test. Here they are pure: the app grabs the
/// live state (listenerMode, recapDepth, active mode) and makes one call.
///
/// Behaviour is identical to the previous in-controller constants — the strings
/// are unchanged, only relocated.
public enum PromptCatalogue {

    // MARK: - System

    /// The RTI default system message, used when the active mode has no system
    /// prompt of its own.
    public static let system = """
    You are RTI, a real-time meeting assistant. The user is in an active conversation.
    Keep responses short (under 120 words), direct, and actionable. Use simple markdown
    where it helps (bullets, **bold** for key terms). If you don't know something, say so briefly.

    If the transcript context starts with a "## User notes" block, treat those notes as
    authoritative corrections from the user (e.g. name spellings, identity clarifications).
    Prefer them over what appears in the raw transcript.
    """

    // MARK: - Quick actions (speaker / participant framing)

    /// Assist — "what should I say next". Listener variant surfaces what was
    /// learned instead, since an observer never speaks.
    public static func assist(listener: Bool) -> String {
        listener ? listenerAssist : assistSpeaker
    }

    /// Say next — a one-line draft reply. No listener variant (an observer never
    /// speaks).
    public static let sayNext = "Given the conversation so far, draft exactly one short reply I could say next, in the language the conversation is being held in. One line, natural, in my voice. No preamble."

    /// Follow-up questions. The listener variant frames them as questions to pass
    /// to the discussion leader.
    public static func followups(listener: Bool) -> String {
        listener ? listenerFollowups : followupsSpeaker
    }

    // MARK: - Recap

    /// Recap the conversation so far at the requested depth. The language/format
    /// rule is shared across depths, so the logged prompt only varies in the
    /// bullet-count clause.
    public static func recap(_ depth: RecapDepth) -> String {
        "Recap the conversation so far \(depth.instruction) \(recapLanguageRule)"
    }

    // MARK: - Summary (mode-shaped)

    /// Pick the end-of-session / on-demand summary prompt for the session's
    /// mode: interviews get a research debrief, everything else gets minutes.
    public static func summary(for kind: ModeKind) -> String {
        switch kind {
        case .interview: return interviewSummary
        default: return meetingSummary
        }
    }

    // MARK: - Listener research actions (fieldwork observer)

    /// Key tensions — points where participants disagree or are torn.
    public static let keyTensions = """
    I'm a researcher observing this session (I never speak). Surface the KEY TENSIONS so far — points where participants disagree, where one person's view cuts against another's, or where someone is visibly torn.

    Output up to 3 bullets, most significant first. Each bullet ONE line:
    - **<the tension in 4–8 words>** — who holds which side, with the key verbatim if there is one.

    If there's no real tension yet, say "No clear tension yet — views still converging." Reply in ENGLISH. Original-language terms ALWAYS as term (pinyin, English meaning) — never bare Chinese. No preamble.
    """

    /// What's unsaid / probe — threads a good moderator should chase next.
    public static let probe = """
    I'm a researcher observing this session (I never speak). Surface what's been LEFT UNSAID or under-explored — the threads a good moderator should probe next.

    Output up to 3 bullets, each ONE line:
    - **<what to probe in 4–8 words>** — the question I'd quietly pass to the moderator, written in the conversation's language with an ENGLISH gloss in parentheses.

    Reply in ENGLISH framing. Bare Chinese never — term (pinyin, English meaning). No preamble.
    """

    /// Emerging themes — recurring needs/attitudes/patterns starting to cohere.
    public static let themes = """
    I'm a researcher observing this session (I never speak). Name the EMERGING THEMES across the conversation so far — the recurring needs, attitudes, or patterns starting to cohere, not one-off remarks.

    Output up to 4 bullets, each ONE line:
    - **<theme in 3–6 words>** — the evidence (who said what), 1 line.

    Reply in ENGLISH. Original-language terms ALWAYS as term (pinyin, English meaning) — never bare Chinese. No preamble.
    """

    // MARK: - Building blocks (private)

    private static let assistSpeaker = "Based on the recent conversation, suggest what I should say or ask next (the suggested line itself should be in the conversation's language). Be concise — max 3 short lines of framing in ENGLISH."

    private static let followupsSpeaker = "List 3 thoughtful follow-up questions I could ask the other person right now, written in the conversation's language with an ENGLISH gloss in parentheses. Bullet points, one line each."

    /// Shared language/format rule for Recap, kept identical across depths so the
    /// logged prompt only varies in the bullet-count clause.
    private static let recapLanguageRule = "Reply in ENGLISH regardless of the conversation's language. When you keep an original-language term, ALWAYS write it as term (pinyin/romanization, English meaning) — e.g. 健身穿搭 (jiànshēn chuāndā, workout outfits) — never bare Chinese the reader might not parse."

    /// Listener-mode Assist: the user is observing, not speaking, so "what should
    /// I say" is the wrong frame. Surface what's notable instead.
    private static let listenerAssist = """
    I'm a researcher passively observing this session. Surface what I just LEARNED — not what to say (I never speak). Glanceable in 5 seconds, not a paragraph.

    Flag the single most significant thing in the recent conversation. Output EXACTLY two lines with a BLANK LINE between them (so they render as separate lines, not one run-on):

    **[TAG]** <one line: what was said or revealed; include the key verbatim with its speaker if there is one>

    **Matters:** <one line: why this is significant for the research objective>

    TAG is one of: FINDING (a clear insight or need), TENSION (views split within the group), CONTRADICTION (someone contradicts themselves or earlier consensus), NEW THREAD (an unexpected topic worth attention), MISSED (the discussion moved past something important without probing it).

    Reply in ENGLISH. Original-language terms ALWAYS as term (pinyin, English meaning) — e.g. 得体 (détǐ, appropriate) — never bare Chinese. Max ~25 words per line. Keep the blank line between the two lines. No preamble, nothing else.
    """

    private static let listenerFollowups = "I'm a passive listener. List 3 sharp questions the discussion leader could ask right now to deepen the conversation — questions I could quietly pass along, each in the conversation's language with an ENGLISH gloss in parentheses. Bullet points, one line each."

    /// Granola-style whole-meeting summary — runs over the FULL transcript, not
    /// the assist window. SessionArchive reuses it for the end-of-session
    /// auto-summary so chat and archive stay identical.
    private static let meetingSummary = """
    Write a structured summary of this ENTIRE meeting so far, in markdown. Work \
    only from what was actually said — no invention, no padding.

    ⚠️ CRITICAL LANGUAGE RULE — the ENTIRE summary MUST be written in ENGLISH. \
    The transcript is usually in Chinese; translate everything into English as \
    you write. Every section header below MUST stay in English exactly as given \
    (never translate a header), and every bold topic header, bullet, and \
    sentence you author MUST be English too. No Chinese sentences, bullets, or \
    headers — the ONLY Chinese permitted is an essential term kept inline as \
    中文 (pīnyīn, English meaning). If you catch yourself writing a clause in \
    Chinese, stop and translate it.

    ⚠️ CRITICAL FORMAT RULE — applies to EVERY Chinese term, everywhere including \
    the Overview: write it as 中文 (pīnyīn, English meaning). The pinyin (with tone \
    marks) is MANDATORY. A bare Chinese term with no pinyin is a format error — \
    e.g. 没得选 (méi dé xuǎn, no other choice), never 没得选 alone.

    ## Overview
    2–3 sentences: what this meeting was, what it covered, the single most \
    important takeaway.

    ## Key points
    The substantive content, grouped under short bold topic headers in the order \
    the topics arose. Concrete and specific — keep names, brands, numbers, and \
    essential original-language terms as term (pinyin, English meaning) — e.g. \
    松弛 (sōngchí, relaxed ease), 背刺 (bèicì, price betrayal). Attribute \
    views to named people where clear, otherwise by role.

    ## Decisions & agreements
    Anything decided, agreed, or confirmed. If none, write "None."

    ## Tensions & contradictions
    Where views split, or someone contradicted themselves or the group. These \
    are often the most valuable — be precise about who held which side. If \
    none, write "None observed."

    ## Open questions & follow-ups
    Unresolved threads, things someone said they'd do, topics raised but not \
    explored.

    Rules: skip greetings, logistics, and side conversations about tools or \
    scheduling; never use raw transcript labels like "them_1".
    """

    /// Fieldwork-debrief summary — used when the session ran in Interview mode
    /// (IDI/FGD observation). A research read-out, not meeting minutes.
    private static let interviewSummary = """
    Write a QUALITATIVE RESEARCH DEBRIEF of this entire session so far, in \
    markdown. Work only from what was actually said — no invention, no padding. \
    This was a research interview/focus group; treat the speakers as \
    RESPONDENTS, not meeting attendees.

    ⚠️ CRITICAL LANGUAGE RULE — the ENTIRE debrief MUST be written in ENGLISH. \
    The transcript is usually in Chinese; translate everything into English as \
    you write. Every section header below MUST stay in English exactly as given \
    (never translate a header), and every bold theme header, bullet, and \
    sentence you author MUST be English too. The ONLY Chinese permitted is (a) \
    an essential term kept inline as 中文 (pīnyīn, English meaning), and (b) the \
    verbatim quotes in "Verbatims worth keeping", which stay in the original \
    language with an English gloss. No other Chinese sentences, bullets, or \
    headers. If you catch yourself writing a clause in Chinese, translate it.

    ⚠️ CRITICAL FORMAT RULE — every Chinese term, everywhere: write it as 中文 \
    (pīnyīn, English meaning). Pinyin with tone marks is MANDATORY; a bare \
    Chinese term is a format error — e.g. 性价比 (xìngjiàbǐ, value for money).

    ## Overview
    2–3 sentences: who we spoke to, what this session explored, the single most \
    important takeaway for the research.

    ## Who we heard from
    One line per distinct respondent you can tell apart (by Speaker number if no \
    name) — their relevant profile in their own terms (e.g. "Speaker 2 — 5-yr \
    road+trail runner, two full marathons").

    ## What they told us
    The substantive content under short bold theme headers, in order of \
    importance to the research question — needs, behaviours, attitudes, decision \
    drivers. Attribute to specific respondents. Keep names, brands, places, and \
    essential terms as term (pinyin, English meaning).

    ## Tensions & differences
    Where respondents split, or contradicted each other or themselves — the most \
    analytically valuable material. Be precise about who held which side. If \
    none, "None observed."

    ## Verbatims worth keeping
    3–6 quotes that carry a finding, each as `Speaker N` (or name): "the line." \
    Keep the original language plus a gloss.

    ## Implications (the "so what")
    What these findings MEAN for the research question — the interpretation a \
    reader should walk away with. Backward-looking only: this summarises a \
    session that already happened, so do NOT recommend what to do next, what to \
    probe, or what a future session should chase. If there are no clear \
    implications yet, write "Too early to call."

    Rules: skip warm-up logistics and recording disclaimers; never use raw \
    transcript labels like "them_1" — use "Speaker N".
    """
}
