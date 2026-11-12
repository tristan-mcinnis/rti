# RTI beta palette timing and live workspace memory

The original palette evaluated 55 result rows three times for a five-row viewport. The beta evaluates the visible five, ranks the merged list without first reranking the registry, and keeps query changes inside the palette. The command field keeps AppKit’s native text editor and marked-text handling and disables automatic completion and spelling correction for search. The focus and full-collection tests exercised typing, activation, dismissal and a jump to row 150.

## Cmd+K on the default workspace

At 860 × 660 pt, each fresh process received 1,301 invented EN/ZH final batches spanning 65 minutes, 24 saved two-turn chats and 24 messages in the open chat. During twelve open/three-key cycles, another 48 final batches went through the production receive/publish path. The baseline had 52 registry commands and 55 empty-query results. The beta had 60 and 62. Both had five visible rows. The beta column uses the fresh repeat after Release compilation ended. All observations include the first open and first typed key. Each cell contains median / worst milliseconds. Nearest-rank p95 equals the worst for twelve observations per position.

| Input | Baseline, updated view | Beta, updated view | Baseline, complete bitmap | Beta, complete bitmap |
|---|---:|---:|---:|---:|
| Cmd+K | 47.12 / 74.77 | 17.57 / 34.52 | 279.88 / 364.28 | 261.33 / 426.60 |
| s | 24.51 / 51.02 | 7.01 / 38.22 | 246.98 / 282.77 | 235.28 / 304.53 |
| se | 18.38 / 22.64 | 6.47 / 15.06 | 236.99 / 271.02 | 252.47 / 438.21 |
| set | 13.55 / 18.10 | 7.78 / 12.07 | 234.62 / 566.23 | 250.94 / 316.26 |

12/12 opens reached the updated view in under 100 ms. 34/36 filter updates reached it in under 16 ms. The exceptions were cycle 1 s at 16.69 ms, cycle 12 s at 38.22 ms. An earlier beta run also reached the filter target on 34 of 36 keys, with two over-budget observations of 26.85 and 29.79 ms. [Raw key timings](fixtures/palette-baseline/beta-samples.csv)

A synthetic AppKit event was dispatched to a nonactivating, offscreen panel hosting the complete workspace. The earlier endpoint marks the first observation of the expected query after layout needed to service that event. The later one includes software-rasterizing the whole workspace. In the offscreen host we explicitly assigned focus after measuring open to deliver filter keys. Physical presentation and automatic focus timing on the user's visible display need the beta's Instruments trace.

In a diagnostic trace the first key entered AppKit text checking and correction-indicator setup after the query callback. The main thread also spent time in the composer's SwiftUI body and text layout. The beta field owns its input services and the palette owns its query. A sampling profile changes elapsed times, so the table uses the timed fixture runs. The full-window bitmap includes Core Animation layer rasterization and blur.

## Memory over three sessions

One hostless process opened the same saved-chat fixture and replayed three sessions, each spanning 92 min 57 s in 1,860 invented final batches. Provider time was accelerated. The test let the real 120 ms publisher run between minutes. Each cycle scrolled the live reader to three positions, visited Chats, Sessions and Assist and filtered the palette through four route cycles. The beta also opened Codebook with 16 concepts and 96 invented evidence entries. After each session, it cleared the current chat fixture and transcript and sampled again after 600 ms. The cold sample is after workspace mount and writing 24 fixture chats.

| Cycle and stage | Baseline RSS / footprint, MiB | Beta RSS / footprint, MiB |
|---|---:|---:|
| 0 · initial | 97.33 / 34.75 | 95.42 / 34.66 |
| 1 · recorded | 161.44 / 114.56 | 155.53 / 118.00 |
| 1 · interacted | 196.00 / 134.97 | 183.47 / 147.44 |
| 1 · reset | 195.09 / 134.20 | 188.22 / 146.83 |
| 2 · recorded | 152.36 / 132.28 | 191.41 / 137.53 |
| 2 · interacted | 150.31 / 135.25 | 171.12 / 139.99 |
| 2 · reset | 158.39 / 134.06 | 162.14 / 138.56 |
| 3 · recorded | 176.98 / 132.56 | 190.39 / 139.61 |
| 3 · interacted | 177.33 / 137.97 | 181.41 / 141.36 |
| 3 · reset | 177.50 / 136.77 | 179.05 / 139.97 |

Mach `TASK_VM_INFO` supplied both measurements. The warm reset samples test retained growth across repeated sessions. They include the persistent workspace, AppKit caches and the test process. From the first warm reset to the third, beta footprint fell by 6.86 MiB. The third beta reset used 3.20 MiB more than the original. Physical footprint is the charged process memory at each sample. These samples do not measure live hardware capture, real Soniox sockets, physical-display presentation, provider inference, or a recording that runs for 93 minutes of wall time. [Raw memory observations](fixtures/palette-baseline/workspace-memory.csv)

## Other live surfaces

The shared lazy chooser also covers Add Context, @, slash, scope and the Guide palette. The new Codebook card list and archived evidence sheet use lazy stacks. The sheet loads archived turns through an actor and then scans loaded text for the nearest quote. Its merge menu still enumerates candidate cards. Stimulus import runs off the UI actor; its item, Guide-question and history pickers enumerate the loaded package. Neither search path is part of Cmd+K filtering. [Original overlay and popover audit](palette-baseline-20261112.md) · [Codebook views](../RTI/Sources/Codebook/ResearchCodebookTab.swift) · [Stimulus controls](../RTI/Sources/UI/Overlay/StimulusControls.swift)

## Reproduction

Baseline timings use the original probe. To reproduce the beta timings, follow its checkout and build directions with revision `9fbccf4d` and apply only the beta instrumentation patch to that disposable checkout. The opt-in memory test and normal viewport/navigation regression are already in that commit. Unit and render fixtures use invented content. The release app also emits the native draw signposts for a directly observed window. [Baseline directions](palette-baseline-20261112.md) · [Beta timing patch](fixtures/palette-baseline/beta-instrument.patch) · [VERIFY](../RTI/VERIFY.md)
