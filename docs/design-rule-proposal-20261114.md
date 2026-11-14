# Proposed additions to house DESIGN.md (2026-11-14)

Status: proposal. Not applied. Needs Tristan's yes before `design-system/DESIGN.md` changes.
Source: Tristan's review of RTI during a live group, compared with the Codex and Claude desktop apps.

## Add to "The rule in six lines" (becomes eight)

7. **Every element answers a question the user has now.** If a mark, chip, colour or count cannot say in words why it is there, remove it. A dot always carries a word or a visible legend.
8. **Actions sit under what they act on.** Copy, pin, retry and dismiss go in one quiet row directly below the item, left-aligned, and show on hover and on the newest item. Never in a far corner.

## Change in "Type scale"

- `body`: 15 regular (was 14), line height 1.55, always `textPrimary`. Prose is never `textSecondary`.
- Bold is for a few inline words, never a whole lead-in on every bullet.
- `textSecondary` and `textTertiary` are for metadata only (times, counts, hints), never for content the user came to read.

## Add to "Shape, space, size, motion"

- **Navigation:** an app with more than three pages uses a collapsible left sidebar (`chatRail` width, `surfaceSunken`), like Codex and Claude. A top tab row is for two or three peer views inside one page only.
- **Live noise budget:** a live side panel shows at most three blocks, and each block at most three items. More goes behind a "Show all" row.

## Add to "Shared components"

- **Answer** (RTI and Quick Launch): prose capped at `Layout.rtiAnswerMaxWidth`, no card; the action row (copy, retry, more) sits under the answer; sources and quotes stay collapsed behind one "Show quotes" row unless the user asked for them.

## Why

Tristan's review (2026-11-14): RTI's copy button sat at the top right; answers were long and grey; the topic map had coloured dots nobody could explain; the codebook was hard to follow. The Codex and Claude apps feel calmer because of lighter type, near-black ink, actions under each message and a left sidebar.
