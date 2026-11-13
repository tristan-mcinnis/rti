# RTI state machines

This is the one index of the state types in RTI. Each entry gives the
states, the events, the effects and the test file. The code is the
source of truth. When this file and the code disagree, follow the code
and fix this file.

Dated audits keep their history: `state-machines-20261109.md`,
`state-audit-20261112.md`, `state-coverage-20261112.md`. This file
replaces none of them. It lists what exists now.

All of this state is live and in memory, except where an entry says
"on disk". No entry adds an RTI database or index.

## How to find the state types

Run this from the repo root. Each hit must have an entry below.

```sh
grep -rnE "(enum|struct|class|actor) [A-Za-z]*(State|Phase|Pacer|Board|Gate|Control|Status|Health)\b" RTI/Sources RTI/Core
```

The search does not find every machine by name. Some machines are a
controller with a generation counter and a `sealed` flag (Notes, Guide,
Codebook). They have entries too.

## The spine: session phase

`SessionPhase` (`RTI/Core/Session/SessionPhase.swift`), owned by
`SessionCoordinator.phase`.

- States: `idle`, `recording`, `paused`, `finishing`, `upgrading`,
  `done`.
- Events and transitions:
  - `startSession` (from `idle`, `done` or `upgrading`, after the mic
    permission) -> `recording`.
  - `pause` -> `paused`. `resume` -> `recording`.
  - `stopSession` -> `finishing`.
  - `completeStop` -> `upgrading` when the archive and audio are good,
    else `done` (the review path: the `-rti.md` sidecar is still
    written, through `writeStopSidecar`, and no upgrade is queued; if
    that write fails, the error says the `/meeting` notes file is
    missing). On the upgrade path a failed stop sidecar is logged and the
    export writes it again from the archive.
  - The upgrade ends -> `done`, only if the same session is still
    current and the phase is still `upgrading`.
  - `emergencyShutdown` -> `idle`.
  - `toggleSession` does nothing while `finishing`.
- Effects: the session phase is the one spine. Its events reset or stop
  every other live machine:

| Event | What it does to the other machines |
|---|---|
| `startSession` | `PendingStartGate.begin`. Then, once the mic is granted: transcript and speaker names reset, `NotesGenerationController.reset(for:)`, `AutoAssistController.reset(for:)` (`AutoPassState` `.reset`, `LiveRailBoard.reset`), `GuideSessionController.startPreparedSession`, `ResearchCodebookController.start`, `MicControl` `.sessionStarted`. |
| `stopSession` | `PendingStartGate.cancel` if a start waits. `AutoAssistScheduler.stop`, `AutoAssistController.stop` (`AutoPassState` `.stop`, the rail admits nothing more), `MicControl` `.sessionFinishing`, both `TranscriptionHealth` values to `idle`. |
| `completeStop` | `ResearchCodebookController.finish`, `GuideSessionController.finish` and `NotesGenerationController.finish` (final drain, 8 s each, run together), `MicControl` `.sessionStopped`, `GuideSessionController.endSession`, then the upgrade. |
| `emergencyShutdown` | `writeQuitRecord`: the archive and the `-rti.md` sidecar (completeStop never runs on this path). `MicControl` `.sessionStopped`, health to `idle`, phase to `idle`. |

- Header mirror: `OverlayLivePhase` (`RTI/Core/UI/OverlayShellStatus.swift`)
  has the same six cases. `OverlayShellStatus` maps a phase to the header
  word, tone and record chip.
- Archive writes: while `recording`, a checkpoint every 5 minutes takes
  only the snapshot on main (`SessionFinalizer.prepare`) and renders and
  writes it on a utility task (`SessionFinalizer.write`). The stop and
  quit writes run on main. `ArchiveWriteGate` runs one write at a time
  and skips a job older than one already written, so a checkpoint still
  writing at Stop never lands after the final archive. A live write
  (it carries evidence) or one with a system-leg offset writes
  `session.json` and `transcript-evidence.json` even when nothing was
  said yet. The start writes once (session id, speech context, speaker
  policy) and the system leg's start writes again (its offset), so a
  crash before the first checkpoint recovers the system leg at its real
  offset with the raw provider.
- Recovery: the next launch's upgrade writes the `-rti.md` sidecar for
  any current-format folder (evidence, `notes.jsonl` or
  `soniox-live.jsonl` present) that has none, with the generated notes,
  screen context and chat read back from `notes.md`,
  `screen-context.md` and `chat.md`
  (`SessionArchive.archivedSidecarSections`). The export
  (`requiredCanonicalExport`) throws, so the upgrade marker and
  `canonical-export.pending.json` stay, when it cannot write the
  transcript or the sidecar, and when no meetings folder resolves: a
  broken `config.json` (`VaultPaths.configReadProblem`) or one that
  names no `transcripts_dir`, `knowledge_base_dir` or `recordings_dir`.
  It never reports success without an export. When one leg transcribes to
  nothing, its live lines come from the evidence and then from
  `soniox-live.jsonl` past the last checkpoint
  (`SonioxLiveJournalReplay`; a line cut by a kill is skipped).
- Tests: `RTI/Tests/MenuStatusTickTests.swift`,
  `RTI/Tests/OverlayShellStatusTests.swift`,
  `RTI/RenderTests/LivePerfTests.swift`,
  `RTI/RenderTests/SessionStopErrorTests.swift`,
  `RTI/RenderTests/SessionCaptureFailurePolicyTests.swift`,
  `RTI/RenderTests/SessionArchiveRecoveryTests.swift`,
  `RTI/Tests/TranscriptUpgradeTests.swift`,
  `RTI/RenderTests/MenuTickWiringTests.swift`.

## Start admission

`PendingStartGate` (`RTI/Core/Session/PendingStartGate.swift`), owned by
`SessionCoordinator`.

