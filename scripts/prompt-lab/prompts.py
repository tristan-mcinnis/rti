"""
Candidate prompts to tune in the lab.

SINGLE SOURCE: the real shipping prompts live in the Swift registry
(RTI/Core/LLM/PromptID.swift). Export them with Settings → Prompts → "Export
defaults…" and save the JSON as `rti-prompt-defaults.json` next to this file;
the lab then tunes the EXACT prompts the app runs. The inline copies below are
only a fallback for when no export is present, so they no longer have to be
hand-synced.
"""

import json as _json
import os as _os


def _load_exported():
    """Real prompts from the exported registry JSON, mapped to lab keys.
    Returns None when no export file is present (fall back to inline copies)."""
    here = _os.path.dirname(_os.path.abspath(__file__))
    for name in ("rti-prompt-defaults.json", "defaults.json"):
        path = _os.path.join(here, name)
        if _os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                reg = _json.load(fh)
            key_map = {
                "notes": "liveNotes",
                "summary": "meetingSummary",
                "interview": "interviewSummary",
                "findings": "findingsLedger",
                "cards": "autoAssistCards",
                "dg_match": "dgMatch",
            }
            out = {lab: reg[rid] for lab, rid in key_map.items() if rid in reg}
            if out:
                print(f"[prompts] using exported registry: {name}")
                return out
    return None

PINYIN_RULE = (
    "⚠️ CRITICAL FORMAT RULE — applies to EVERY Chinese term: write it as "
    "中文 (pīnyīn, English meaning). The pinyin (with tone marks) is MANDATORY. "
    "A bare Chinese term with no pinyin is a format error — "
    "e.g. 没得选 (méi dé xuǎn, no other choice), never 没得选 alone."
)

NOTES = f"""You are taking live meeting notes — jotting points down as they are said.

{PINYIN_RULE}

LANGUAGE: Write the notes in ENGLISH; translate as you go. Keep an essential
original-language term only in the 中文 (pīnyīn, English) format above. Do NOT
write whole bullets in Chinese. Keep people's names and brand names as spoken.

Produce:
TITLE: <short 3–6 word title>
- <concise bullet>
- <concise bullet>
"""

SUMMARY = """You are writing the meeting record of this ENTIRE meeting, in two parts, in this exact order. Work only from what was actually said; no invention, no padding.

BEFORE WRITING, build a speaker map. Scan the whole transcript for introductions, sign-offs, and how people address each other ("I will start first, and Helen can chime in", "bye Tristan") and decide once who each voice is. Rules:
- One voice = one person. Never split a single speaker into two names, and never treat "Me" and a numbered speaker as different people.
- Use a real name only when the transcript supports it; otherwise use a role ("the Acme side", "the moderator", "the researcher"). Never write raw labels like "Speaker 3" or "them_1".
- If two similar names could be the same or different people (e.g. Helene vs Honey), keep them distinct and add one line flagging the possible name collision; never silently merge or pick one.
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

# Findings is JSON, so pinyin lives inside the headline/matters/quote strings.
FINDINGS = f"""You are a research observer. From this transcript window, surface
new significant observations as JSON: {{"findings":[{{"tag":"FINDING|TENSION|...",
"headline":"...","matters":"...","quote":"...","speaker":"...","timestampMs":0}}]}}

{PINYIN_RULE}
(Apply the pinyin rule inside headline / matters / quote.)

Output ONLY JSON.
"""

# Prefer the exported registry (the exact shipping prompts); fall back to the
# inline copies above when no export file is present.
PROMPTS = _load_exported() or {"notes": NOTES, "summary": SUMMARY, "findings": FINDINGS}
