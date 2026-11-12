# RTI state audit, 12 November 2026

Revision `67c44ec8`. Phase 0 inspected the checkout and compiled small probes directly from its Swift sources. All example words, timestamps and identities are invented. The supplied screenshots document the user's symptoms. Their client content is excluded from the probes and this report. Hardware diarization accuracy, actual menu interaction under load and trackpad behavior still need an isolated beta run.

## Defects behind the seven reported symptoms

| Rank | Report | Finding and evidence |
|---|---|---|
| 1 | 1. Most people look like Speaker 1 or 2 | A missing system speaker becomes `remote_1`. A second, independent defect loses valid speaker distinctions. Two different speakers on **the same system leg**, saying “我的茶杯是蓝色的” one second apart, yielded one live row under the first speaker. The final merge treats matching text from different IDs within five seconds as potential echoes even on the same leg. Neither result establishes how many speakers the provider distinguished in the original meeting. |
| 2 | 4. Recap, Notes and Auto over-attribute speech | All three format raw cluster IDs as ordinary speaker labels. They carry no field distinguishing provider clusters, absent labels, user-confirmed names, or unverified identity. The existing confidence is the mean token recognition score. The decoder actually produced 1.0 for an invented token with both speaker and confidence absent. Prompt input lacks the evidence required to make named or group claims reliable. |
| 3 | 5. Research loses Live Notes | Starting Research with a loaded guide binds the session to the Guide controller. The Notes generator returns through the Guide branch and the Notes tab shows Guide instead. Unguided Research still supports ordinary Live Notes. This is a conditional replacement of both the producer and the screen. |
| 4 | 6. Cannot change live translation | Mode and languages are editable through nested pickers. Configuration is immutable per socket, but RTI already replaces clients when defaults change. The UI displays the requested settings without showing whether each leg has switched. Selecting two-way EN/EN proved a specific failure: the pill remains enabled while the effective config is nil. Whether incoming rows also interrupt the open Mac menu needs reproduction. |
| 5 | 3. Cannot turn labels off | The shared live config hardcodes diarization on for every new mic and system stream. Prepare has no labels control. The file pass leaves diarization on for both WAVs too. The independent audio legs already carry enough information for a Me/Them display. |
| 6 | 2. Cannot specify a participant count | There is no per-session expected count in Prepare, the live config or the file-pass argument builder. An optional Guide roster supplies seat and group context, not a provider clustering constraint. Counting roster rows would also conflate attendance with who spoke. |
| 7 | 7. Scroll fights the reader | Transcript already detects native user scrolling and has Jump to latest. An off-bottom render proof exists, but a seeded still does not establish actual wheel behavior. Notes and Auto unconditionally scroll on append and appearance. Guide centers each cursor change. Assist resets follow when entry count changes. These are four different behaviors. |

## Recording lifecycle

| State owner | Event and writer | Transition or gap |
|---|---|---|
| `SessionCoordinator.phase`, `PendingStartGate` | Header, menu, hotkey or control command requests start. Permission callback resolves the pending token. | Idle, done or background-upgrading → permission check → prepare files and devices → recording. A cancelled permission request cannot start a session. ID and start time are set **before** preparation. On failure the catch tears down capture but those fields can survive in the previous phase. |
| `phase`, `pausedAt`, `completedPauses`, `AudioPipeline.suspended/micMuted` | Pause/resume, mute button, fatal capture callback | Recording ⇄ paused. Pausing both legs retains matching silence so WAV time includes the pause. The displayed timer excludes it. Mute affects the mic alone. UI intent for deliberate listening and unintended mute currently shares one boolean. |
| `SessionCoordinator.stopSession/completeStop` | Finish, hotkey, fatal audio error or quit | Finalize audio → finishing → drain and archive → upgrading or done. The new-session guard fences old upgrade UI completions. Quitting takes a separate archive/recovery path. A transcription failure alone can leave audio recording. |

Sources: [lifecycle](../RTI/Sources/Session/SessionCoordinator.swift), [phase](../RTI/Core/Session/SessionPhase.swift), [audio](../RTI/Sources/Audio/AudioPipeline.swift).

## Stream connection and capture