- States: no pending start, or one pending token.
- Events: `begin` (returns a token, or nil when one waits), `resolve(token)`
  (true only for the current token), `cancel`.
- Effects: a stop or a second Record press while the mic prompt is open
  cancels the start. A late permission answer then starts nothing.
- Tests: `RTI/Tests/PendingStartGateTests.swift`.

## Mic

`MicControl` (`RTI/Core/Session/MicMode.swift`), owned by
`SessionCoordinator.mic`.

- States: `preset` (`speaking`, `listeningOnly`), `mode` (`open`,
  `mutedInCall`, `listeningOnly`), and `isLive`.
- Events: `setPreset` (ignored while live), `sessionStarted`, `toggleMute`
  (ignored outside a call), `sessionFinishing`, `sessionStopped`.
- Effects: `micMuted` makes the audio pipeline send silence on the mic
  leg. `bannerVisible` shows "Your mic is muted" for an in-call mute only.
  A stop resets the mode, and the preset when a live call used it. So a
  mute never carries into the next call.
- Tests: `RTI/Tests/MicModeTests.swift`.

## Transcription health, one per leg

`TranscriptionHealth` (`RTI/Core/Session/TranscriptionHealth.swift`),
written by `SonioxClient` and held in `SessionCoordinator.transcriptionHealth`
and `systemTranscriptionHealth`.

- States: `idle`, `connecting`, `live`, `reconnecting`, `failed`.
- Events: socket open (`connecting`), configured (`live`), drop
  (`reconnecting`, backoff 1, 2, 4, 8 s), retries spent or a fatal error
  (`failed`, after `maxRetries` = 5), stop (`idle`). A dead path that
  sends no TCP reset is a drop too (`abandonSocket`): the path stays not
  viable for 5 s (`.viabilityChanged(false)`), the system suggests a
  better path (`.reconnectSuggested(true)`), or audible audio (peak
  1,000 or more) goes 15 s with no frame back (`stallTimeout`). Room
  tone and silence never count.
- Spent retries: `AudioPipeline` gives each leg one fresh client after
  45 s, doubling to 6 min per spent budget, until the leg is `live`
  again (mic: `scheduleMicAutoReconnect`; system:
  `scheduleSystemAutoReconnect`, the new client connects at the next
  system buffer). Never after auth or a client bug. The system notice
  says whether capture failed (`systemCaptureLostNotice`) or only the
  live text (`systemTranscriptLostNotice`: the audio is still recorded).
- Effects: the header and the Transcript show the state. Only the current
  socket can change it: `emitStatus` checks the delivery generation.
  Socket events arrive and frames decode on the client's own serial
  `callbackQueue`, not on main. Words, status and errors then hop to main
  in arrival order, so the per-leg re-base on `live` still comes before
  the new stream's words.
- Tests: `RTI/RenderTests/SonioxClientSocketEventTests.swift`,
  `RTI/RenderTests/AudioPipelineRecoveryTests.swift`.

`SystemAudioCaptureHealth` (`RTI/Sources/Audio/SystemAudioCapture.swift`)
is a sample, not a machine: buffer time, audible time and RMS levels.
`AudioPipeline` reads it to tell a silent leg from a dead one. Tests:
`RTI/RenderTests/AudioPipelineRecoveryTests.swift`.

## Capture faults (degraded, not terminal)

`AudioPipeline` (`RTI/Sources/Audio/AudioPipeline.swift`), `MeetingRecorder`
(`RTI/Core/Audio/WAVWriter.swift`) and `TapStallPolicy`
(`RTI/Core/Audio/TapStallPolicy.swift`). Only a recording that cannot be
saved stops the session (`onError`).

- Mic outage: states healthy, outage (`micOutageStartedAt`). Event: no
  mic buffer for 8 s, counted from the later of the last buffer and the
  last input start (session start, rebind, wake). Effects: `micLostNotice`
  once, then `audio.restart()` at once and after 5, 10, 20, 40 and every
  60 s for as long as it lasts. The system leg keeps recording. A buffer
  ends the outage and clears the notice; the recorder pads the mic gap.
- Sleep: states awake, asleep (`isAsleep`). Events: `NSWorkspace`
  willSleep, didWake. Effects: the mic and system watchdogs skip while
  asleep; wake gives both an 8 s first-buffer grace, then the normal
  rebind. The recorder's gap clock (`sleepInclusiveUptime`,
  `CLOCK_MONOTONIC`) counts sleep, so each leg is padded with silence for
  it and WAV time stays equal to live (wall) time.
- System backend: the tap never gives up (`TapStallPolicy`: rebuild after
  6 s without buffers, three times, then every 60 s). The pipeline
  watchdog makes two quick recoveries, then one a minute. A tap that
  delivered any buffer this session is idle, not dead, and is kept. A tap
  that never delivered falls back to ScreenCaptureKit once, only with
  Screen Recording already granted; the fallback starts before the tap
  stops, and the tap stays if it fails. `systemAudio` is never nil while
  capturing. A fallback whose `start()` returns after its call ended (a
  Screen Recording prompt held it while the user stopped and started the
  next call) is stopped: it needs the same `captureGeneration` and the
  same tap, and its buffers pass only after it is installed (AUD-5).
- Mic tap: each engine run converts with its own `MicTapConverter`, held
  by that run's tap block, so `stop()` and `restart()` on main change
  nothing the audio thread reads. The tap is installed with no format
  (`installInputTap`), so a device that changes format between the format
  read and the install cannot raise AVAudioEngine's exception; the
  converter is rebuilt when a buffer arrives in a new format (AUD-7).
