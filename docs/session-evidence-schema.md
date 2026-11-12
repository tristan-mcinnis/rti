# RTI session evidence, version 1

Each new tracked session has three complementary records. The live Soniox stream is the source for provider text and timing. The moderator's journal records what they typed and marked. The evidence file joins the two by original audio time and keeps any offline playback corrections separate.

| File | Contents |
| --- | --- |
| `notes.jsonl` | Owner-only JSON lines. Each acknowledged action has a stable ID, session ID, local author leg, millisecond audio offset, kind and original text. Section, Guide and material fields are optional. A correction targets an earlier event and retains its identity. Only complete newline-terminated records count. |
| `transcript-evidence.json` | `schemaVersion: 1`, original turns, effective notes, half-open spans, per-note upgrade anchors and, after an upgrade, the upgraded turns. Original turns carry a stable turn ID, unaltered original words, source leg, speaker evidence, audio offsets, context and optional explicit discussed codes. An upgraded turn keeps its own words, speaker, time and matching live turn IDs. Mixed or approximate joins carry an explicit status. |
| `session.json` | Schema version, turn provenance, spans, note IDs, evidence path, material package revision and optional pointers to raw Soniox artifacts when present. A missing schema version means the older archive format. |
| `stimulus-package.json` | The confirmed selection at record start, with neutral codes, scoped item IDs, order, version, available source pointers and a digest of the manifest plus available referenced source assets. The private product map is excluded. A manual physical item has a local ID. |
| `transcript.live.md`, `transcript.md`, `*-transcript.txt`, `*-rti.md` | The first is the live verifier source. The reader and raw transcript include separate authored marker/material annotations and per-turn context. The raw sidecar points to the evidence and journal and lists the typed notes. Speech words remain independently verifiable. |

A missing `shownCodes` in a marker leaves the displayed set alone. In projected context, a missing set means untracked, an empty set means explicitly cleared, and multiple codes mean a comparison. `showEventID` distinguishes revisits. A recorded reveal persists for the group. The shown set records the moderator's report. Only an explicit code in original words populates discussed codes.

An offline time crossing a section or material boundary sets `anchor` to `review boundary`. The live evidence stays with its original position. With incomplete or ambiguous alignment, the upgrade retains the source and marks it approximate. Opening a historical session never creates a journal. Older Guide imports continue to read the timestamped speech grammar from the preserved sources.
