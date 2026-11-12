# Research codebook files (schema 1)

Each Research recording writes `codebook.json` and `codebook.md` beside its transcript. Selecting a project in an eligible business project root also writes those two files in that project. The archive JSON owns the evidence from one session. The project JSON includes those entries across sessions and owns card identities and moderator edits. Markdown is a readable projection. An older session with none of these files opens normally.

| Field | Meaning |
| --- | --- |
| `schemaVersion`, `projectDirectory` | Schema integer and optional directory of the merged book. |
| `sessions[]` | Stable recording `id`, optional `group`, recording `startedAt` (seconds since 2001-01-01 UTC), archive `folder`, consumed original turn IDs, `endMs` watermark and `incomplete` flag. |
| `cards[]` | UUID `id`, canonical `name`, `aliases`, `type` (brand, person, org, concept, hypothesis), `seeded` (false means emerged), `pinned`, and append-only `entries`. |
| `entries[]` | `point`, `valence` (positive, negative, mixed, neutral), optional moderator-spoken `inferredName`, and `evidence`. Within a card, session ID plus turn ID identifies a single entry. |
| `evidence` | `sessionID`, `turnID`, `group`, `offsetMs`, immutable original-language `original`, `speaker` (raw ID, label, Me/Them leg, confidence, optional seat and segment, moderator flag), optional `questionID`, `markerID`, `markerLabel`, `packageRevision`, `showEventID`, `shownItemIDs`, `shownCodes`, and `revealRecorded`. Missing shown codes means untracked, an empty array means explicitly cleared. Shown identifiers record an exposure. They do not assign a remark to a particular material. |
| `suppressed`, `redirects` | Normalized aliases for dropped cards and source-to-survivor UUIDs from explicit merges. Replay respects both. |

A preparatory seed is one line in Setup or `<project>/codebook-seed.md`. A line can be a name, a Markdown list item, or `type | canonical name`. Heading and blank lines are ignored. Explicit guide JSON `hypotheses` is an optional array of names. The codebook summary draws from the evidence points on the card.

`quotes.jsonl` contains a `ResearchQuote` evidence object per starred turn. Focus the transcript and press **S**, or use **⌘⌥8** during a Research recording. Clicking a transcript line selects it. With no selection, the shortcut uses the latest finalized turn. A repeat star of the same session/turn has one effect.

The `-rti.md` sidecar names `codebook_json`, `codebook_markdown`, `quote_bank` when present (relative to the session archive), and the two `project_codebook_*` paths when the project merge has succeeded. Session and project files use owner-only, atomic replacement. Each update rereads the file under a cross-process lock. A retry can restore committed session entries to the merged book.
