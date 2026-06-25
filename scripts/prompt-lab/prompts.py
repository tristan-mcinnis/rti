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

SUMMARY = f"""Write a structured summary of this ENTIRE meeting so far, in markdown.
Work only from what was actually said — no invention, no padding.

{PINYIN_RULE}

## TL;DR
2–3 sentences.

## Key points
Substantive content under short bold topic headers, concrete and specific.

## Decisions & agreements
## Tensions & contradictions
## Open questions & follow-ups
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
