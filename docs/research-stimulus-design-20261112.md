# Which material was the group reacting to?

**Proposed for the local beta.** If a moderator asks “What catches your eye?” twice, the guide question can stay the same while the board changes. RTI should record each change once and carry it with the evidence. The moderator can use an external slide deck, a clip, a worksheet or a physical sample. This workflow also works with Screenshots Off.

## Prepare the material

Read the selected IC package’s `stim-manifest.json`. Its slides carry a guide moment, neutral codes where supplied, and an array order for PPTX pages. Non-slide pieces and worksheets have separate references. The guide’s stimulus plan identifies a section; several questions can belong to that section. Group rotation instructions may be in a separate moderator sheet. Show the proposed order for the selected group and let the moderator confirm it. When there is no package, accept a neutral label and an optional file/page. A session can start with nothing prepared.

Pin the chosen material revision at record start. Identify a piece by its package revision, kind and source item, with its displayed code as a label. The same code can recur in other packages or refer to an option on a board. Store a local digest of the manifest and referenced presented files where available. A changed file offers a new revision and preserves the old reference. A missing file can still be logged as a manually identified item, with its provenance visible. Loading only explicitly chosen materials preserves the existing project-scan exclusions.

## While moderating

| Moderator action | RTI behavior |
| --- | --- |
| Preview a board, move to another guide question, or receive a model suggestion | Show the proposed material privately. The recorded exposure stays where the moderator left it. |
| Select **Mark shown** | Record the piece or comparison set at the current audio offset. One control in Guide and its palette command share the same operation. Show the active codes beside the question. Keep the current Guide position unless the moderator explicitly changes it. |
| Mark another set, clear, or revisit | Close the preceding interval and open a new one. Use distinct states for unknown, explicitly cleared and a known set. Returning to A after B creates another visit to A. Preserve any earlier confirmed reveal for that group. |
| Correct the last change or a past boundary | Append a correction to the original event. Rebuild the affected evidence. Retrying the same event has one effect. On a failed save, keep the choice available and show that it has not been recorded. |

Use the proposed typed marker journal, `notes.jsonl`, for these changes. A plain note, a section marker and a confirmed stimulus change may occur independently. Store original audio time, stable event and session IDs, group and revision. For a clip, sample or comparison, “shown” records the moderator’s report of what was available to the group. It does not establish that every participant saw or handled it. Moderator-only notes, the blind code map and planned reveal details stay out of the automatic Assist prompt. Opening this control never initiates a screen capture.

## What a saved quote means

For every original turn, record the guide question, evidence ID, marker and material set at its original audio time. Keep **shown** separate from **discussed**. If A and B were visible and someone says “the first one,” retain the comparison context and leave the referent unresolved. If they explicitly refer back to A while B is showing, preserve both facts. Apply the same lookup to moderation actions, starred quotes, respondent cards and the project codebook. When an upgrade moves the playback locator across a boundary, retain the original attribution and flag the disagreement for review.

The [bilingual contract fixture](fixtures/stimulus-review/README.md) exercises these transitions independently of the running app. The [downstream probe](fixtures/stimulus-review/downstream.md) shows which existing workbook outputs retain the IDs.

Publish one versioned machine-readable projection from the journal. Link it in session metadata and the raw sidecar. Render human-readable material context in the live view, Sessions and transcript exports. Keep the exact original words, speaker and turn ID available to existing verifiers. A missing projection in an older archive means “untracked.” Material identity and reveal history must travel through the actual workbook importer before a comparison by board is considered verified.

## Current behavior and acceptance

- Prepare imports the DG and optional roster. Its typed guide model has questions, probes and sections. A fixture through the current Word/Markdown parser lost the Markdown stimulus-plan list and show cue; the guide skill’s plan reader recovered the moment. Reuse that reader for matching Markdown sources. For Word or prepared JSON without a plan, let the moderator bind a moment explicitly. [Guide reader](../RTI/Sources/UI/Overlay/GuidePreparation.swift) · [Typed guide](../RTI/Core/Guide/GuideDocument.swift)
- A run against the current RTICore gave the same question four board-A turns and one later board-B turn. The saved cell kept the four A quotes. Store the underlying evidence independently of the number of quotes displayed on the Guide card. [Baseline probe](fixtures/stimulus-review/before.swift) · [Current extraction](../RTI/Core/Guide/GuideExtraction.swift)
- The current synthesis importer can pass its checker even when a newly inserted heading makes a previously verified quote fall into review. Preserve the live proof transcript’s grammar. Exercise old and new archives through the downstream readers and assert exact accepted and held turn IDs, original words, and visibility of A/B in the resulting workbook. Include simultaneous boards, a skipped rotation, a blind/reveal/revisit, correction replay, a missing source and an upgraded timestamp on the other side of a marker.