| State owner | Event and writer | Transition or gap |
|---|---|---|
| Per-leg `SonioxClient`, socket, generation, retry work item | Capture creates client; open sends config; network message or close changes health; retry timer or user retry opens a replacement | Idle → connecting → live → reconnecting/failed. The two streams use separate clocks and separate client ownership checks. A system leg can wait for PCM, connect, park on silence, and reconnect. Finalization on an already disconnected socket returns before cancelling a queued retry. That stop/retry sequence is a source-level race candidate. |
| `AudioPipeline`, per-leg owners, backend and capture generation | Mic/system callbacks, output-device changes, watchdog, pause and teardown | Mic engine and tap/SCK deliver PCM to independent WAV and STT consumers. Stream restart rebases words onto session time. On backend fallback after `await sck.start()`, one path tests only `isCapturing`; a stop followed by a new start deserves an interleaving test. |
| `TranscriptAggregator` per leg, `TranscriptPipeline` for merge, coordinator for publication | Interim replaces provisional runs; final commits a turn; stale socket/client delivery is rejected; merge coalesces revisions for UI | Finals live across stream replacement, interims clear, stream IDs rotate. The repeated-speech probe confirms a cross-speaker merge on the same input before UI, archive or prompts receive the data. |

Sources: [socket](../RTI/Sources/Soniox/SonioxClient.swift), [merge](../RTI/Core/Session/TranscriptPipeline.swift), [aggregator](../RTI/Core/Session/TranscriptAggregator.swift), [socket regression coverage](../RTI/RenderTests/SonioxClientSocketEventTests.swift).

## Translation

| State owner | Event and writer | Transition or gap |
|---|---|---|
| Five `TranslationDefaults` keys, controls in `TranscriptTabView`, derivation in `TranslationStore.currentConfig()` | Toggle enable, choose mode/target or two language picks | Off → one-way(target) or two-way(A,B). A=B gives nil despite enable remaining true. Each changed effective config may initiate a separate switch while editing two fields. |
| `SessionCoordinator.translationConfig`, immutable fields in each `SonioxClient` | Defaults notification on main recalculates config. If changed and recording **or paused**, coordinator prepares both aggregators for reconnect, replaces clients and publishes state | Old clients disconnect. New mic connects, new system connects immediately only if that leg was connected. A parked leg opens later with its new config. Already-final speech and WAV owners survive. The pending text is cleared. Old interim words are not flushed through an acknowledged handover. |
| Header pill, aggregated health and archived original speech | UI reads selected options immediately; socket callbacks set per-leg health and rebase; transcript display hides/shows translated rows | No state binds a specific requested language pair to a ready acknowledgement for each leg. No old-row backfill. A missing key, a failed reconnect or the invalid pair can leave UI selection and effective output apart. |

Sources: [picker](../RTI/Sources/UI/Overlay/TranscriptTabView.swift), [config](../RTI/Sources/UI/LiveTranscript/TranslationStore.swift), [defaults observer](../RTI/Sources/Session/SessionCoordinator.swift), [client replacement](../RTI/Sources/Audio/AudioPipeline.swift).

## Speaker naming and evidence

| State owner | Event and writer | Transition or gap |
|---|---|---|
| `RawToken.toSonioxWord`, `SpeakerTurn.collapse`, `SpeakerLabelMapping` | Provider delivers optional speaker string. Decoder converts absent/unparseable IDs to 0. Collapse groups unlabeled neighbors with a labelled run | Mic 0/1 → self, 2+ → room_N. System 0/1 → remote_1, 2+ → remote_N. No distinction survives between absent speaker and first detected voice in these raw keys. Recognition confidence cannot stand in for identity confidence. |
| `SpeakerNameStore`, `SpeakerNameArchive` | User renames a raw ID, optionally assigns Guide seat/moderator; starting a session clears mappings. The Guide remaps on edits | Name assignment persists by raw key across reconnects. Raw numeric labels are used across independent provider streams. A new stream can reuse a number without evidence it denotes the same person. |
| `LiveTranscriptPresentation.label`, `LLMController.recentTranscriptText`, `TranscriptContext.format` | Assist/recap gathers recent rows; Notes and Auto gather incremental rows. Display name wins; unnamed self is Me in prompts | Text-only attribution passes through. Session Markdown carries display labels, Guide quote records carry their locators/participant fields, and session metadata carries no per-turn identity verification. Guide roster assignment is useful human input, separate from hearing a name mentioned. |

