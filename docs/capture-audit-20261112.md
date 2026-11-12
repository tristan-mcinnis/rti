# Where inline notes and screenshots go

Baseline `67c44ec8`, 12 November 2026. The probes used invented text, silent PCM, a stub transcription provider and a screen backend that aborts if called. They ran outside the installed app.

## Typed notes from entry to export

| Boundary | Observed behavior |
| --- | --- |
| ⌘⌥N and Submit | `OverlayInputState` selects note mode. In `AssistantInputView+Submit.submitLiveNote`, recording and paused sessions call `SessionCoordinator.insertNote`. Outside those phases the same composer appends a prep note to `MeetingContextStore`. Finishing is outside those phases. Prep text clears on session reset. |
| Live storage | `TranscriptPipeline.insertNote` appends an in-memory `LiveEntry` with speaker `note` and wall milliseconds since start. It trims the text and evicts the oldest after 500 notes. The coordinator publishes immediately. No journal write accompanies the insertion. |
| Pause, resume and reconnect | Neither pause nor resume resets the list. `AudioPipeline` writes matching silence to active WAV legs during pause, so their time axis continues while the header timer freezes. Typing while paused is allowed. `prepareForReconnect` keeps notes. Starting a new session resets the pipeline. |
| Checkpoint, quit and crash | `SessionCoordinator+Archive.startCheckpointLoop` snapshots every five minutes. Additional archive writes occur on orderly shutdown and some lifecycle events. A hard exit before the next snapshot loses an accepted note. Audio recovery can create a placeholder transcript, which cannot reconstruct typed text. Later checkpoints can overwrite an earlier snapshot with the truncated 500-note list. |
| Finish, archive and Sessions | `SessionFinalizer` takes notes from the merged live entries. `SessionArchive.renderTranscript` prints inline Markdown with whole seconds. `renderGuideTranscript` prints milliseconds and preserves a separate live transcript for Guide. `notes.md` contains generated notes. `session.json` has audio and Guide metadata but no inline notes or marker spans. `SessionsWindowModel+Reader` reads archive projections. |
| Offline upgrade | `TranscriptUpgradePipeline.upgrade` reads the current `transcript.md`. `TranscriptUpgradeMerge.notes` parses one line per note, discards fractional seconds and can misread spoken text containing “Note:”. `renderBody` moves notes below all speech under “Session notes”. A second upgrade recognizes those bullets. `TranscriptUpgradeArtifacts` backs up the previous file. `TranscriptUpgradeService` re-anchors Guide quotes only. |
| Downstream | At finish, `SessionArchive.writeCanonicalMeetingSidecar` puts surviving typed text under “My notes” in `*-rti.md`, flattens line breaks and omits offsets and IDs. The raw `*-transcript.txt` is produced after a successful upgrade. `CanonicalMeetingTranscript` filters inline notes and ignores trailing note bullets. A retry cannot infer spans from this raw file. |

### Reproduction

| Probe | Result on the baseline |
| --- | --- |
| Child process accepts a note, verifies it in memory and exits immediately with code 75 | The empty temporary fixture directory still contained zero files. This probes insertion before a checkpoint, without killing the recorder. |
| Insert 501 distinct notes, then prepare for reconnect | 500 survived, including the most recent. The first was gone. Reconnect retained all 500. |
| Upgrade a Guide-format note at 2,750 ms with text `/Tile B\nsecond line` and speech at 1 s and 7 s | Both deterministic upgrade passes returned a single note at 2,000 ms, text `/Tile B`. It appeared after the 7 s turn. The second line and raw-export marker were absent. |
| Parse the spoken sentence “They printed Note: read the tile.” | The upgrade parser manufactured the typed note “read the tile.” |

This compact check repeats the cap, multiline, timestamp and raw-export observations from the repo root with a built Debug core.

```sh
p=.deriveddata/Build/Products/Debug
fixture=$(mktemp -d)
swiftc -module-cache-path "$fixture/cache" -I "$p" -L "$p" -lRTICore -o "$fixture/probe" - <<'SWIFT'
import Foundation
import RTICore
let p = TranscriptPipeline(), start = Date()
for n in 1...501 { _ = p.insertNote("Fixture \(n)", startedAt: start) }
precondition(p.liveEntries.count == 500 && !p.liveEntries.contains { $0.text == "Fixture 1" })
let live = "`00:00:02.750` **📝 Note:** /Tile B\nsecond line\n`00:07` **You:** Blue."
let notes = TranscriptUpgradeMerge.notes(from: live)
precondition(notes == [TranscriptUpgradeNote(startMs: 2000, text: "/Tile B")])
precondition(!CanonicalMeetingTranscript.render(markdownTranscript: live).contains("/Tile B"))
SWIFT
"$fixture/probe"
```

### Proposed Phase 2 contract

