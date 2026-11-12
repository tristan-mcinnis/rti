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
    else `done`.
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
| `completeStop` | `ResearchCodebookController.finish` and `GuideSessionController.finish` (final drain), `MicControl` `.sessionStopped`, `GuideSessionController.endSession`, then the upgrade. |
| `emergencyShutdown` | `MicControl` `.sessionStopped`, health to `idle`, phase to `idle`. |

- Header mirror: `OverlayLivePhase` (`RTI/Core/UI/OverlayShellStatus.swift`)
  has the same six cases. `OverlayShellStatus` maps a phase to the header
  word, tone and record chip.
- Tests: `RTI/Tests/MenuStatusTickTests.swift`,
  `RTI/Tests/OverlayShellStatusTests.swift`,
  `RTI/RenderTests/SessionStopErrorTests.swift`,
  `RTI/RenderTests/SessionCaptureFailurePolicyTests.swift`,
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
  (`failed`, after `maxRetries` = 5), stop (`idle`).
- Effects: the header and the Transcript show the state. Only the current
  socket can change it: `emitStatus` checks the delivery generation.
- Tests: `RTI/RenderTests/SonioxClientSocketEventTests.swift`,
  `RTI/RenderTests/AudioPipelineRecoveryTests.swift`.

`SystemAudioCaptureHealth` (`RTI/Sources/Audio/SystemAudioCapture.swift`)
is a sample, not a machine: buffer time, audible time and RMS levels.
`AudioPipeline` reads it to tell a silent leg from a dead one. Tests:
`RTI/RenderTests/AudioPipelineRecoveryTests.swift`.

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
  now"), `passFinished(generation:endMs:)`, `cancelPending`, `stop`,
  `reset`.
- Effects: `none`, `disarm`, `arm(at:)`, `startPass(generation:)`. The
  controller holds the one timer and runs the pass. The debounce is 7 s
  (`quietWindow`). The floor is 60 s on client and research calls
  (`floor(for:)`), nil on internal and personal calls. Only
  `passRequested` skips the floor. Only an accepted pass moves the
  watermark. `stop` and `reset` bump the generation, so an old reply is
  dropped.
- Tests: `RTI/Tests/AutoPassStateTests.swift`,
  `RTI/RenderTests/AutoAssistControllerTests.swift`.

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
  arms one timer for that. A dismissed text never comes back. A card
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
  (scheduler tick or "Write notes now").
- Effects: a pass appends one note block. Only the owning generation can
  clear `isGenerating` or write a result. The session archive writes the
  notes on stop (`notes.md` and the `-rti.md` sidecar), as before.
- Tests: `RTI/RenderTests/LiveNotesTests.swift`.

## Guide

`GuideSessionController` (`RTI/Sources/Notes/GuideSessionController.swift`).

- States: inactive (no session ID), active and following live
  (`isFollowing`), active on a manual question (`manualQuestionID`),
  `isGenerating`, `sealed` (after `finish`). It also keeps
  `furthestIndex`, the cursor and the extraction.
- Events: `startPreparedSession` (research call with a prepared guide,
  else it resets `GuidePreparation`), `generate`, `move(by:)`,
  `jump(to:)`, `select`, `followLive`, `selectMarker`,
  `markersDidChange`, `finish` (final drain under an 8 s deadline),
  `endSession`.
- Effects: each pass files quotes against guide questions. A
  `passRevision` bump drops an old pass. After `finish` no periodic pass
  runs. `endSession` clears all state.
- Derived: `GuideGap.State` (`RTI/Core/Guide/GuideGaps.swift`) is
  `skipped`, `thin(quotes:)` or `oneSeat(quotes:)`. `GuideGaps.find`
  computes it from the extraction on read, up to 5 gaps. It keeps no
  state. The rail and the Auto research prompt read it.
- Tests: `RTI/RenderTests/GuideLiveTimingTests.swift`,
  `RTI/RenderTests/GuideGapsControllerTests.swift`,
  `RTI/RenderTests/GuideRenderProofTests.swift`,
  `RTI/Tests/GuideGapsTests.swift`.

## Codebook

`ResearchCodebookController` (`RTI/Sources/Codebook/ResearchCodebookController.swift`).

- States: no `location` (not a research call), preparing (a
  `preparation` task), ready, `generating`, `sealed`. A `passID` token
  owns each pass.
- Events: `start(sessionID:at:callType:)`, `generate`, `finish` (final
  drain under an 8 s deadline), `edit`, `star`, `retryProjectMerge`,
  `markersDidChange`.
- Effects: a pass merges proposals into the codebook through
  `ResearchCodebookStore` (on disk, in the session folder and the
  project). A new `passID` or `location` drops an old result. The rail
  shows `topicMap` from the book.
- Tests: `RTI/RenderTests/ResearchCodebookTests.swift` covers the store
  and the topic map. No test drives the controller's states directly;
  `RTI/RenderTests/LiveRailRenderProofTests.swift` and
  `RTI/RenderTests/CommandPaletteFocusProofTests.swift` use it.

## Transcript upgrade

The upgrade is the `upgrading` phase plus an on-disk marker.

- States: pending marker set (`SessionArchive.markAutomaticUpgradePending`),
  running (`runUpgradePhase`, `postProcessingStatus` shows progress),
  cleared (`clearAutomaticUpgradePending`) or kept for retry.
- Events: `completeStop` starts it. Success clears the marker. Failure
  keeps the audio and the marker. At the next launch,
  `SessionArchive.pendingAutomaticUpgrades` runs each one again
  (`AppDelegate`). `TranscriptUpgradeService.upgradeRetryingOnce` tries
  twice.
- Effects: the end sets `done` only for the current session. It clears
  the chat only if the chat is still as Stop left it (`UpgradeChatMark`).
- Tests: `RTI/RenderTests/AssistSearchCancelTests.swift`
  (`runUpgradePhaseForProof`), `RTI/RenderTests/SessionArchiveRecoveryTests.swift`.

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
- `OverlayShellModel.Chooser` (`RTI/Sources/OverlayPanelView.swift`):
  which header chooser is open, or nil.
- `OverlayEscapeState` and `OverlayEscapeAction`
  (`RTI/Core/UI/OverlayEscapeOrder.swift`): what `esc` does, in order:
  pass to the input method, close a layer, close find, stop the stream,
  clear text, nothing. Tests: `RTI/Tests/OverlayEscapeOrderTests.swift`.
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