- Capture gaps (`CaptureGapLog`, `RTI/Core/Audio/CaptureGap.swift`): one
  record per leg of what was not recorded, in session ms. Events: mic
  outage begin and end (`noAudio`), mic all-zero input from 10 s until it
  clears, mute or pause (`silentInput`), system capture failed or never
  started, set and cleared with `systemAudioOutageReported`
  (`captureFailed`), and each silence fill of the writer
  (`MeetingRecorder.onGapFilled`: `noAudio`, or `writeFailed` for frames a
  failed write owed). `finalize` and `abort` close every open gap. Reports
  of one stretch merge per leg. Effects: `session.json` `capture_gaps`, a
  "Recording gaps" block under the date line of `transcript.md` (kept when
  the upgraded transcript replaces it) and a "## Recording gaps" section
  at the top of the `-rti.md` sidecar, so `/meeting` never reads a
  one-sided stretch as a quiet one (AUD-4). A checkpoint saves open gaps
  as still missing.
- Durable writes: states writing, degraded (per leg `failingSince`),
  failed. Event: a block write throws. Effects: the block's frames are
  owed and written as silence before the next good block; `onWriteDegraded`
  drives `recordingAudioNotice`. Every write failing for 30 s
  (`writeFailureTolerance`) is fatal once: `onWriteFailure`, the
  recording-failure latch, the session stops and the archive is marked
  "Recording needs review" (`recordingStoppedEarly`: the reason stays on
  screen until the next start). The review path still writes the
  `-rti.md` sidecar; the upgrade is manual. A recovered failure sets no
  `recordingError`, so automatic processing stays queued.
- Tests: `RTI/RenderTests/AudioPipelineDegradedCaptureTests.swift`,
  `RTI/Tests/RecordingFaultToleranceTests.swift`,
  `RTI/RenderTests/AudioPipelineRecoveryTests.swift`,
  `RTI/RenderTests/AudioPipelineStaleFallbackTests.swift`,
  `RTI/RenderTests/MicTapConverterTests.swift`,
  `RTI/RenderTests/CaptureGapArchiveTests.swift`,
  `RTI/Tests/CaptureGapLogTests.swift`.

`FinalPacketLogThrottle` (`RTI/Core/Soniox/FinalPacketLogThrottle.swift`)
is a counter per leg. Event: `record`. Effect: true for the first packet
with final tokens and then every 100th, so only those get a log line.
Tests: `RTI/Tests/FinalPacketLogThrottleTests.swift`.

## Auto pass timing

`AutoPassState` (`RTI/Core/Live/AutoPassState.swift`), owned by
`AutoAssistController.pass`.

- States (`Phase`): `idle`, `debouncing(until:)`, `waitingFloor(until:)`,
  `generating(generation:)`. Also `watermarkMs`, `lastPassAt`,
  `generation`.