Use the existing session folder from record start. The session journal `notes.jsonl` owns accepted notes. Append, synchronize and acknowledge each submission in order. Keep the draft and offer retry on write failure. Use a stable ID for a repeated submit. Preserve original text and multiline content, millisecond offset on the recording timeline, leg of entry (an authored local note, including when listening only), kind, display label and optional Guide IDs. A slash prefix in note mode selects a section marker. A regular note never closes a span.

Derive half-open spans in stable journal order. A marker begins at its recorded offset and ends at the next marker or recording end. A same-offset successor wins for turns at that offset. Write the first explicitly versioned `session.json` shape with derived spans, note/marker IDs and per-turn provenance. Treat a missing schema version as the current legacy shape. The journal can rebuild these after a crash. Re-anchor by time to upgraded turns, retaining original offsets and text. Flag untimed, ambiguous or distant anchors as approximate. A turn crossing a boundary belongs to the span at its start unless timestamped tokens establish a genuine split. Preserve an explicit unmarked value before the first marker.

Use this same projection for live dividers, Sessions, `transcript.md`, per-turn marker labels in the raw export and the timestamped sidecar. Project notes separately from speaker evidence. When following the Guide, prefer the latest explicitly linked marker. Recover old inline notes and trailing bullets when no journal exists. Keep unreadable records visible as errors and leave historical archives untouched on open.

Acceptance covers pause/resume, a process killed immediately after acknowledgement, a torn last append, write failure and retry, 501+ notes, repeated/equal-time markers, bilingual multiline text, markers during silence, repeated upgrades, Guide links and both generations of legacy Markdown. Compare IDs, offsets, exact text and marker membership across every output.

## Screenshot routes and policy boundaries

| Entry point | Present behavior and required check |
| --- | --- |
| Ambient timer, Prepare and header eye | `VisualContextSettingsDefaults` defaults its global Boolean to true. `VisualContextTrail` starts immediately and samples every 60 s. Pause/stop cancels the capture task. After OCR it checks cancellation. A separately launched local-description task can still complete after disable. |
| Screen/window keys, menus, palette, composer and slash command | All reach `ScreenshotManager`. Display capture excludes RTI and deny-listed apps via its content filter. Window capture selects a non-excluded window. Existing attachment request IDs protect replacement/clear. Manual captures can stage a JPEG during a recording, including paused recording, even when ambient capture or local vision is off. |
| Model tools | `capture_screen` calls `captureAndDescribe(trigger: "tool")`, which can stage a JPEG and returns OCR to the model. It has no attachment request ID. `highlight_screen_text` uses the last captured regions. The tool description advertises local interpretation while the implementation returns OCR text. |
| Imported image | `attachDroppedImage` shares screenshot OCR, staging and the pending attachment lane. An image file has a different provenance from a screen capture. Distinguish explicit file imports at ingestion before permitting them as ordinary attachments. Block the legacy screenshot lane while Off. |
| Send, retry and retained sources | `LLMController+Send` reads pending JPEG/OCR, ambient OCR while the session is running, and retained source payloads. `+Threads` can rehydrate a historical screenshot for follow-up. `+Actions` can regenerate or retry via ordinary send paths. A gate on the key alone misses tools, model dispatch, local asset submission and these reuse paths. |

An isolated probe ran the existing `VisualContextTrail` implementation with fake, disabled preferences and no display access. It supplied the synthetic text “Invented amber tile.” through `recordExternalCapture`. The disabled trail accepted one event and `recentPromptContext()` returned its text. Turning the ambient switch off today therefore does not exclude previously acquired context from the next prompt.

Use one effective policy for Settings, Prepare, menu bar, palette, the automatic indicator and the final capture/write/send decisions. Start with **Manual only**. **Off** vetoes new screenshots and their use for an outbound request. In **Manual only**, only an explicit capture gesture starts one. **Automatic during recording** enables the ambient sampler only while actively recording. Store a project and call-type override under the stable workstream identity. Display the effective mode and source. Global Off should immediately suppress even an earlier project opt-in. Label attempted disabled shortcuts locally without requesting Screen Recording access.

Capture a generation and session ID at request start. Recheck at the ScreenCaptureKit seam, after each await, before staging, local description, prompt construction, and dispatch or retry. On a policy change, cancel affected work and invalidate pending capture IDs and highlight regions. A stricter deny-list edit also invalidates suspended results. Keep historical session artifacts readable and suppress reuse of captured payloads while Off. A provider request already delivered cannot be withdrawn. Continue to honor local-vision save/describe choices, display/window exclusions and the existing provider destination display.

Acceptance uses fake capture, store, local vision and model transports. Assert zero calls/bytes for Off through every input, including retained screenshot retry and tool calls; use latches to change mode during OCR, description, queued dispatch and a session rollover. Test the three modes across pause/resume, switching projects/call types, empty windows, permissions, exclusions and legacy sessions. Separately verify the on-screen Automatic indicator and disabled-key message in the beta.