Sources: [wire decoder](../RTI/Core/Soniox/SonioxProtocol.swift), [label map](../RTI/Core/Support/SpeakerLabelMapping.swift), [mean score](../RTI/Core/Session/SpeakerTurn.swift), [name owner](../RTI/Sources/Session/SpeakerNameStore.swift), [Notes/Auto context](../RTI/Sources/Session/TranscriptContext.swift), [Assist context](../RTI/Sources/LLM/LLMController+Send.swift).

## Live Notes

| State owner | Event and writer | Transition or gap |
|---|---|---|
| `NotesGenerationController` with session ID, generation, busy flag, lastNotedMs and notes | Start resets. Scheduler tick or manual generation reads new text. Completion appends a titled block and advances watermark. Failure keeps it for retry | Ordinary generation is single-flight and generation-fenced. The scheduler owns its own tasks and drains them on stop; manual work starts outside that task set, so late completion versus archive snapshot needs a test. |
| `GuideSessionController`, Notes slot and `OverlayPanelView` | Prepared Research session starts with guide. Notes generation delegates to Guide. Guide has its own consumed turns, cursor revision, final drain and sealed state | Guided → scheduled/manual Guide pass → final sealing. The ordinary generator returns before adding a note. With guide active the tab is Guide even if global Notes is disabled. |

Sources: [producer](../RTI/Sources/Notes/NotesGenerationController.swift), [tab](../RTI/Sources/OverlayPanelView.swift), [Guide owner](../RTI/Sources/Notes/GuideSessionController.swift), [scheduler](../RTI/Sources/Auto/AutoAssistScheduler.swift).

## Auto cards

| State owner | Event and writer | Transition or gap |
|---|---|---|
| `AutoAssistController`, `AutoAssistScheduler` | New speech arms 7-second debounce; minimum 25 seconds between proactive passes. Periodic tick and manual action also start a pass | Disabled or idle → queued → generating → append cards or retry later. Session generation fences results and busy cleanup. Tick checks enable at fire; an already armed debounce checks session but does not recheck enable in `fireIfDue`. Disabling can leave a queued producer. |
| `lastMs`, cards, unseen count, project retrieval | Successful model output advances watermark; UI visit marks seen; session reset clears. Project retrieval and model work suspend the pass | A failed/empty response retains eligible speech. Trigger-time transcript can include overconfident identities. A paused session still satisfies `isRunning`, allowing a pending pass over earlier speech. |

Sources: [Auto](../RTI/Sources/Auto/AutoAssistController.swift), [generation regressions](../RTI/RenderTests/LiveNotesTests.swift).

## Call type and Guide position

| State owner | Event and writer | Transition or gap |
|---|---|---|
| `CallTypeStore.active`, `CommandBuilder.switchCallType`, `LLMController.listenerMode` | Prepare/palette selects Client, Research, Internal or Personal. The switch persists the selection and updates listener framing. Each subsequent live request reads current type | Prompts, actions and tool policy can change immediately. STT context and active Guide were bound at start. Archive/sidecar reads the then-current type at Finish. Switching mid-call can leave different components describing different call types. |
| `GuidePreparation`, `GuideSessionController`, `GuideCursor` and manual selections | Start snapshots guide/group/roster; manual jumps record a timed selection; model suggestions need evidence and current cursor revision; stop seals | A valid suggestion can advance the current question today. The tab does not expose a durable Following/Manual user choice. Existing time-bounded manual routing and cursor rules must be preserved when markers are added. |

Sources: [call type](../RTI/Sources/Calls/CallTypeStore.swift), [switch](../RTI/Sources/UI/CommandPalette/CommandPaletteFactory.swift), [cursor](../RTI/Core/Guide/GuideDocument.swift), [guide controller](../RTI/Sources/Notes/GuideSessionController.swift).

## Scroll follow