- Events: `activity`, `timerFired`, `tick`, `passRequested` ("Suggest
  now"), `passFinished(generation:endMs:)`, `passSkipped(generation:)`,
  `cancelPending`, `stop`, `reset`.
- Effects: `none`, `disarm`, `arm(at:)`, `startPass(generation:)`. The
  controller holds the one timer and runs the pass. The debounce is 7 s
  (`quietWindow`). The floor (`floor(for:format:)`) is 60 s on client
  calls, 150 s on research calls and 180 s in a research group
  (`ResearchFormat.group`: two or more roster seats, or an FGD guide
  title). It is nil on internal and personal calls. Only
  `passRequested` skips the floor. Only an accepted pass moves the
  watermark. `stop` and `reset` bump the generation, so an old reply is
  dropped.
- Thin input: an admitted research pass that has fewer new respondent
  characters than `ResearchFormat.minimumRespondentCharacters` (150, or
  40 in an interview) ends at once as `passSkipped`. No request is
  sent, the watermark stays and `lastPassAt` goes back to the last sent
  pass, so the skip uses up no floor. The next settled final (7 s
  debounce) or tick checks the window again. Respondent characters come
  from the shared role rule (`AutoResearchSignals.respondentCharacters`).
  The format reads "idi" in a guide title only as a whole word; "group
  interview" is a group. One exception: when the system leg has been
  silent for 3 minutes or more (`AutoResearchSignals.silence`), one thin
  pass runs for that silence (`silencePassFor`, keyed on the system
  leg's last speech), so the silence signal reaches the rail while the
  room is still gone. `reset` clears it.
- Card gate after a reply (`AutoCardRules.accept`, pure): a RECALL
  without a supplied source is dropped; when more than 30% of the new
  window is CJK (`AutoCardLanguage.isMandarin`), a SAY or ASK without
  `text_zh` is dropped. A card whose only line is Mandarin (in
  `text_zh`, or put in `text_en`) keeps it as its Mandarin line, and an
  older saved prompt's one `text` with English, Mandarin and pinyin
  lines splits into its lines (`AutoCardLanguage.lines`); a card with word or character-pair Jaccard 0.5
  or more against a card shown in the last 15 minutes, or still
  waiting, is dropped; a research pass keeps one card, plus a FLAG that
  quotes two call times (a contradiction). With no guide running
  (`guideActive` false), a card that names a guide (`mentionsGuide`:
  "guide", 提纲, 指南, 访纲, 大纲) is dropped.
- Observation: `pass` is not observed. Each committed final moves its
  debounce deadline, and an observed `pass` redrew the rail at the flush
  rate. Views read `isGenerating`, a stored flag written only when the
  phase enters or leaves `generating`. An `arm` effect keeps a timer that
  fires at or before the new time (less than 7 s before it): the early
  fire re-arms. So a burst of finals re-arms about once per quiet
  window.
- Project search (client and research calls with a project picked):
  at most once every three passes (`AutoVaultCadence`); the passes in
  between reuse its hit. It runs on `VaultSearch.Budget.auto`: `.utility`
  QoS, two workers, stopped after 300 ms with what it found, stopped at
  once when the pass is cancelled. The walk checks the limit and the
  cancel on every enumerated item, decks and images too, and may use only
  the first 150 ms (`Budget.walkShare`), so reading always has time.
  Files are read newest first, and each worker reads at least 8 files
  (`Budget.minimumReadsPerWorker`) before the limit can stop it, so a
  cold cache always warms. `VaultSearch.DocumentCache` keeps the
  lowercased text of each file read in this session, keyed by path,
  modification date and size, in memory only, up to 16 MB
  (`DocumentCache.defaultByteLimit`); past that, files are still searched
  but not kept. Only the top results read their excerpt, again from
  disk. `search_vault` keeps `Budget.tool` (every core, no limit).
- Tests: `RTI/Tests/AutoPassStateTests.swift`,
  `RTI/Tests/AutoCardRulesTests.swift`,
  `RTI/Tests/VaultSearchBudgetTests.swift`,
  `RTI/RenderTests/AutoAssistControllerTests.swift`,
  `RTI/RenderTests/LivePerfTests.swift`,
  `RTI/RenderTests/ResearchReplayAcceptanceTests.swift` (see Research
  replay).

## Live rail

`LiveRailItem.State`, `LiveRailPacer` and `LiveRailBoard`
(`RTI/Core/Live/LiveRailPacer.swift`). `AutoAssistController.rail` holds
the board.

- Item states: `new` (waits for the pacer), `shown`, `pinned`,
  `dismissed`, `expired` (faded to "Earlier"). Lanes: `now` (say, ask,
  recall) and `threads` (flags).
- Board events: `offer`, `advance(now:callType:explicit:)`, `fade`,
  `pin`, `dismiss`, `noteSelfSpeech`, `reset`.
- Pacer rule (`admit`): at most one item per 60 s (`spacing`), a 4 s
  hold after your own speech on client calls (`selfSpeechHold`), lane
  caps 3 and 2 (`nowCap`, `threadsCap`), fade 240 s after shown
  (`fadeAfter`), drop a waiting item older than 90 s once a newer one
  waits (`staleAfter`). An explicit request skips the spacing and the
  hold.
- Effects: `advance` returns the next time to call it. The controller
  arms one timer for that. `noteActivity` keeps the last self-speech time
  outside the observed board and copies it in before each `advance`, so
  a mic final does not redraw the rail. A dismissed text never comes back. A card
  that faded unseen may come back from a later pass. After `stop`, the
  rail admits nothing until the next session.
- Layout: `LiveRailLayout.Mode` (`RTI/Sources/UI/Overlay/LiveRail/LiveAssistRail.swift`)
  is `none`, `rail` or `strip`. The rail folds to the strip below
  `stripBelow` (`House.Layout.chatMinWidth` 720 pt plus 32 pt, so
  752 pt of panel width).
- Tests: `RTI/Tests/LiveRailPacerTests.swift`,
  `RTI/RenderTests/LiveRailRenderProofTests.swift`.

## Live Notes

`NotesGenerationController` (`RTI/Sources/Notes/NotesGenerationController.swift`).

- States: `isGenerating`, a `generation` counter, the `lastNotedMs`
  watermark, the session ID.
- Events: `reset(for:)` (session start), `clear`, `generate(sessionId:)`
  (scheduler tick or "Write notes now"), `finish(sessionId:)` (one pass
  at Stop over the talk since the last tick, bounded to 8 s).
- Effects: a pass appends one note block and posts
  `.rtiNotesBlockAdded`. Only the owning generation can clear
  `isGenerating` or write a result. The session archive writes the
  notes on stop (`notes.md` and the `-rti.md` sidecar). The Stop pass
  does not wait for a manual pass already running, and "Write notes now"
  stays on after Stop: a block that lands after the archive is written
  to `notes.md` and the sidecar by `LateChatArchiveRefresher`.
- Backlog cap: a window over 6,000 characters that covers more than two
  scheduler intervals (a failed pass kept its watermark, or Notes was
  turned on mid-call) keeps only its newest 6,000 characters
  (`backlogStart`). The block starts where the kept part starts, and a
  "Notes skipped" block (`skippedNote`) marks the dropped stretch, so
  `notes.md` and the sidecar show the gap.
- Tests: `RTI/RenderTests/LiveNotesTests.swift`,
  `RTI/RenderTests/LivePerfTests.swift`.

## Periodic passes

`AutoAssistScheduler` (`RTI/Sources/Auto/AutoAssistScheduler.swift`).

- One repeating timer at the Notes interval (default 120 s). Each tick
  starts every enabled task at its own `phase` of the interval: Notes at
  0, Auto at 1/6, the guide at 1/3, the codebook at 2/3 and its
  synthesis at 5/6 (at 120 s: +0, +20, +40, +80, +100 s). A stop, a
  restart or a task turned off during the wait drops that run. No two
  passes prepare their prompts on the same main-thread turn.
- Pass prep reads the transcript incrementally:
  `TranscriptPipeline.utterances(includeNotes:)` keeps
  `LiveTranscriptPresentation.utterances(from:)` up to date
  (`UtteranceIndex`: fragments over a minute behind the newest are folded
  once; a late fragment before that, a reset or a notes replay rebuilds),
  and `GuideTranscript.liveSources()` reuses the sources of unchanged
  utterances. Auto's windows are found by binary search on the sorted
  entries. Signposts (`PassSignpost`, category `LivePerf`) time `guide
  pass prep`, `codebook pass prep`, `auto pass prep` and `checkpoint
  snapshot`.
- Tests: `RTI/Tests/UtteranceIndexTests.swift`,
  `RTI/RenderTests/LivePerfTests.swift`.

## Guide

`GuideSessionController` (`RTI/Sources/Notes/GuideSessionController.swift`).

- States: inactive (no session ID), active and following live
  (`isFollowing`), active on a manual question (`manualQuestionID`),
  `isGenerating`, `sealed` (after `finish`). It also keeps
  `furthestIndex`, the cursor, the extraction, the `GuideMatcher`, and
  the pass state: `reached` (guide index to the earliest ms the
  recording reached it), `lastPosition` and `lastPassAt` (for Auto
  freshness), `emptyStreak` and `backoffTicks`, `retryTurns` (one failed
  batch) and `unfiled` (turns given up after two failures).
- Events: `startPreparedSession` (research call with a prepared guide,
  else it resets `GuidePreparation`), `generate` (scheduler tick, or
  `explicit` from the Guide tab button), `move(by:)`, `jump(to:)`,
  `select`, `followLive`, `selectMarker`, `markersDidChange`, `finish`
  (final drain under an 8 s deadline), `endSession`.
- Effects: each pass files quotes against guide questions anywhere in
  the guide; only a manual pick or a marker link fixes where a turn
  files. A moderator line matching a guide question sets the position
  while following; every such line in a batch counts, in spoken order,
  so a batch that crosses two questions keeps both on the timeline.
  Moderator lines and bare backchannels (role `unknown`, such as 对对对)
  never supply a quote or a note. A `passRevision` bump drops an old pass. A failed
  pass sets `retryTurns`; the next pass sends only those turns; a second
  failure moves them to `unfiled` and the archive marks the capture
  incomplete. A decoded pass with no cells and no position adds to
  `emptyStreak`; from 3, a scheduler tick runs only every third time
  until a pass files something. A backed-off tick still reads its ready
  turns' roles locally and sends nothing; a moderator line there that
  moves the position ends the back-off and the pass runs at once.
  After `finish` no periodic pass runs.
  `endSession` clears all state.
- Derived: `GuideGap.State` (`RTI/Core/Guide/GuideGaps.swift`) is
  `notRecorded`, `skipped`, `thin(quotes:)` or `oneSeat(quotes:)`.
  `GuideGaps.find` computes it from the extraction on read, up to 5
  gaps. A question is `skipped` only once its section closed. When the
  first guide index the recording reached (in the first 5 minutes) is in
  a later section, the recording started mid-guide: the sections before
  it are `notRecorded` (`GuideGaps.recordedFrom`). A first position
  inside the first section is a normal start, so an early skip there
  stays `skipped`. "Moderator to…" items are
  never gaps. `gaps` (the rail's "Go back to") leaves `notRecorded` out.
  `autoQuestion(at:)` is the user's pick, a marker link, or
  `lastPosition` under 4 minutes old, else nil (Auto says "Guide position
  uncertain"). `autoGaps(at:)` is `gaps` only while `lastPassAt` is under
  4 minutes old. It keeps no other state. Turn roles come from
  `TurnRoles` (`RTI/Core/Guide/TurnRoles.swift`), a pure rule.
- Turn IDs: `consumed` holds source IDs. A split piece's ID is
  `speaker@start#pk` (piece k of the utterance), never its interpolated
  time, so it stays the same while the utterance grows. Mic-leg echoes
  are left out only when `TurnRoles.roomOnBothLegs` holds for the last
  10 minutes (an in-room group on a speaker).
- Tests: `RTI/RenderTests/GuideLiveTimingTests.swift`,
  `RTI/RenderTests/GuideGapsControllerTests.swift`,
  `RTI/RenderTests/GuidePassControllerTests.swift` (retry, back-off,
  moderator position, payload, stable piece IDs, a tally split at its
  question mark),
  `RTI/RenderTests/GuideRenderProofTests.swift`,
  `RTI/RenderTests/ResearchReplayAcceptanceTests.swift`,
  `RTI/Tests/GuideGapsTests.swift`, `RTI/Tests/TurnRolesTests.swift`.

## Codebook

`ResearchCodebookController` (`RTI/Sources/Codebook/ResearchCodebookController.swift`).

- States: no `location` (not a research call), preparing (a
  `preparation` task), ready, `generating`, `sealed`. A `passID` token
  owns each pass.
- Events: `start(sessionID:at:callType:)`, `generate`, `finish` (final
  drain under an 8 s deadline), `edit`, `star`, `retryProjectMerge`,
  `markersDidChange`.
- Effects: each pass sends the batch's turns with a `TurnRoles` role
  hint and leaves mic-leg echoes of the room out on an in-room group
  only (they are still consumed). A turn whose role is not respondent
  (a moderator line, or a bare backchannel with role `unknown`) is
  stored with `moderator: true`, so it never becomes an entry. A pass merges proposals into the codebook through
  `ResearchCodebookStore` (on disk, in the session folder and the
  project). A new `passID` or `location` drops an old result. The rail
  shows `liveTopicMap()`, `topicMap` cached on the book revision.
- Synthesis (2026-11-13): a second scheduler task,
  `researchCodebookSynthesis`, calls `synthesize` on each tick. It runs
  only when `synthesisDue` holds: 10 minutes of call time since the last
  run, 4 or more codes, and a new quote. States: `synthesizing`, a
  `synthesisID` token, `lastSynthesisMs`, `quotesAtLastSynthesis`. The
  clock is checked before any counting. A failed run retries after
  2 minutes even with no new quote. After a good run the count takes in
  the quotes the reply re-cited (tension sides, hypothesis evidence), so
  those links never make the next run due. `start` clears the clock and
  the token; `finish` drops a synthesis in flight, and none runs after
  the call ends. The reply goes through the store as `.synthesis`.
- Code rules enforced in `ResearchCodebook.apply`: no person or
  organisation codes and no speaker labels; a new non-brand code needs
  two quotes, a brand or stimulus code in the quote, or a barrier; at
  most 3 new non-brand codes a pass; about 40 codes a session (votes
  still land); a tension cites two different turns; only a vote may
  cite a moderator turn. Votes, tensions and hypotheses file only into
  a card of their own type, and nothing else files into one
  (`canFile`), so a tally never lands on a theme as a quote. A code never
  resolves to a schema 1 person or org card: `matches` skips them. An
  entry whose spellings reach two cards is dropped. A brand never takes
  another brand's spelling as an alias (清悦 never absorbs 晴越), and a
  brand created in a pass is found again in that pass by its name, not
  by an alias. A new brand name whose alias is one known brand's
  spelling is still read as a new spelling of that brand: code cannot
  tell a sound-alike from a recognition variant.
- Tests: `RTI/RenderTests/ResearchCodebookTests.swift` covers the store
  and the topic map. `RTI/RenderTests/ResearchCodebookMeaningTests.swift`
  covers schema 1 loading, the code rules, votes, tensions, the synthesis
  apply and due rule, the brief and the prompts.
  `RTI/RenderTests/ResearchCodebookSynthesisTests.swift` drives
  `synthesize` with a scripted request: the clock and new-quote gates,
  the retry, the sealed guard, and a late reply after `start` or
  `finish`.
  `RTI/RenderTests/ResearchCodebookRenderProofTests.swift` renders the
  tab. `RTI/RenderTests/ResearchReplayAcceptanceTests.swift` drives
  `generateLive`, `synthesize` and `finish` over the invented replay. `RTI/Tests/StimulusCodeMatcherTests.swift` covers the code
  matcher. No test drives the pass states (`generate`, `edit`, `star`);
  `RTI/RenderTests/LiveRailRenderProofTests.swift` and
  `RTI/RenderTests/CommandPaletteFocusProofTests.swift` only render the
  controller.

## Research replay

An acceptance replay, not a state type. The fixture is
`RTI/Tests/Fixtures/ResearchReplay/`: an invented 60-minute Mandarin
group for an invented oat drink (Lumo 露慕), with every failure the
2026-11-12 judges found scripted at a known minute. `script.tsv` is the
source; `scripts/research-replay-fixture.py` writes `transcript.jsonl`
(the live token journal shape) and adds bland filler lines (about 130
characters a minute on the system leg). `guide.json` and
`codebook-seed.md` are the inputs, `answer-key.json` says what a correct
run shows, and `responses/` holds recorded replies, hand-written to the
shipped schemas. Several break the rules on purpose (a moderator line
cited, a backchannel, a person, a speaker label, a brand merge, a card
in the warm-up, two cards a pass, an ASK with no Mandarin line, a near
repeat, a guide card with no guide). The test bundle never bundles the
fixture; tests read it by path.

- `ResearchReplayRun` (`RTI/RenderTests/ResearchReplay.swift`) feeds
  each journal batch through `receiveTranscriptWordsForProof` on a
  simulated clock. It runs the shared guide controller (its request is
  swapped with `useRequestForTest`), a codebook controller on a
  temporary folder and an Auto controller. Guide, codebook and synthesis
  run at +40, +80 and +100 s of each 120 s tick; Auto ticks every 10 s,
  standing in for the debounce, and still waits for its floor.
- Layer A, `ResearchReplayAcceptanceTests` (offline, in `make
  test-render`): every guide reply decodes; role hints mark the summary
  and the guide reads as moderator lines and none of them, nor the
  backchannel, is cited; S1 is `notRecorded` and a question is `skipped`
  only once its section closed; the three client spellings merge and the
  sound-alike brands stay two cards, with no person or speaker-label
  card; the tally is one vote card, 5 for B and 1 for A; Auto shows at
  most one card a pass (plus a contradiction), every ASK and SAY has its
  Mandarin line, no two cards within 15 minutes repeat, nothing runs in
  the warm-up, the contradiction, silent-leg, leading-question and
  brand-assumed FLAGs land in their windows, and with no guide no card
  names one; consecutive Auto prompts share their first 3,000
  characters; the scorer gives the recorded replies full marks.
- Input budget: the run sends about 590,000 characters in 84 calls
  (guide 29, codebook 31, synthesis 5, Auto 19). fd042d6b sent 541,165
  in 118 calls on the same fixture (local harness, dry run). The section
  5 target, 60% of that, is not met: Auto makes a third of the calls,
  but each guide, codebook and Auto prompt is larger and the guide and
  codebook still run every 2 minutes. The test holds a hard limit at
  120% and marks the 60% check as an expected failure (strict, so it
  fails once the target is met).
- `ResearchReplayEnduranceTests`: the same text end to end for 120
  minutes (about 2,500 packets), both legs and mic only, accelerated,
  with the Transcript tab visible and the passes on their ticks against
  a stub. It prints flush p95, the longest main-actor gap (a 10 ms
  ping), pass preparation at minutes 30 and 120, the checkpoint snapshot
  and `phys_footprint` growth from minute 10. Limits (M5, assert only
  with `RTI_TIMING_TESTS=1`; an M1 is about 1.8x, an estimate): flush
  p95 under 4 ms, gap under 50 ms, guide and codebook prep under 5 ms
  and flat (median at minute 120 within 1.5x of minute 30), Auto prep
  under 8 ms (measured 4.2 to 5.6 ms with both legs, over the 5 ms
  target), checkpoint snapshot under 5 ms, footprint growth under 40 MB
  (about 33 MB for the first replay in a process). `SessionCoordinator`
  records each flush as the `transcript flush` signpost;
  `flushTranscriptForProof` runs a pending flush at once (DEBUG).
- Layer B, `ResearchReplayLiveEvalTests`: opt-in with
  `RTI_EVAL_DEEPSEEK=1`, local only. It runs the same replay against
  the configured provider and scores it with `ResearchReplayScore`
  against the answer key (codebook recall 80% or more and no forbidden
  card, the minute-34 tension and FLAG, guide position at 8 of 10
  checkpoints, Auto volume, template share and Mandarin lines, input
  estimate). Results go to `.deriveddata/research-replay-eval/<stamp>/`
  only. `RTI_EVAL_STRICT=1` fails the test on a missed target.
- `RTI_REPLAY_DUMP=<folder>` (as `TEST_RUNNER_RTI_REPLAY_DUMP` through
  xcodebuild) writes Layer A's exchanges and timeline there.

## Transcript upgrade

The upgrade is the `upgrading` phase plus an on-disk marker.

- States: pending marker set (`SessionArchive.markAutomaticUpgradePending`),
  running (`runUpgradePhase`, `postProcessingStatus` shows progress),
  cleared (`clearAutomaticUpgradePending`) or kept for retry.
- Events: `completeStop` starts it. Success clears the marker. Failure
  keeps the audio and the marker. `PendingUpgradeResumer` runs
  `SessionArchive.pendingAutomaticUpgrades` again at launch and each time
  the network comes back (`NetworkReturnGate`: offline to online only);
  runs never overlap and skip the live session's folder.
  `TranscriptUpgradeService.upgradeRetryingOnce` tries twice when the
  error `isRetryable`: `providerFailed` (a Soniox answer) or
  `networkFailed` (a `URLError`, never called a write failure).
- Refusal: `upgrade` throws `stillRecording` for the folder of a session
  in `recording`, `paused` or `finishing`
  (`SessionCoordinator.isCapturing(sessionStartedAt:)`), and Sessions
  hides Upgrade on that row.
- Soniox file jobs (`SonioxAsyncFileClient`): a request that never left
  the Mac (offline, DNS, connect refused) is sent again, POST included;
  a timed-out or dropped GET or DELETE is replayed; a POST that may have
  arrived is resumed by its reference in the next run. Remote cleanup
  after the transcript is saved never fails the run; the job file stays
  for the next run to delete the leftovers. `.soniox-async-<leg>-audio.json`
  stamps the audio byte size of each raw result; a raw result or job for a
  different size is stale, set aside as `.soniox-async-<leg>-stale.json`,
  and the audio is sent again.
- Early stop: a terminal `AudioPipeline.onError` sets
  `recordingStoppedEarly`. Its message is never retired on the timer,
  and a later upgrade ends on "Recording stopped early · see message",
  never "Session saved".
- Effects: the end sets `done` only for the current session. It clears
  the chat only if the chat is still as Stop left it (`UpgradeChatMark`).
  The upgrade numbers the other side's voices itself, so typed names move
  to the upgraded voice heard at the same times (`SpeakerNameRemap`: over
  5 s of shared time and more than half of that speaker's overlap). A
  name with no clear match is left out. The live map stays in
  `speaker-names.live.json`; a later upgrade starts from it. A guided
  session keeps its names on the live speaker IDs.
- Tests: `RTI/RenderTests/AssistSearchCancelTests.swift`
  (`runUpgradePhaseForProof`), `RTI/RenderTests/SessionArchiveRecoveryTests.swift`,
  `RTI/RenderTests/RecordingHandoffSafetyTests.swift`,
  `RTI/Tests/SonioxAsyncFileClientTests.swift`,
  `RTI/Tests/NetworkReturnGateTests.swift`,
  `RTI/Tests/SpeakerNameRemapTests.swift`.

## Window and pages

- `WorkspaceModel.Page` (`RTI/Sources/UI/Workspace/WorkspaceModel.swift`):
  `live`, `sessions`, `chats`, `settings`. Events: `select`,
  `showSettings`, `leaveSettings`, `setWindowVisible`. Effects: hiding
  the window or leaving a library page pauses playback and closes
  actions. It never stops capture or drops the draft.
  `isLivePageActive` is true only when the window shows the Live page.
  Tests: `RTI/RenderTests/WorkspaceRenderProofTests.swift`,
  `RTI/RenderTests/WorkspaceVisibilityRegressionTests.swift`.
- `OverlayTab` (`RTI/Sources/UI/Overlay/OverlayTabBar.swift`): `setup`,
  `assist`, `transcript`, `notes`, `guide`, `codebook`. `LiveLanding`
  (`RTI/Sources/OverlayPanelView.swift`) picks the tab when a recording
  starts from Prepare: Transcript when the rail shows, Guide for a guided
  start with no rail, else Assist. Tests:
  `RTI/RenderTests/LiveRailRenderProofTests.swift`.
- `OverlayEscapeState` and `OverlayEscapeAction`
  (`RTI/Core/UI/OverlayEscapeOrder.swift`): what `esc` does, in order:
  pass to the input method, close find, stop the stream, clear text,
  nothing (the window-level layer step went with the header chooser,
  2026-11-13; the composer's chooser and palette take `esc` through
  `ComposerKeyRouter`). Tests: `RTI/Tests/OverlayEscapeOrderTests.swift`.
- `RTIWindowKind` (`RTI/Core/UI/MainMenuValidation.swift`) names the key
  window for menu validation. Tests: `RTI/Tests/MenuValidationTests.swift`.
- `SessionsWindowRules` (`RTI/Core/Session/SessionsWindowRules.swift`)
  holds the Sessions and Chats page rules. Tests:
  `RTI/Tests/SessionsWindowRulesTests.swift`.

## Chat streaming and composer

- `StreamCoalescer` (`RTI/Core/LLM/StreamCoalescer.swift`): `pending`
  text and the last flush time. Events: `append(_:now:)`, `flush(now:)`.
  Effects: write at most every 80 ms or at a paragraph break. The owner
  flushes on finish, failure and cancel, so the answer is complete.
  Tests: `RTI/Tests/StreamCoalescerTests.swift`,
  `RTI/RenderTests/ChatRuntimeIntegrationTests.swift`.
- Chat history cap (`PromptBuilder.buildConversationMessages`,
  `RTI/Core/LLM/PromptBuilder.swift`): no stored state. Each turn sends
  the 12 newest prior exchanges (`historyTurnCap`) within about 24k
  characters (`historyCharacterCap`). The latest user turn and the
  newest prior exchange are always sent. A cut history starts with a
  user message. Tests: `RTI/Tests/PromptBuilderTests.swift`.
- `ComposerState` (`RTI/Core/LLM/ComposerState.swift`), with
  `ComposerAttachmentStatus` (`ready`, `reading`, `failed`),
  `ComposerLayer` and `ComposerSourcesStatus`. Tests:
  `RTI/Tests/ComposerStateTests.swift`,
  `RTI/Tests/ComposerSourcesStatusTests.swift`.
- `ComposerDocument.Phase` (`RTI/Sources/UI/Overlay/ComposerDocument.swift`):
  `reading`, `ready`, `failed`. `AttachmentChipModel.Phase`
  (`RTI/Sources/UI/HouseChat/HouseAttachmentChip.swift`): the same three
  for a chip. Tests: `RTI/RenderTests/ComposerConversationBoundaryTests.swift`,
  `RTI/RenderTests/ComposerRenderProofTests.swift`. No test names
  `AttachmentChipModel` directly.
- `OverlayInputState` (`RTI/Sources/UI/Overlay/OverlayInputState.swift`)
  and `ThreadFindState` (`RTI/Sources/UI/HouseChat/HouseFindBar.swift`)
  hold the draft and the find bar. Tests:
  `RTI/RenderTests/ComposerRenderProofTests.swift`,
  `RTI/RenderTests/AssistThreadRenderProofTests.swift`.
- `LateChatArchiveRefresher` (`RTI/Sources/Session/LateChatArchiveRefresher.swift`):
  a target (session id, the stop snapshot, archive folder, call type,
  `filedBeforeArchive`). Events: `begin` at Stop, `archived` after
  completeStop wrote the archive and sidecar, `.rtiChatTurnFiled` (posted
  by `persistTerminalTurn` with the turn's session ids). Effects: a turn
  of the stopped recording filed after Stop re-reads its chats from the
  store and rewrites only `chat.md` and the `-rti.md` sidecar; one filed
  before `archived` is remembered and rewritten then. Stop does not wait
  for a streaming answer. The target lasts until the next Stop (NET-7).
  `.rtiNotesBlockAdded` (posted by `NotesGenerationController` with the
  session id and every block) does the same for a notes block that lands
  after `archived`: it rewrites only `notes.md` and the sidecar, and a
  failed write sets the coordinator's error (F2, batch 6).
  Tests: `RTI/RenderTests/LateChatArchiveTests.swift`,
  `RTI/RenderTests/LiveNotesTests.swift`.
- `VaultRetrieval.Status` (`RTI/Core/LLM/VaultRetrieval.swift`):
  `available`, `noMatch`, `unavailable(reason:)`. Tests:
  `RTI/RenderTests/AssistSearchCancelTests.swift`.

## Screen context

`VisualContextTrail.State` (`RTI/Sources/Screenshot/VisualContextTrail.swift`):
`disabled`, `idle`, `waiting`, `capturing`, `active`, `paused`,
`permissionRequired`, `failed`. Session pause and resume set `paused`.
Stop ends capture. Tests: `RTI/RenderTests/ScreenshotPolicyTests.swift`.

## Library and setup

These hold state for a page or a check. None of them is part of a live
call.

| Type | States | Tests |
|---|---|---|
| `ChatLibraryRules` source `State` (`RTI/Core/Session/ChatLibraryRules.swift`) | `verified`, `missing`, `mismatched`, `unverifiable`, `noArchive` | `RTI/Tests/ChatLibraryRulesTests.swift` |
| `ChatLibraryLegacy.State` (`RTI/Core/Session/ChatLibraryLegacy.swift`) | `read(skippedLines:)`, `unreadable` | `RTI/Tests/ChatLibraryRulesTests.swift` |
| `SessionsWindowModel.ContentSearchState` (`RTI/Sources/UI/SessionsControl/SessionsWindowModel+Types.swift`) | `idle`, `searching`, `done`, `unavailable` | none |
| `CalendarMeetingStore.AccessState` (`RTI/Sources/Session/CalendarMeetingStore.swift`) | `notDetermined`, `denied`, `available` | none |
| `AppPermissions.State` (`RTI/Sources/UI/Onboarding/AppPermissions.swift`) | `granted`, `denied`, `notDetermined` | none |
| `ScriptRunState` (private, `RTI/Sources/Session/TranscriptUpgradeService.swift`) | not finished, finished (one time) | none |
| `ThreadGate` (private actor, `RTI/Core/LLM/ChatThreadStore.swift`) | one write per thread at a time | none |
| `GuideRoster` `FieldState` (CSV parser, `RTI/Core/Guide/GuideRoster.swift`) | `plain`, `quoted`, `afterQuote` | none |

## Rules for a new state type

- Put the rule in a pure value in `RTI/Core` with a `reduce` or an
  `advance` that returns the effect. The controller applies the effect.
- Capture the owner's token (generation, pass ID, session ID) before an
  `await`. Check it before you write a result, an error or a busy flag.
- Reset it from the session spine above. Do not add a second spine.
- Keep it in memory. Do not archive it, and do not add an index.
- Add an entry here with its test file in the same change.
