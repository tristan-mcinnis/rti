"""
Candidate prompts to tune in the lab. Keep these in sync with the Swift source
(NotesGenerationController.notesPrompt, LLMController.meetingSummaryPrompt,
FindingsController.prompt). Tune here, port the winner back to Swift.

These mirror the current (post-2026-06-14) prompts with the strengthened pinyin
rule. Edit, re-run run.py, compare compliance, then update the .swift files.
"""

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

PROMPTS = {"notes": NOTES, "summary": SUMMARY, "findings": FINDINGS}