| State owner | Event and writer | Transition or gap |
|---|---|---|
| `LiveTranscriptList.following`, reading anchor and AppKit scroll observer | Native live scroll away from bottom pauses follow. Scrolling near the bottom or Jump to latest resumes. New session resets | With same-session updates, the held row and intra-row offset are restored. The viewport edge threshold and a last run taller than the viewport need actual input testing. Activation follows only when current state allows it. View destruction/recreation can reset view-local state. |
| `HouseThread.following`, separate Notes/Auto scroll readers, Guide cursor, Logs | Assist follows while near bottom, resets on entry-count change and on appearance. Notes and Auto append/appear scroll to bottom; Guide follows current question; live Logs scroll on append | The other surfaces lack a shared user-pause rule. A model or timer append is sufficient to displace backreading on Notes/Auto. Reader search or list selection in Sessions uses explicit navigational scrolling and has a different purpose. |

Sources: [Transcript](../RTI/Sources/UI/Overlay/LiveTranscriptView.swift), [Assist](../RTI/Sources/UI/HouseChat/HouseThread.swift), [Notes](../RTI/Sources/UI/Overlay/NotesTabView.swift), [Auto](../RTI/Sources/UI/Overlay/AutoTabView.swift), [Guide](../RTI/Sources/UI/Overlay/GuideTabView.swift), [Logs](../RTI/Sources/Settings/LogsView.swift).

## Screenshot capture

| State owner | Event and writer | Transition or gap |
|---|---|---|
| `VisualContextTrail` and ambient defaults | Start/toggle → waiting → capture → active; pause/stop cancels; permission failure or capture failure changes state | Ambient defaults to enabled today. Post-capture cancellation checks protect a paused/stopped trail. Enabling with a session start date schedules immediate capture without checking paused state in the setter. |
| `ScreenshotManager`, LLM attachment request ID, chat send, frame archive | Screen/window keys and the model capture tool ask for pixels independently. Privacy lists exclude windows before capture. OCR, local description, archive and sending have separate destinations | Turning the ambient toggle off does not gate manual or tool capture. Manual frames can be archived during a running/paused session even when ambient is off. Off must also fence an already pending request and later image submission. Ambient JPEG saving and local description depend on the separate local vision config. |

Sources: [automatic capture](../RTI/Sources/Screenshot/VisualContextTrail.swift), [screen/window capture and archive](../RTI/Sources/Screenshot/ScreenshotManager.swift), [chat tool](../RTI/Sources/LLM/LLMTools.swift), [attachment identity](../RTI/Sources/LLM/LLMController+Actions.swift).

## Inline notes and section markers

| State owner | Event and writer | Transition or gap |
|---|---|---|
| Composer note mode → `SessionCoordinator.insertNote` → `TranscriptPipeline.noteEntries` | Submit trims text, allocates in-memory UUID and computes wall-clock milliseconds since start. Reconnect keeps notes. Starting a new session clears them | Acceptance guards only `startedAt` in the coordinator. Pause does not reset notes, WAV time retains silence, and repeated inserts evict old records after 500. A fresh pipeline cannot recover uncheckpointed notes. No durable leg, span, section label or question binding exists. |
| Archive renderer, sidecar and upgrade markdown reader | Checkpoint or Finish renders inline rows. File upgrade parses recognized Markdown lines, renders them after all speech. Raw export filters notes. Sidecar stores text under My notes | Standard archive timestamp rounds to seconds. Guide renders milliseconds but upgrade discards the fraction. Multiline continuation disappears in the line-based parser. Sidecar loses timing and line breaks. Slash prefix remains literal text. A repeated upgrade can recover a correctly formed trailing note, but cannot restore rejected or evicted content. |

Sources: [insert and cap](../RTI/Core/Session/TranscriptPipeline.swift), [checkpoint](../RTI/Sources/Session/SessionCoordinator+Archive.swift), [archive and sidecar](../RTI/Sources/Session/SessionArchive.swift), [file upgrade and raw format](../RTI/Core/Session/TranscriptUpgrade.swift).

## Session save

