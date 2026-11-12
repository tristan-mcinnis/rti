# Stimulus review fixture

From the RTI repo root, run `python3 docs/fixtures/stimulus-review/check.py`. Exit 0 with no output means the contract checks pass. Add `--show` to print the eight proposed per-turn records. The files contain invented EN/ZH speech and a three-slide IC package. The checker reads local fixture files only.

The package plans A1, B1 and reveal slide R1 for Guide moment T. All three appear in the manifest from the start. Participant exposure comes from the moderator’s journal. “No recorded reveal” describes the available evidence about this group, including when a blind board is shown again.

| What the moderator sees | What the archive records |
| --- | --- |
| Before the first mark | `shownCodes: null` means unknown. |
| A1 and B1 together, then a new Guide question | Both codes stay visible. The Guide position becomes S1Q2. An ordinary typed note changes neither. |
| Boards put away | An explicit empty list starts the known no-board interval. |
| A1 back on screen while someone recalls B1 | A correction to the original marker fixes the shown code. B1 remains the turn’s explicitly discussed code. Replaying the correction gives the same eight turns. |
| R1 revealed, then A1 revisited | A1 has a fresh visit ID. The group already saw the reveal. |
| The upgraded audio moves a quote across a boundary | Its original time, words and attribution remain. A separate playback time and review flag expose the disagreement. A missing upgrade time is marked approximate. |

The digest in `session.json` covers the exact manifest bytes and all three HTML slide files, including their private notes. It is the SHA-256 of a compact JSON list of sorted relative paths and their SHA-256 values. The asset identity is the pair of package digest and neutral code. This fixture has one package per session. A future mid-session package change would need its own referenced revision.

Only the selected safe fields travel with a projected turn. Invented private product mappings, file names and moderator notes stay out of blind context. Verbatim participant speech is preserved. Assertions check the fixture’s allowed fields and private canaries. The test reads supplied session events and upgrade anchors and exercises export semantics. Capture UI, provider alignment, consent, disk durability and actual participant exposure need separate beta checks.
