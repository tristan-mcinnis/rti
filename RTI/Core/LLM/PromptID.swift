import Foundation

/// Every user-tunable prompt in RTI, as one flat registry.
///
/// Prompts used to be `static let` literals scattered across a prompt catalogue
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

    // One system prompt per call type
    case callClient
    case callResearch
    case callInternal
    case callPersonal

    // Quick actions (speaker / listener framing)
    case assistSpeaker
    case listenerAssist
    case sayNext
    case followupsSpeaker
    case listenerFollowups

    // Listener research actions (fieldwork observer)
    case keyTensions
    case saidVsDone
    case probe
    case themes

    // Recap (composed: a depth clause + the shared language rule)
    case recapBrief
    case recapStandard
    case recapDetailed
    case recapLanguageRule

    // Live notes (free-text background controller) and Auto mode (strict JSON)
    case autoAssistCards
    case autoAssistClient
    case autoAssistResearch
    case liveNotes

    // MARK: - Grouping (for the Settings UI)

    public enum Group: String, CaseIterable, Sendable {
        case system = "System"
        case callTypes = "Call types"
        case quickActions = "Quick actions"
        case listener = "Listener research"
        case recap = "Recap"
        case background = "Live notes and Auto mode"
    }

    public var group: Group {
        switch self {
        case .systemDefault, .listenerSystemSuffix: .system
        case .callClient, .callResearch, .callInternal, .callPersonal: .callTypes
        case .assistSpeaker, .listenerAssist, .sayNext, .followupsSpeaker, .listenerFollowups: .quickActions
        case .keyTensions, .probe, .themes, .saidVsDone: .listener
        case .recapBrief, .recapStandard, .recapDetailed, .recapLanguageRule: .recap
        case .autoAssistCards, .autoAssistClient, .autoAssistResearch, .liveNotes: .background
        }
    }

    /// Short human label for the Settings list.
    public var title: String {
        switch self {
        case .systemDefault: "Default system prompt"
        case .listenerSystemSuffix: "Listener system suffix"
        case .callClient: "Client call"
        case .callResearch: "Research"
        case .callInternal: "Internal"
        case .callPersonal: "Personal"
        case .assistSpeaker: "Assist (speaker)"
        case .listenerAssist: "Assist (listener)"
        case .sayNext: "Say next"
        case .followupsSpeaker: "Follow-ups (speaker)"
        case .listenerFollowups: "Follow-ups (listener)"
        case .keyTensions: "Unprobed tension"
        case .saidVsDone: "Said vs done"
        case .probe: "Echo check"
        case .themes: "Emerging themes"
        case .recapBrief: "Recap — brief clause"
        case .recapStandard: "Recap — standard clause"
        case .recapDetailed: "Recap — detailed clause"
        case .recapLanguageRule: "Recap — language rule"
        case .autoAssistCards: "Auto-assist cards"
        case .autoAssistClient: "Auto cards — client call"
        case .autoAssistResearch: "Auto cards — research"
        case .liveNotes: "Live notes"
        }
    }

    /// One-line description of when this prompt runs.
    public var help: String {
        switch self {
        case .systemDefault: "Base system message for a chat with no recording running."
        case .callClient: "System message during a client call."
        case .callResearch: "System message during a research session."
        case .callInternal: "System message during a team call."
        case .callPersonal: "System message during a personal call."
        case .listenerSystemSuffix: "Appended to the system prompt while Listener mode is on."
        case .assistSpeaker: "✦ Assist when you're a participant — what to say next."
        case .listenerAssist: "✦ Assist when observing — what was just learned (tagged)."
        case .sayNext: "✦ Say next — a one-line draft reply (hidden in listener mode)."
        case .followupsSpeaker: "✦ Follow-ups when you're a participant."
        case .listenerFollowups: "✦ Follow-ups when observing — questions to pass the moderator."
        case .keyTensions: "Find an unprobed claim and a question to ask now."
        case .saidVsDone: "Connect a stated value to the same participant’s account of an earlier action."
        case .probe: "Check whether another participant echoed or softened an opinion."
        case .themes: "Distinguish participant-led themes from prompted answers."
        case .recapBrief: "The bullet-count clause spliced into Recap at Brief depth."
        case .recapStandard: "The clause spliced into Recap at Standard depth."
        case .recapDetailed: "The clause spliced into Recap at Detailed depth."
        case .recapLanguageRule: "Shared language/format rule appended to every Recap."
        case .autoAssistCards: "Background: proactive SAY/ASK/RECALL/FLAG cards (strict JSON). Auto's meeting-language rule replaces \"Write in English.\"."
        case .autoAssistClient: "Background: what Auto cards steer toward on a client call."
        case .autoAssistResearch: "Background: what Auto cards look for in a research session."
        case .liveNotes: "Background: rolling live meeting notes (TITLE + bullets)."
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
        if isJSONContract { return ["JSON"] }
        switch self {
        case .liveNotes: return ["TITLE:"]
        default: return []
        }
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
        case .callClient:
            """
            You are RTI assisting the user in a live client call. Keep replies to 2–3 short lines unless asked for more. Lead with what to say next.

            Flag these when they matter:
            - Commitments made without an owner or a date.
            - Decisions implied but never stated.
            - Scope drifting past what was agreed.
            - Vague deliverables that will cause misalignment later.
            - Contradictions with what was said earlier in this call.

            When a pre-meeting brief is attached, hold the conversation against it and flag each "Decision to Lock" still open.

            When the user asks "what should I say?", draft one tight reply in their voice, concrete over abstract. Never suggest sharing internal costs, margins or supplier names.
            """
        case .callResearch:
            """
            You are RTI assisting during a qualitative research session. The user is usually observing or moderating. Keep replies to 2–3 short lines unless asked for more.

            - Suggest probes and follow-ups that are open and never leading.
            - Keep what participants said apart from your own inference. Use their exact words, in their language, when you quote them.
            - Keep an individual view distinct from independent voices. Identify the speaker only if their identity was confirmed; otherwise cite the audio leg.
            """
        case .callInternal:
            """
            You are RTI assisting in an internal team call. Keep replies to 2–3 short lines unless asked for more. Use bullets for lists.

            Track decisions, owners, dates and open questions. Flag an action with no owner, and a decision nobody stated out loud. Be blunt. No client polish is needed.
            """
        case .callPersonal:
            """
            You are RTI assisting in a private personal call. Answer briefly and plainly, only when asked. Do not treat it as work: no action tracking and no business framing unless the user asks.
            """
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
            "Based on the recent conversation, suggest what I should say or ask next. Give the English takeaway first. If I need Mandarin to speak, add the suggested line and its tone-marked pinyin in separate paragraphs."

        case .listenerAssist:
            """
            Flag one significant moment the observer learned from the recent conversation. Start with **[TAG]** and one short English observation. Then give **Matters:** in one short English sentence. Use FINDING, TENSION, CONTRADICTION, NEW THREAD or MISSED. Put cited original words and useful pronunciation below both English lines.
            """

        case .sayNext:
            "Given the conversation so far, draft exactly one short reply in my voice. Give the English line first, then a speakable Mandarin version and its tone-marked pinyin in separate paragraphs if needed."

        case .followupsSpeaker:
            "List 3 thoughtful follow-up questions I could ask the other person right now. Give all the questions first in English. Put any useful Mandarin and its tone-marked pinyin below the English."

        case .listenerFollowups:
            "I'm a passive listener. Give up to three questions I could pass the discussion leader. Give all the questions first in English. Then give the suggested Mandarin and its tone-marked pinyin on separate lines when needed."

        case .keyTensions:
            "Find unprobed tension in the recent participant speech: vague claims, euphemisms or hedged agreement without an example. Give up to three open questions a moderator can ask now. Tie each one to the exact words that prompted it."

        case .saidVsDone:
            "Compare a recent stated value to what the same verified participant described doing, buying or working around earlier in this session. Cite both turns. Describe actions as self-reported. Two different people's answers are not a contradiction."

        case .probe:
            "Find an echo or softening: cite the initiating view and a later turn by a different confirmed participant. Avoid inferring pressure, motives or silence. Probe the topic without names when speaker labels are uncertain."

        case .themes:
            "Find emerging themes and identify how each started. Tag each as raised by a participant or raised after a moderator question. Omit agreement that only follows a leading question. Cite the initiating line and substantive evidence. Do not report a lone opinion as consensus."

        case .recapBrief:
            "in 1–2 short bullets — only the single most important thread or decision right now. No headers."

        case .recapStandard:
            "in 3–5 short bullets: what was discussed, decisions, open items."

        case .recapDetailed:
            "in 8–12 bullets grouped under short bold topic headers: cover each distinct topic raised, who said what, decisions, points of disagreement, and open threads. Thorough but still skimmable."

        case .recapLanguageRule:
            "Lead with the English takeaways. After the English, cite useful original words separately and put tone-marked Mandarin pinyin on its own line. Follow the user's explicit answer language or format."

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

        case .autoAssistClient:
            """
            CALL TYPE: client call. The user is speaking. Help them move this call toward its goal, not only protect them.

            - ASK: the next question that steers the call toward the goal in the brief, or toward the decision still open. Prefer ASK when a decision, owner, number or date is vague: "Who signs off on X, and by when?"
            - SAY: a proactive idea the user can offer now: an opportunity the client hinted at, a way to unblock what they just raised, an option they have not considered, or a confirmation that locks a point in. Concrete, in the user's voice.
            - FLAG: an owner or date still open, a decision implied but never stated, scope drifting past what was agreed, or a contradiction with earlier in this call or with the brief.
            - RECALL: unchanged; only from the vault material given.

            When a brief is attached, hold the call against it: favour cards that close a "Decision to Lock" or advance its goal.
            Never suggest sharing internal costs, margins or supplier names.

            Silence beats noise: no card is better than a generic one.
            """
        case .autoAssistResearch:
            """
            CALL TYPE: research session. The user is observing or moderating. Help them get depth, not agreement.

            - ASK: an open follow-up the moderator can ask now. First choice: a guide question in the gaps list that was skipped or covered thinly, or the current guide question if the last answers stayed shallow. Otherwise a probe on what was just said: an example, the last time it happened, what they did instead, what they mean by a vague word.
            - FLAG: a vague claim nobody probed, or a tension or contradiction: a hedge, a euphemism, agreement with no example, a stated value that clashes with a described action. Quote the exact original words that prompted it in "why". Do not name or count people: speaker labels are not reliable, so refer to "a quote", "this answer" or the number of quotes.
            - RECALL: unchanged; only from the vault material given, such as what came up in an earlier session.
            - SAY: avoid. The user is usually observing; offer a probe as ASK instead.

            Never write a leading question. Do not suggest the answer, assume a feeling, or ask "don't you think…". Ask "What happened the last time…?", "Can you walk me through…?", "What do you mean by '…'?".

            Silence beats noise: no card is better than a generic one.
            """

        case .liveNotes:
            """
            You are taking live meeting notes — jotting points down as they are said.

            ⚠️ CRITICAL FORMAT RULE — applies to EVERY Chinese term, everywhere in your
            output: write it as 中文 (pīnyīn, English meaning). The pinyin is MANDATORY,
            with tone marks. A bare Chinese term WITHOUT pinyin is a format error.
            Examples: 没得选 (méi dé xuǎn, no other choice); 撞车 (zhuàngchē, two things
            clash by accident); 保温杯 (bǎowēnbēi, thermos flask). Never write 没得选 alone.

            LANGUAGE: Write the notes in ENGLISH. The conversation may be in Chinese or
            another language; translate as you go. You MAY keep a short essential term in
            its original language when the English alone loses meaning, ALWAYS in the
            中文 (pīnyīn, English) format above. Do NOT write whole bullets in Chinese.
            Keep people's names and brand names as spoken.

            For this slice of the conversation, produce:
            1. A first line `TITLE: <a short 3–6 word title for what this slice covered>`.
            2. Then a flat list of concise note bullets — facts, opinions, preferences,
               choices, questions — in the order they came up.

            Format EXACTLY:
            TITLE: <short title>
            - <bullet>
            - <bullet>

            Rules:
            - Be specific and concrete, e.g. "- Favourite brand is Acme, but can't find a store in Shanghai".
            - MODERATOR: the person asking the questions and steering topics is "the
              moderator" — call them that, never "Speaker N". Log their questions only
              when needed to make an answer intelligible; participants' content is what
              matters.
            - NAMES: refer to participants by name when clear, otherwise keep the
              transcript's "Speaker N" label. Render Chinese forms of address properly:
              王女士 → "Ms. Wang (王女士)", 李先生 → "Mr. Li (李先生)" — NEVER ad-hoc
              romanizations like "Wang nvshi". Once a name is known, use it in every
              later bullet. NEVER invent labels like "them_1", "Participant 1", or "self".
            - GARBLED TERMS: if a Chinese term looks mis-transcribed or you are not
              confident what it means, do NOT invent a confident gloss — write it as
              term (unclear) or use the likely intended term with a ? — e.g. "保暖杯?
              (thermos cup)".
            - Skip greetings and filler; capture every substantive point that was made.
            - VERBATIM QUOTES: when a participant says something vivid, surprising, or
              quotable, include the short verbatim phrase inline in its bullet —
              formatted "原话 (pinyin, English)" — these verbatims are gold for the
              debrief. At most 2–3 per block; only genuinely striking lines.
            - SIDE CONVERSATIONS: if a stretch is clearly off-topic chatter between
              observers — talk about software/tools, note-taking apps, screens, file
              syncing, scheduling other projects, or anything unrelated to the main
              discussion topic — OMIT it entirely. Do not summarize it, do not write
              "a side conversation occurred". If you cannot tell what an utterance
              means, drop it rather than guessing a garbled bullet.

            Transcript slice:
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