| State owner | Event and writer | Transition or gap |
|---|---|---|
| `SessionArchive` and retained WAV legs | Start creates dated archive, seeds transcript and pending-upgrade marker. The first system offset and periodic five-minute checkpoints can write archive snapshots | A hard crash before the next snapshot can lose recent typed material even if the WAV survives. Checkpoints rewrite the session projection. The current writer can therefore remove an earlier note after eviction. |
| `SessionCoordinator.completeStop` and `SessionFinalizer` | Finish collects all chat threads, closes audio, finalizes Guide, snapshots current transcript/notes/visuals, writes archive and raw sidecar, then schedules upgrade | Multiple artifact writes can fail separately. Audio close/write errors are surfaced and block automatic upgrade. A reported archive error is distinct from an empty session. Original records must remain readable with optional newer metadata absent. |

Sources: [finalizer](../RTI/Sources/Session/SessionFinalizer.swift), [session metadata](../RTI/Core/Session/SessionArchiveMetadata.swift), [archive recovery tests](../RTI/RenderTests/SessionArchiveRecoveryTests.swift).

## Offline transcript upgrade

| State owner | Event and writer | Transition or gap |
|---|---|---|
| Pending marker, `TranscriptUpgradeService`, `TranscriptUpgradePipeline` | Finish, launch recovery or Sessions action → discover WAVs → transcribe per leg → merge and install backup/replacement → raw export and optional processor | Auto retries a provider failure once. Guided archives with `transcript.live.md` have a per-directory overlap guard; unguided upgrades still lack that guard. Session-ID fencing prevents stale progress from overwriting a newer live session's UI. |
| Archived speech context and file adapter | The service invokes the selected script per WAV with EN/ZH hints, optional context file and an output file. The default local script uses async v6, language ID and diarization by default | Both legs receive the same policy. Mic/system namespacing of results is local. Guide quote anchoring checks timed remote turns. Inline notes use separate Markdown extraction, not this quote anchor. Empty/failed provider output can preserve original speech or use leg-specific live fallback according to the merge rules. |

Sources: [service](../RTI/Sources/Session/TranscriptUpgradeService.swift), [merge/transaction](../RTI/Core/Session/TranscriptUpgrade.swift), [fixture tests](../RTI/Tests/TranscriptUpgradeTests.swift).

## Native window and content movement

The [window stability trace](window-stability-20261112.md) covers frame restoration, drag, minimize, activation and Spaces. It records native frame coordinates separately from updates to the scroll view.

## Mid-session settings sweep

| Control | Effective time and owner | User-visible consequence |
|---|---|---|
| Translation toggle, target, language pair and live provider retry | Changed effective config replaces STT clients immediately. Backend is currently Soniox. | Existing WAV and final rows survive. Selected values alone cannot certify resumed translated output. |
| Speech context, project terms, meeting participants, call type used for STT | `launchSession` builds one `speechContext`. Replacement clients use that same value. Archive snapshots end-of-call context for file work. | Editing project or names can affect Assist/the archive but will not update live STT on its own. |
| Labels, expected speakers, language identification/hints | Hardcoded wire settings, apart from hinted translation languages. | No live switch or separate mic/system policy today. |
| Guide, group and roster | Prepare locks editing during an active recording; start binds the selected document. | Switches of call type during the call do not install or remove the active guide. |
| Notes interval, Notes/Auto enable and queued work | Scheduler takes interval once at start. Each tick reads enable keys. Existing generation/debounce has its own ownership. | A slider change does not reschedule an existing timer. Turning a feature off can hide its tab before ongoing work stops. |
| Input selection and echo cancellation | Audio engine reads settings at startup/rebind. Settings describes the next-recording behavior. | Header can show the selected preference while current audio still uses the former input. Live hardware route and saved preference are distinct. |
| Target app for system audio, output route and Bluetooth protection | Target selection stores defaults. CoreAudio tap reads the selected app when built/rebuilt; the menu setter does not rebuild on selection. Default output changes can rebuild a tap. Backend fallback and unavailable process fallback can widen the effective source. Bluetooth guard acquires/releases a route lease around capture. | A checked target does not guarantee the running tap changed immediately. Input/output rebind and speakerphone hardware need beta testing. |
| Mic mute, pause and listening role | Mute and pause flow directly into the capture pipeline; call type separately controls assistant listening posture. | Intentional listener and missing expected microphone audio can share a warning. |
| Privacy exclusions, automatic screen context and local vision | Privacy exclusions are read at new capture; ambient on/off cancels or starts a task. Local vision config is read on each ambient pass. | Pending/manual/tool/chat paths are independent. Existing saved frames and chat attachments have their own lifetimes. |
| Prompt, model, call type and speaker rename | Prompt/model and call policies are read for a new request. Renames update current presentation and Guide mappings. | Completed or already dispatched answers keep the earlier context. An old model reply cannot verify a new speaker assignment. |

