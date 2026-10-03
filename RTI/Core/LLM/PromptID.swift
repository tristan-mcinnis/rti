import Foundation

/// Every user-tunable prompt in RTI, as one flat registry.
///
/// Prompts used to be `static let` literals scattered across `PromptCatalogue`
/// (on-demand actions) and the four analysis controllers (background JSON jobs),
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

    // Session summaries (mode-shaped)
    case meetingSummary
    case interviewSummary

    // Background analysis (strict-JSON or fixed-format controllers)
    case findingsLedger
    case autoAssistCards
    case dgParse
    case dgMatch
    case liveNotes

    // MARK: - Grouping (for the Settings UI)

    public enum Group: String, CaseIterable, Sendable {
        case system = "System"
        case quickActions = "Quick actions"
        case listener = "Listener research"
        case recap = "Recap"
        case summaries = "Session summaries"
        case background = "Background analysis"
    }

    public var group: Group {
        switch self {
        case .systemDefault, .listenerSystemSuffix: .system
        case .assistSpeaker, .listenerAssist, .sayNext, .followupsSpeaker, .listenerFollowups: .quickActions
        case .keyTensions, .probe, .themes: .listener
        case .recapBrief, .recapStandard, .recapDetailed, .recapLanguageRule: .recap
        case .meetingSummary, .interviewSummary: .summaries
        case .findingsLedger, .autoAssistCards, .dgParse, .dgMatch, .liveNotes: .background
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
        case .meetingSummary: "Meeting summary"
        case .interviewSummary: "Interview debrief"
        case .findingsLedger: "Live intelligence ledger"
        case .autoAssistCards: "Auto-assist cards"
        case .dgParse: "Discussion guide — parse"
        case .dgMatch: "Discussion guide — match"
        case .liveNotes: "Live notes"
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
        case .meetingSummary: "Full-transcript summary for meeting-family modes."
        case .interviewSummary: "Full-transcript research debrief for Interview mode."
        case .findingsLedger: "Background: running live ledger of decisions/actions/questions/risks (strict JSON)."
        case .autoAssistCards: "Background: proactive SAY/ASK/RECALL/FLAG cards (strict JSON)."
        case .dgParse: "Background: parse a discussion guide into an outline (strict JSON)."
        case .dgMatch: "Background: match guide questions to the transcript (strict JSON)."
        case .liveNotes: "Background: rolling live meeting notes (TITLE + bullets)."
        }
    }

    /// True when the controller that runs this prompt parses its output as JSON,
    /// so deleting the JSON-shape instruction silently breaks the feature. The
    /// Settings editor warns when an override drops a required token.
    public var isJSONContract: Bool {
        switch self {
        case .findingsLedger, .autoAssistCards, .dgParse, .dgMatch: true
        default: false
        }
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
    /// Shared strict pinyin/format rule. Identical wording in the two summary
    /// prompts, so it is factored here; editing it updates both defaults.
    static let pinyinFormatRuleSummary = """
    write it as 中文 \
    (pīnyīn, English meaning). The pinyin (with tone \
    marks) is MANDATORY.
    """

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

        case .meetingSummary:
            """
            You are writing the meeting record of this ENTIRE meeting, in two parts, in this exact order. Work only from what was actually said; no invention, no padding.

            BEFORE WRITING, build a speaker map. Scan the whole transcript for introductions, sign-offs, and how people address each other ("I will start first, and Helen can chime in", "bye Sam") and decide once who each voice is. Rules:
            - One voice = one person. Never split a single speaker into two names, and never treat "Me" and a numbered speaker as different people.
            - Use a real name only when the transcript supports it; otherwise use a role ("the Acme side", "the moderator", "the researcher"). Never write raw labels like "Speaker 3" or "them_1".
            - If two similar names could be the same or different people (e.g. Helene vs Helena), keep them distinct and add one line flagging the possible name collision; never silently merge or pick one.
            - A claim you cannot place is marked "(unattributed)". Do not guess names. When someone relays a request or concern from their side, the side owns it, not the relayer.

            TRANSCRIPTION UNCERTAINTY: the transcript is machine-generated and garbles names, brands, and numbers. When a proper noun or figure looks garbled, write your best reading followed by (transcript: "heard text"). Never silently substitute a better-known brand or a clean number for an unclear one, and never present a normalized garble as fact.

            LANGUAGE: English throughout; translate Chinese as you write. In PART 2 a Chinese term may appear inline as 中文 (pīnyīn with tone marks, English meaning) on FIRST mention only, plain English after that. PART 1 contains no Chinese characters and no pinyin.

            BANNED, never write: "The single most important takeaway", "the core tension is", "delve", "It's worth noting", "In conclusion", "In summary", "overall", "aligns with", "key stakeholders", "leverage" (as a verb), "robust", "comprehensive", "successfully", "valuable meeting", "productive meeting". No sentence may describe the summary itself. No em dashes anywhere; use commas, periods, or parentheses.

            PART 1 — SHARE BRIEF
            First line exactly: === SHARE BRIEF ===
            HARD LIMIT 1800 characters. Plain sentences and "- " bullets only; NO markdown headers, NO bold, NO tables. Written to paste straight into Slack/WeChat/email with zero editing. Order:
            1. One line: what meeting, who (organisations and names), when, how long.
            2. Decisions, each: - [DECIDED] <what> ; <who agreed>
            3. Actions, each: - [ACTION] <owner>: <task>. Due <date>, or "no date". Owner is always a named person or a side, never "someone". A request for a deadline, a document, an intro, or missing access IS an action.
            4. At most 3 lines of what is still open.

            PART 2 — FULL RECORD
            First line exactly: === FULL RECORD ===
            Markdown, exactly these sections:
            ## Attendees — one line per side: organisation, names and roles as introduced. Note anyone who joined late, left early, or was referenced as absent.
            ## Overview — 2-3 sentences: what the meeting was and what changed because of it. State the biggest outcome as plain content, never as commentary about takeaways.
            ## Key points — the substance under short, specific bold topic headers in the order topics arose. Concrete: names, brands, numbers, dates, who said what, every claim attributed. Each fact appears here exactly ONCE; later sections may reference it but never restate it.
            ## Decisions & agreements — who proposed and who agreed, kept distinct ("X proposed, Y confirmed" is not "Y requested"). "None." if none.
            ## Tensions & contradictions — only tensions the participants themselves surfaced, or that two attributed statements directly create. Name who held which side. Do not manufacture tension from a topic the room agreed to study. "None observed." if none.
            ## Open questions & follow-ups — an owner named on each line. No filler rows: an unknown future outcome is not an open question.
            ## Verbatims worth keeping — up to 5 short quotes with speaker; keep the original language with an English gloss.

            COVERAGE RULES:
            - Working agreements and logistics that create obligations are content, not chatter: agreed communication channels, access problems (SharePoint, files, recordings), and scheduling facts that change anyone's prep time. Skip only greetings, tool fumbling, and screen-share noise.
            - Every deadline carries its direction: who delivers what to whom, by when. Compute actual dates from the meeting date ("next Tuesday" becomes the real date); never compress a deadline into a nearby milestone.
            - Cover the ENTIRE session, including everything after presentations end or the recording formally closes; end-of-call segments often carry the decisions.
            - Part 1 must be derivable from Part 2: no fact appears only in the brief.
            """

        case .interviewSummary:
            """
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

        case .findingsLedger:
            """
            You are keeping a live INTELLIGENCE LEDGER during a meeting. From THIS
            transcript window, surface every genuinely new work object that would help
            the user steer the current conversation or preserve the outcome: decisions,
            action items, open questions, risks/blockers, and follow-ups. There may be
            several, one, or none.

            Output ONLY JSON, no prose, no markdown fences:
            {
              "findings": [
                {
                  "tag": "DECISION | ACTION | OPEN_QUESTION | RISK | FOLLOW_UP | FINDING",
                  "headline": "<=20 words: the decision/action/question/risk/follow-up; include owner/date when stated>",
                  "matters": "<=20 words: why it matters or the immediate next step>",
                  "quote": "<short verbatim source quote, or null>",
                  "speaker": "<speaker label if clear, or null>",
                  "timestampMs": <ms from the [mm:ss] prefix: mm*60000 + ss*1000, or null>
                }
              ]
            }

            TAGS:
            - DECISION: a choice, agreement, scope call, priority, or explicit non-decision.
            - ACTION: someone commits to do/send/check/schedule something.
            - OPEN_QUESTION: a question or ambiguity still unresolved.
            - RISK: a blocker, dependency, contradiction, concern, or claim to verify.
            - FOLLOW_UP: a thread the user should revisit before the meeting moves on.
            - FINDING: a concrete live insight that does not fit the above.

            Rules:
            - Only NEW objects from THIS window. Do NOT restate anything in the
              already-logged list below.
            - Every object should be source-linked: include timestampMs when possible
              and quote the shortest useful phrase when there is one.
            - Be specific and concrete. Skip greetings, logistics, and side-chatter
              unless they create a real action or decision.
            - Write in ENGLISH. Keep an essential original-language term ONLY as
              term (pinyin, English meaning) — never bare Chinese.
            - If nothing in this window is significant and new, return {"findings": []}.
            """

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
                  "source": "<the project document/transcript/guide this draws on, or null>"
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

        case .dgParse:
            """
            You convert a raw moderated-interview discussion guide into a structured JSON outline. Output ONLY JSON.

            Shape:
            {
              "objectives": [
                {
                  "id": "obj_1",
                  "title": "Objective title",
                  "description": "Optional short description, or null.",
                  "sections": [
                    {
                      "id": "obj_1_sec_1",
                      "title": "Section title",
                      "questions": [
                        { "id": "obj_1_sec_1_q1", "text": "Question text" }
                      ]
                    }
                  ]
                }
              ]
            }

            Rules:
            - Preserve the author's wording for question text — do not paraphrase.
            - Use stable, hierarchical IDs as shown.
            - If the document has no explicit objective grouping, create a single objective titled "Discussion guide" containing all sections.
            - If the document has no section grouping, create a single section titled the same as its parent objective.
            - Skip preamble, methodology notes, and timing instructions that aren't questions.
            - Output JSON only — no markdown fences, no commentary.

            Raw guide document:
            """

        case .dgMatch:
            """
            You match unanswered questions from a discussion guide against the live transcript window. Output ONLY JSON.

            Shape:
            {
              "matches": [
                {
                  "questionId": "obj_1_sec_1_q1",
                  "summary": "One-line summary of what the participant said.",
                  "quotes": [
                    { "text": "Verbatim quote.", "speaker": "self|them_1|…", "timestampMs": 123456 }
                  ],
                  "confidence": "high|medium|low",
                  "status": "partial|answered"
                }
              ]
            }

            Rules:
            - Match SEMANTICALLY, not by wording. The moderator paraphrases and often asks in Chinese; a question counts as touched whenever its MEANING or topic comes up, regardless of exact phrasing or language. Each guide question is given in English and 中文 (separated by " / ") — match against either.
            - Emit a match whenever the transcript meaningfully touches a question. Use "partial" generously for a topic that came up but wasn't fully resolved; use "answered" only when the response is substantive and complete.
            - Skip a question ONLY if its topic genuinely has not come up at all.
            - Each questionId MUST be copied EXACTLY from the bracketed id in the list below (e.g. "obj_2_sec_1_q3"). Never invent or alter an id.
            - Quote text MUST be verbatim from the transcript, in its original language.
            - Compute timestampMs from the `[mm:ss]` prefix (mm*60000 + ss*1000).
            - confidence = "high" only when the quote leaves no ambiguity.
            - Output JSON only.

            Unanswered questions (format: "- [id] English / 中文"):
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

    /// All defaults as an id→text map, for export to the offline prompt lab so
    /// the Python copy can read one source instead of drifting.
    public static func exportMap() -> [String: String] {
        var out: [String: String] = [:]
        for id in PromptID.allCases {
            out[id.rawValue] = id.defaultText
        }
        return out
    }
}