The broader inventory of chat submission, retained sources, retrieval, workspace loading, library navigation, palette focus, prompts, audio recovery and status-item lifetimes remains in [the November 9 audit](state-machines-20261109.md). Its original stale-client risk was subsequently fenced in `01938685`. Its unguided-upgrade overlap risk remains. The project overview still describes Guide/Findings as removed, while this checkout has a working Research Guide producer and tab. Live Notes remains a separate producer in unguided calls.

## Soniox API contract

I compared the WebSocket start message, the REST request schema and the token definitions with RTI’s live encoder and the installed file-transcriber script. The provider documents these options for both legs independently. A new live configuration requires a new stream. A changed async configuration requires a new transcription job.

| Choice | Real-time and async behavior | Consequence for RTI |
| --- | --- | --- |
| Speaker labels | Both protocols accept `enable_speaker_diarization`. Soniox describes “Temporary speaker switches that stabilize as more context is available.” A cluster number belongs to its transcription. The service supports up to 15 speakers. [Diarization](https://docs.soniox.com/stt/concepts/speaker-diarization) | RTI enables it on both live legs. The upgrade runs the file transcriber once per available leg with its default diarization. Preserve leg and stream identity independently of the displayed name. |
| Expected count | Neither start schema lists an exact, minimum or maximum number of speakers as an input. The async request describes the diarization switch as “speakers are identified and separated in the transcription output.” [Create transcription](https://docs.soniox.com/api-reference/stt/transcriptions/create_transcription) | Store the moderator’s count locally. It can flag extra clusters or suggest a merge for review. A count alone cannot tell RTI which voices belong together. Preserve original provider IDs and flag unresolved merges. |
| Identity confidence | The documented score estimates “how likely the token was recognized correctly.” [Confidence scores](https://docs.soniox.com/stt/concepts/confidence-scores) | Use explicit provenance for speaker attribution. Missing speaker data currently decodes to zero and missing token confidence to 1.0. Neither default can verify a person. A spoken name stays inferred until confirmed. |
| Context | Both accept general facts, background text, terms and translation terms. Soniox describes terms as “Words and names you want spelled your way”. [Context](https://docs.soniox.com/stt/concepts/context) | Use context for spelling. A participant list in context cannot bind voice clusters to people. Snapshot edited terms on the next connection or file request. |
| Languages and reconnect | Both accept language hints, strict hints and language identification. The WebSocket instruction is “Before streaming audio, configure the transcription session”. No language, context or speaker reconfiguration message is documented. [WebSocket API](https://docs.soniox.com/api-reference/stt/websocket-api) | RTI hints English and Chinese and also adds the selected translation languages live. A switch must drain the retiring stream, rebase new token times and continue writing the existing WAVs. |
| Translation | The docs say “The same config block and token format work on both real-time and async delivery.” Specify one target in one-way mode or a language pair in two-way mode. Original speech carries timing. Translation tokens follow their originals. [Speech-to-text translation](https://docs.soniox.com/translation/stt-translation) | Keep quotes anchored to original speech. RTI supplies the translation block live. Its current file-upgrade command requests transcription with English and Chinese hints. |

Verified against the published API and source. A billed speech-recognition session, speaker accuracy on a four-person recording, and account-specific provider behavior remain untested.

The live encoder selects `stt-rt-v6`. The file-upgrade adapter passes each available leg to the installed transcriber with EN/ZH hints and optional context. That script currently selects `stt-async-v6`. We also inspected the published OpenAPI `CreateTranscriptionPayload` fields. [Live request](../RTI/Core/Soniox/SonioxProtocol.swift) · [File upgrade](../RTI/Sources/Session/TranscriptUpgradeService.swift) · [Published REST schema](https://docs.soniox.com/openapi.yaml)

## Synthetic evidence and checks still needed

| Exercise on this revision | Observed result |
|---|---|
| Decode one final token without speaker/confidence, run both label maps and serialize default config | Mic `self`, system `remote_1`, confidence `1.0`, diarization enabled and no speaker-count field. |
| Feed two final system tokens to `TranscriptPipeline.process`, IDs 1 and 2, 1,000 and 2,000 ms, same eight-character invented phrase | `liveEntries` returned one row with ID `remote_1`. No microphone words were fed. |
| Insert 501 distinct notes, inspect live merge, call `prepareForReconnect()`, construct a fresh pipeline | 501 inserts succeeded. Note 1 was absent, 500 remained after reconnect, fresh pipeline contained 0. This is an in-memory reproduction, not a process-kill exercise. |
| Feed a two-line synthetic note at 00:00:04.950 and one later spoken line to `TranscriptUpgradeMerge.notes` and `CanonicalMeetingTranscript.render` | One note at 4,000 ms, only its first line. Raw text contained only the spoken line. |
| Compile the actual `TranslationStore.swift` against the current core config. Exercise distinct and equal two-way languages using a volatile argument domain | EN/ZH gave enabled=true and an effective config. EN/EN gave enabled=true and nil. The running recorder's defaults were untouched. |

For the beta, replay four distinguishable speakers on the remote leg, with a moderator on the mic and a reconnect halfway through. Compare named/unnamed evidence at each stage. Exercise real menu selection during incoming rows and actual wheel, scrollbar and keyboard navigation with a growing tall turn. Preserve a user's manual scroll through appended Notes/Auto items. Test a crash after a multiline marker and before the next checkpoint, same-second markers, a marker typed while paused, and two consecutive upgrades. Until then the field symptoms and these controlled reproductions have different evidence.

## Beta implementation and replay checks

The beta now commits Soniox final tokens once and replaces only the sending leg's provisional suffix. Equal words on either leg survive, including consecutive punctuation and repeated untimed text. The on-disk wire record and in-memory timed tokens preserve optional speaker and recognition confidence, original-language text, translation status, socket identity and time offset. An unnamed system cluster provides no named attribution. A new socket starts a new cluster namespace. The live projection consumes newly accepted groups and patches the affected rows and reading turns. Opening a reader after an uncached history still builds that history once.

A release-optimized fixture alternated EN and ZH across mic/system, held the previous published snapshot and processed 240 interim and 240 final packets after preload. Results are process-local ingestion and reader projection, excluding SwiftUI layout, hardware and the network. Separate 90-minute runs varied with host load. The checked-in replay gave these results.

| Fixture | Final p50 / p95 / max | Interim p50 / p95 / max | Cold full projection | Peak process RSS |
|---|---|---|---|---|
| 10 min, 5,760 tokens | 0.096 / 0.321 / 2.701 ms | 0.019 / 0.082 / 0.215 ms | 10.635 ms | 12.8 MiB |
| 90 min, 44,160 tokens, 5,521 reading rows | 1.441 / 4.015 / 9.444 ms | 0.050 / 0.141 / 3.032 ms | 259.201 ms | 55.7 MiB |

Before the incremental reader change, a comparable raw 90-minute replay spent 4.411 / 7.036 / 11.768 ms p50 / p95 / max on a final **before** forming the reading turns and peaked at 61 MiB. That narrower baseline cannot establish an end-to-end speedup ratio. The first uncached projection remains visible in the measurements. Repeat with `RTI_PROVIDER_REPLAY_MINUTES=90 python3 scripts/transcript-merge-benchmark.py --output /tmp/rti-provider-replay-90`. The result includes cold latency, steady CPU seconds, p50/p95/max times and peak RSS. The command exits unsuccessfully when steady final p95 exceeds 16 ms. [Replay source](../scripts/TranscriptMergeBenchmark.swift) · [runner](../scripts/transcript-merge-benchmark.py)
