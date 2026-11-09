# RTI state-machine audit, 2026-11-09

## Decision

Keep one local owner per lifecycle. Admit asynchronous results using the identity of the operation that started them, and apply that check to completion, errors and cleanup as well as successful output. Keep recording, transcription, upgrades, navigation and chat independent. Their valid overlapping states would be harder to express in a global app-state enum.

This improves UX by preventing obsolete work from changing the current session, DX by keeping transition rules beside their owner, and AX by giving agents source locations, explicit invariants and deterministic regression tests. It adds no dependency, index, persistent registry or new UI flow.

The source and tests are authoritative. This is a dated audit of the app's meaningful stateful workflows, including already-explicit machines; small focus/hover states are grouped with their UI owner. It is not an exhaustive proof of every asynchronous interleaving. Paths and line references describe the inspected revision, based on `dfd0244b`; line numbers can drift. Cross-area rows intentionally overlap where lifetimes meet.

## Transition review rule

For each asynchronous operation, identify the owner and the lifetime token (socket, session ID, request ID or generation). Capture it before suspension. After suspension or callback dispatch, check it before changing output, errors, watermarks, busy flags or resource ownership. Cancellation requests alone are insufficient. Test old work completing after reset and after replacement, plus the current operation's successful and failed terminal paths. Keep valid orthogonal states separate: muted is not paused, disconnected transcription is not stopped recording, and an old archive upgrade is not the current session.

## Changes selected

- Soniox accepts text frames only from its current socket. Old words and errors cannot enter a replacement stream through that event path. Current-socket final words remain accepted during finalization. Logs do not include rejected text payloads.
- Notes and Auto release busy state only for their own generation. Notes rejects stale failures before showing an error. Auto checks ownership after awaited retrieval before starting a model request.
- Controller requests are injectable for deterministic suspended-completion tests, while production defaults remain unchanged.
- Corrected stale persistence comments in SessionCoordinator and TranscriptPipeline.

These targeted repairs use patterns already present in chat and session library loading. No broad enum migration was justified by the evidence. Remaining risks below are follow-up candidates, not claims that those paths were runtime reproduced.

## Verification

See the final verification section below. Inventory evidence names existing tests; it does not imply that hardware, network or OS permissions were exercised by those tests.



## Capture inventory

Source inspection: 2026-11-09. Runtime source and tests are authoritative; this is an audit snapshot, not a second state registry.

## Bounded improvement implemented

`RTI/Sources/Soniox/SonioxClient.swift:132` now rejects replaced sockets' text events alongside lifecycle events. This prevents stale transcript tokens, authentication failures and retryable errors from affecting the current stream. Ignored-event logging omits payloads to protect transcript content.

`RTI/RenderTests/SonioxClientSocketEventTests.swift` adds regression coverage for stale transcript/error frames and preservation of current-socket final tokens during finalization.

Validation is consolidated at the end of this report.

## Inventory

| Machine and owner | States/events and invariant | Existing evidence |
|---|---|---|
| Session lifecycle, `SessionCoordinator.swift:22`, `SessionPhase.swift:16` | Explicit idle → recording ⇄ paused → finishing → upgrading → done. New recording can supersede upgrading; upgrade completion checks session ID. | `SessionCaptureFailurePolicyTests`, `SessionStopErrorTests`, `SessionArchiveRecoveryTests` |
| Permission/start admission, `PendingStartGate.swift:8`, `SessionCoordinator.swift:414` | No request → pending token → resolve/cancel. Repeated start cannot launch twice; cancelled permission callback cannot start capture. | PendingStartGate tests; coordinator path still coupled to system permission |
| Capture lifecycle, `AudioPipeline.swift:261` | Unprepared → prepared WAV/client owners → capturing → finalizing → closed; abort from failure. Implicit in resource optionals, isCapturing, generation. | `AudioPipelineRecoveryTests` |
| Mic mute and pause, `AudioPipeline.swift:84`, `SessionCoordinator.swift:367` | Orthogonal enabled/muted and recording/paused; paused time excluded from displayed timer; WAV silence retains timeline. | Paused provider retry regression in `AudioPipelineRecoveryTests` |
| Per-leg transcription connection, `SonioxClient.swift:30` | Disconnected → connecting → configured/live → retry waiting → reconnecting or failed → intentional finalization/disconnection. Implicit Boolean product plus socket identity and retry handle. | `SonioxClientSocketEventTests`, `SonioxFailureTests` |
| System STT parking, `AudioPipeline.swift:482` | Await first PCM → connected → idle threshold → parked → PCM resumes/reconnects. Capture and WAV ownership continue while STT sleeps. | Recovery tests cover broader retained-audio policy; parking-specific coverage is limited |
| Mic watchdog/recovery, `AudioPipeline.swift:568` | Startup grace → buffers flowing, missing buffers or zero samples → restart/notice/fatal outage. Restart clock must not reset session clock. | Device-rebind and missing-device tests in `AudioPipelineRecoveryTests` |
| System capture health, `AudioPipeline.swift:645` | Grace → healthy → recovery cooldown/attempts → backend fallback or persistent notice → healthy. Health only recovers after observed audio. | System interruption test in `AudioPipelineRecoveryTests` |
| CoreAudio tap resources/recovery, `CoreAudioTapCapture.swift:28` | Tap/device/IO proc creation → active generation → device-change or stall rebuild → teardown/failed. Old-generation PCM must be ignored. | Hardware-specific behavior needs device verification |
| ScreenCaptureKit recovery, `SystemAudioCapture.swift:47` | Desired running versus actual stream, restart in flight, watchdog; stop must win over asynchronous restart. | No dedicated deterministic backend state tests found |
| Mic engine/device rebind, `AudioCaptureManager.swift:40` | Engine stopped → configured/tapped/running → configuration change/restart → stopped. Mute and zero-sample tracking are orthogonal. | Audio input tests plus pipeline fake-device tests |
| Bluetooth input lease, `BluetoothMicGuard.swift:19` | Unowned → temporarily rerouted → released. Restore original input only if user has not changed the route themselves. | No dedicated test found |
| Durable recording, `WAVWriter.swift:52` | Closed → both legs open → append/silence → close; independent per-leg time anchors and sample counts. Failure latch retains first failure synchronously. | `MeetingRecorderTests`, `SessionAudioTimelineTests`, recovery close-failure tests |
| Transcript aggregation, `TranscriptAggregator.swift:11` | Pending tokens → final runs; stream reset/rebase retains prior finals but changes stream identity and origin. | `TranscriptAggregatorTests`, `TranscriptPipelineTests` |
| Transcript merge/projection, `TranscriptPipeline.swift:18` | Dirty merge → cached merge; open entries become settled after safe horizon, invalidated by eviction/out-of-order changes. | `TranscriptPipelineTests`, presentation/turn tests |
| Transcript publish coalescing, `SessionCoordinator.swift:810` | Clean → scheduled publication → flush; session reset increments generation to reject queued old publication. | Transcript render/replay proofs |
| Capture/transcription error presentation, `SessionCoordinator.swift:300`, `:869` | Per-leg failures → aggregate banner → successful leg recovery or timed retirement. Fatal capture errors stop; STT errors preserve recording. | `SessionCaptureFailurePolicyTests`, `SessionStopErrorTests` |
| Archive checkpoint/finalization, `SessionCoordinator+Archive.swift`, `SessionFinalizer.swift:30` | Seed/checkpoint → stop snapshot → archive/sidecar written or save failure. Retained audio remains recovery authority. | `SessionArchiveRecoveryTests`, metadata/title tests |
| Durable upgrade queue, `SessionArchive.swift:34`, `AppDelegate.swift:75` | Pending marker → upgrade attempt → cleared on success; failure remains queued for next launch. Short empty recovered sessions are explicitly retired. | Archive recovery and upgrade tests |
| Offline upgrade transaction, `TranscriptUpgradeService.swift:80`, `TranscriptUpgrade.swift:169` | Discover legs → transcribe → merge → recoverable artifact installation → canonical export/processor; provider failure retries once after delay. | `TranscriptUpgradeTests` |
| Child-process completion, `TranscriptUpgradeService.swift:303` | Running → exited or timed out; lock-protected finished gates one completion. | No focused completion-race test found |

## Deferred risks

1. **Finalization while reconnecting:** `SonioxClient.finalize():121` returns when not connected before setting intentionalDisconnect or cancelling retry. A retry can therefore open during the stop flush. Needs a dedicated stop/retry regression before changing.
2. **Stale client callbacks after provider replacement:** `AudioPipeline.reconfigureStreamingClients():807` attaches closures without client-generation admission. A callback already queued by the old client can still reach the pipeline. Socket fencing fixes events entering from replaced sockets within one client, not every queued callback across client instances.
3. **Upgrade overlap:** launch recovery, automatic completion and manual upgrade have separate entry points without a visible per-directory job owner. Concurrent upgrade/write/processor work is possible; test and establish shared ownership before altering it.
4. **Start-failure state:** launchSession sets session ID/start time before preparation; failure returns without rolling them back. Phase and metadata can disagree. A full session lifecycle reducer would be too broad for this pass.
5. **Documentation drift:** `SessionCoordinator.swift:7` and `TranscriptPipeline.swift:5` claim no persistence/only in-memory records, contrary to the current archive implementation. Corrected in this change.
6. **Asynchronous backend recovery:** fallback checks isCapturing after awaiting start, but does not compare capture generation. Stop followed by a new start during an old fallback deserves a generation-isolation regression.

## Design decision

Keep independent capture, transcription and archive/upgrade lifecycles separate, with one owner per lifecycle and explicit admission of asynchronous results by socket/session/generation identity. Combining them into one global enum would obscure the intentional behavior where recording continues through transcription failure or a new session begins while an old upgrade finishes.


## Chat inventory

Source audit, 2026-11-09. Read-only; no runtime reproduction or tests run by this auditor. Chat-table paths below are relative to the repository’s RTI/ directory. This is an audit snapshot, not a new state registry.

| Machine | Owner and source | States/events and invariant | Existing evidence |
|---|---|---|---|
| Active send/answer | Sources/LLM/LLMController.swift:37-169; +Send.swift:234-396; +Actions.swift:421 | Idle, persisting, streaming/reasoning/tools, completed/failed/cancelled represented by booleans, IDs, PendingTurn and Task. Generation plus entry ID fence callbacks. | ChatRuntimeIntegrationTests; ChatSourceLifecycleTests |
| Durable submission | Sources/LLM/LLMController+Threads.swift:332-458 | PersistOutcome is saved/noStore/aborted/failed. Provider starts after submission saved; failed persistence restores text draft. | ChatRuntimeIntegrationTests |
| Checkpoint and terminal ordering | Sources/LLM/LLMController+Commands.swift:113-155; +Threads.swift:15; Core/LLM/ChatThreadStore.swift:626 | Periodic writing, cancelled/drained, terminal write. Store refuses checkpoint resurrection of terminal rows. | ChatThreadStoreTests; ChatSourceLifecycleTests |
| Conversation identity and resume | Sources/LLM/LLMController+Threads.swift:36-95,170-238 | Active/reset/loading/rehydrated/failed, resumeRequestID and generation. Latest resume alone replaces active state; reset preserves disk. | ComposerConversationBoundaryTests; ChatSourceLifecycleTests |
| Retained sources | Sources/LLM/LLMController+Threads.swift:58,242; +Send.swift source selection | Pending/submitted/retained/rehydrated/missing. New chat clears in-memory context, preserves saved bytes. | ChatSourceLifecycleTests |
| Screenshot attachment | Sources/LLM/LLMController+Actions.swift:368-419 | Empty/capturing/ready/failed. Request identity rejects suspended reader after removal/replacement. | ChatRuntimeIntegrationTests; ChatSourceLifecycleTests |
| Dated source seed | Sources/LLM/LLMController+Threads.swift:97; LLMController.swift:187 | Pending source consumed only on saved/noStore, guarded by equality with captured source. | ChatRuntimeIntegrationTests:429 |
| Document extraction | Sources/UI/Overlay/ComposerDocument.swift:11; AssistantInputView+Submit.swift:1-100 | Explicit reading/ready/failed per chip; removal ignores later extractor result. | ComposerConversationBoundaryTests |
| Composer follow-up queue/reset/handoff | Sources/UI/Overlay/AssistantInputView.swift:443; +Submit.swift:225; +Layers.swift:152 | Queued/stream ending/submitting/disarmed. Conversation switch disarms old follow-up. | ComposerConversationBoundaryTests |
| Composer action and layer dispatch | Core/LLM/ComposerState.swift; ComposerKeyRouter.swift | Multiple orthogonal booleans plus ComposerLayer; chooser, notes, blocked attachment, queue and send precedence. | ComposerStateTests; ComposerKeyRouterTests |
| Provider request ownership | Sources/LLM/LLMRequest.swift:390-438 | SingleFlight generation and Task: idle/reserved/installed/finished/cancelled. Stale finish cannot release replacement request. | LLMRequestPriorityTests |
| Foreground/background admission | Core/LLM/LLMAdmission.swift:111 | Foreground lease set, epoch, background/epoch waiters; waiting/admitted/preempted/cancelled/released. AdmissionWaiter resumes once. | LLMAdmissionTests; LLMRequestPriorityTests |
| Tool loop | Sources/LLM/ToolLoop.swift:78-169 | Stream/tools/stream, four-round cap; done/error/cancel. One foreground lease spans whole turn. | ChatRuntimeIntegrationTests:553 |
| Tool execution and budget | Core/LLM/ToolExecutor.swift:47-158 | Policy admission, execution, timeout/failure/refusal; mutable search/call counts and RunEnd. | ToolExecutorTests; ChatToolPolicyTests |
| SSE parser | Core/LLM/SSEStreamParser.swift:24-100 | Fragments accumulate by tool index; content/reasoning/done/error events. Caller owns terminal state. | SSEStreamParserTests |
| Chat library loading and mutations | Sources/UI/SessionsControl/ChatLibraryModel.swift:54-92 | Separate list load, detail load, rename and delete machines; reload/detail generations and deletion identity. | ChatLibraryModelTests; ChatLibraryFreshnessTests |
| Store mutation/deletion ownership | Core/LLM/ChatThreadStore.swift:217-280,426,824-864 | Per-thread gate serializes mutations; deleted-thread tombstones reject late append; reference-aware artifact removal. | ChatThreadStoreTests |

## Concrete follow-up

`LLMController+Send.swift:49-51` consumes pending screenshot text/image before route admission at lines 77-86 or durable submission at 235 onward. Route refusal therefore loses the pending screenshot. Storage failure restores text only. This is static source evidence, not a runtime-proven defect in this audit.

Recommended next scoped change: retain the screenshot until the captured submission succeeds, and consume it only if its attachment identity is still current. Preserve newer screenshots attached while persistence is suspended. Test blocked route, failed persistence, successful consumption, replacement during persistence, and reset/cancel. The dated-source lifecycle already provides a nearby pattern.

Keep these independent lifetimes separate. A single global app-state enum would couple unrelated operations and make valid combinations harder to represent.


## UI, screen and background generation inventory

Source snapshot: working tree inspected 2026-11-09. Static audit, not a proof that every runtime interleaving is covered. UI hover/focus animation booleans are grouped with their owning presentation machine.

| Machine | Owner/source | States/events/invariants | Evidence and risk |
|---|---|---|---|
| Workspace routing and visibility | `RTI/Sources/UI/Workspace/WorkspaceModel.swift` | Page enum Live/Sessions/Chats/Settings plus window visibility; select/hide/show updates library visibility, pauses playback, closes action layers; capture and composer survive navigation. | `WorkspaceVisibilityRegressionTests`, `WorkspaceRenderProofTests`. Existing explicit page plus implicit visibility product is deliberate. |
| Return from resumed chat to session | `WorkspaceModel.swift` | chatOrigin + resumedChatID + hasResumedChat encode none/prepared/loading/resumed; prepare, conversationDidChange, finishResume, reset, return. Only explicit durable session links grant return navigation. | Workspace proofs. Candidate enum migration, no demonstrated defect. |
| Live tab and chooser presentation | `OverlayShellModel` in overlay sources; `OverlayInputState.swift`; `AssistantInputView+Layers.swift` | Visible tab constrained by enabled Auto/Notes; composer mode chat/liveNote; chooser selection, focus generation and dismissal; commands and menus share owners. | Composer/command-palette render tests and LiveNotesTests tab assertions. Keep independent navigation and recording state. |
| Composer document reading | `UI/Overlay/ComposerDocument.swift`, assistant add-context handlers | Explicit reading/ready(attachment)/failed(reason), remove and submission; a removed document must not return when reading completes. | Existing explicit Phase is a good local pattern; attachment lifecycle additionally covered by chat audit. |
| Mention suggestions | `UI/Overlay/MentionSuggestionStore.swift` | query/scope/candidates/isSearching/task encode absent/loading/cached-refresh/results; cancel old task, debounce typed queries, cache 40 entries. | Completion checks cancellation. No confirmed stale overwrite. Old candidates remain while new uncached query loads; verify presentation hides these before changing. |
| Session library reload | `UI/SessionsControl/SessionsWindowModel+Browse.swift` | unloaded/loading/loaded using hasLoaded/isLoading/reloadGeneration; newest generation alone applies results and releases busy. | Existing generation-guarded defer is correct precedent for Auto/Notes fix. |
| Session content search | same Browse file | idle/searching/available/unavailable plus query, snippets, task; query edit cancels and debounces search; clear resets projections. | `SessionsWindowRulesTests`, sessions render tests. |
| Session reader/find | SessionsWindowModel and +Reader/+Browse | open row, files, selected file, parsed document; find presentation/query/hit index; selecting session resets editor/reader state, next/previous wraps. | Sessions render proofs and rule tests. |
| Session actions, rename and deletion | SessionsWindowModel+Commands/+Browse | layer placement/row/highlight/query; rename row/text; deletion confirmation/pending row/request/in-flight; escape closes highest layer. | Sessions proofs. Several correlated optional fields; migrate only with a concrete invalid-state repro. |
| Saved-session editing/upgrade choice | SessionsWindowModel+Reader and SessionEditors | transcript edit vs display; speaker sheet; upgrade-choice/pending target/upgrading target/notice; target identity must survive navigation. | Session render tests; actual upgrade engine audited by capture agent. |
| Archived audio playback | `UI/SessionsControl/SessionAudioPlayback.swift` | actor Snapshot and UI model: unloaded/loading/paused/playing/ended/error; generation scopes load/update/stop, pendingAction coalesces play/pause/seek; navigation pauses. | `SessionPlaybackActionProofTests`. Explicit action enum; generation protects replaced players. |
| Meeting brief reader | `UI/MeetingBrief/MeetingBriefView.swift` | list/query/highlight/selection/content/rail visibility; reload/open, attached sheet owned by workspace. | Brief render tests; synchronous selection, low risk. |
| Provider draft | `Settings/ProviderSettingsDraft.swift` | uninitialized/clean/dirty/saved/failed via baseline and draft snapshot, saved/error; load preserves dirty edits, save verifies key writes before selecting provider. | `SettingsDraftWorkflowTests`. Failure retains user draft; already a useful small interface. |
| Prompt draft | `Settings/PromptSettingsDraft.swift` | per-prompt baseline/text, prepared/dirty/reset; tab navigation preserves drafts. | Settings draft tests. |
| Onboarding and permissions | `UI/Onboarding/OnboardingView.swift`, `AppPermissions.swift` | credential saved/edited/error plus mic and screen permission enums; request/refresh/save/finish gating. | `OnboardingChecklistTests`, `SettingsOnboardingRenderProofTests`. OS is permission authority. |
| Launch at login | `Settings/LaunchAtLogin.swift` | OS SMAppService status → enabled/requires approval/not registered; register/unregister/settings route. | OS-owned state, avoid duplicating state. |
| Manual screenshot attachment | `Screenshot/ScreenshotManager.swift` | attachment task and LLM-owned request ID encode capturing/OCR/ready/failed/superseded; check request identity after suspension before attaching; denylist shared capture filter. | Shared attachment request checks already protect supersession; chat audit owns resulting pending attachment. |
| Ambient screen trail | `Screenshot/VisualContextTrail.swift` | Explicit disabled/idle/waiting/capturing/active/paused/permissionRequired/failed; task lifetime and sessionStartedAt additionally encode running session. start/stop/pause/toggle/capture success/failure. | Cancellation guards after screenshot await protect pause/stop. Event-ID attachment prevents old local vision result attaching to new-session event. `VisualContextEventTests`, `VisualFrameStoreTests` cover values/storage, not whole async controller. |
| Screen highlight | `Screenshot/ScreenHighlightOverlay.swift` | hidden/showing/dismissed transient overlay and timeout; last captured text regions provide highlight target. | No concrete defect established. |
| Auto scheduler | `Auto/AutoAssistScheduler.swift` | stopped/running timer plus runGeneration and inFlight tasks; start resets watermarks, stop cancels, drain bounds wait. Generation guards post-await watermark writes. | Controller and admission tests cover adjacent behavior. Scheduler has redundant watermarks because controller owns actual cursor; simplify separately after call-site contract audit. |
| Auto debounce | `Auto/AutoAssistController.swift` | idle/debounce/minimum-interval wait/generating; final transcript arms timer, fire requires recording, manual/scheduled pass shares floor. | Concrete residual risk: fireIfDue does not recheck Auto enabled, so turning Auto off after timer armed can still perform a pass. Separate focused fix needed. |
| Auto generation | same Auto controller | sessionId/generation/isGenerating/lastMs/cards/unseen; reset/clear invalidate old pass; manual/scheduler/debounce compete for one pass. | FIXED this work: old completion no longer clears new busy state; guard after retrieval stops obsolete pass entering request. `LiveNotesTests.testOldAutoCompletionCannotReleaseNewSessionPass`. |
| Notes generation | `Notes/NotesGenerationController.swift` | sessionId/generation/isGenerating/lastNotedMs/notes/error; reset/clear, manual/scheduled generation; failures preserve cursor for retry. | FIXED: old completion cannot clear new busy or set new session error. Two deterministic suspended-completion tests in LiveNotesTests cover reset, clear, failure and retry. |
| Auto unread cards | AutoAssistController + Auto tab | unseenCount increases on accepted cards, markSeen clears; cards trim at 300. | Independent presentation state; don't conflate with generation status. |

Recommendation: preserve distributed ownership and explicit local state where it is already sound. Adopt generation-owned completion as the async controller invariant. A universal state-machine framework or app-wide state object adds abstraction and broad migration risk without fixing the demonstrated races. Keep lifecycle effects beside their owner, expose small injectable dependencies, and test adversarial transitions with suspended completions.

Correction after independent follow-up review: the project contract says no corpus/DB, not no proactive retrieval. Auto intentionally supports grounded recall through local keyword search. Request-gated live chat tool rules do not apply to Auto’s separate opt-in retrieval path. Retrieval is project-first with whole-vault fallback on no project hits, not project-only. See the follow-up evidence below.



## Support workflows

| Machine | Source | Transitions and invariant | Evidence / limitation |
|---|---|---|---|
| Process launch and clean exit | `RTI/Sources/AppDelegate.swift`, `Core/Support/CrashNoticeDecision.swift` | Previous clean-exit marker read, removed on launch, restored at orderly exit; onboarding suppresses inappropriate crash notice. | CrashNoticeDecision tests; abrupt process death is not reproduced here. |
| Local command listener | `Sources/Session/ControlService.swift`, `Core/Control/ControlSocketServer.swift` | Start/bind/listen, snapshot updates, command dispatch, stop; listener uses a locked phase snapshot and session methods guard transitions. | Control tests; service marks started even after bind failure, so retry requires stop/start. |
| Calendar permission and suggestions | `Sources/Session/CalendarMeetingStore.swift` | Undetermined/denied/available; permission completion refreshes OS state, then projects current events. | OS is authority; no calendar mutation. |
| Update checking | `Sources/Update/UpdateChecker.swift` | Request/newer release/no result, followed by user alert choice. | Network error and up-to-date collapse to nil; manual check can say up to date after an error. Static finding, unchanged. |
| Credential file replacement | `Sources/Settings/CredentialStore.swift` | Read/decode or quarantine corruption; write private sibling temp then atomically replace. | Provider draft uses write success before changing selection; no credentials inspected. |

## Prioritized follow-up

1. Preserve pending screenshots until submission succeeds, with identity-aware consumption. Test route rejection, write failure, cancellation and replacement while saving.
2. Fence already-queued transcript callbacks at delivery and across provider-client replacement. Socket receipt fencing alone does not cover those distinct lifetimes.
3. Test stop during reconnect and stop/start during backend recovery before changing those capture transitions.
4. Establish per-archive ownership for overlapping offline upgrades, with recovery tests before altering artifact writes.
5. Recheck Auto enabled when an armed debounce fires; prove disable-before-fire behavior.
6. Roll back session start metadata on preparation failure; distinguish failed update checks from successful up-to-date results.

Superseded interpretation: this audit originally called Auto retrieval a transcript-only contract mismatch. Independent review found that inference unsupported; current prompts, restored behavior and citation tests support grounded recall. The broader no-hit fallback is a separate scope/disclosure question, preserved in this lifecycle change. Stale comments claiming no session persistence were corrected; the archive remains current behavior.

## Final verification, 2026-11-09

- `make check`: all targets compiled.
- `make build`: passed with warnings treated as errors.
- `make test`: 786 tests, two skipped, zero failures.
- `make test-render`: 318 tests, one skipped, zero failures, including all five new regression tests. The three Notes/Auto tests use explicit continuation ordering; the two original Soniox tests use timed waits, not deterministic queue ordering.
- `scripts/scrub.sh`: `SCRUB_CLEAN`.
- `design-lint --strict --changed .`: zero hits on touched source files.
- `git diff --check`: passed.
- Independent chat auditor reviewed the integrated runtime/test diff: no blocking findings.

These checks validate the selected changes, not every possible hardware/network race. The test suite uses invented fixtures; no real meeting or provider request was started for this audit.


## Independent follow-up from 6b4e91f4

The previous completion report was rechecked against the clean current tree, installed commit stamp, source, test bodies and history. Three independent reviewers covered ownership, Auto intent and risk ranking. Their findings were reconciled before choosing the change.

### Decision: finish transcription callback ownership

A current-at-receipt socket event could queue words, health or errors, then deliver after replacement/disconnect. Separately, the audio pipeline accepted callbacks from retired clients on both legs. Those callbacks can change transcript content, failure banners and timestamp rebasing, and therefore the input to a later archive. This potential durable contamination takes priority over the simpler screenshot draft-loss defect.

Keep both lifetimes explicit: a socket stream owns queued Soniox delivery; the pipeline's currently installed client owns delivery to each recording leg. Publish ownership before connect, revoke it before disconnect, and retain it through finalize until finish. Navigation does not retire these owners: recording continues when the Live page is hidden.

UX: prevent old words and false health/errors in the current meeting while preserving graceful final-word flush. DX: concentrate admission in Soniox and one pipeline callback-binding helper. AX: tests name the replacement/teardown transitions and prove event ordering directly. Trade-off: queued events from a retired stream are discarded even when received before replacement; retained WAV and the offline transcript upgrade remain the recovery path. No new persisted state or product flow is added.

### What the previous tests actually prove

- The two prior Soniox additions reject already-replaced sockets and allow current finals during finalize. Their 0.3-second waits do not prove current-at-receipt/obsolete-at-delivery ordering.
- The three Notes/Auto continuation tests prove reset/clear busy ownership and Notes error/retry behavior. Injected foreground requests isolate controller ownership; they do not prove background preemption, manual work during stop, network cancellation or archive completion.
- Chat generation and terminal-store guards protect separate conversation lifetimes. Hiding the workspace is deliberately not cancellation. No blanket navigation cancellation was introduced.

### Auto: corrected guidance, preserved implementation

The audit's transcript-only inference was wrong. `CLAUDE.md` prohibits an RTI corpus/DB/index, while allowing local keyword retrieval. Its request-gated retrieval paragraph concerns chat tools. Opt-in Auto is a separate proactive workflow.

Evidence: the default Auto prompt (`RTI/Core/LLM/PromptID.swift`, autoAssistCards) explicitly requests supported RECALL/FLAG from supplied vault material; Auto UI offers recall and asks the user to select a project; `AutoAssistCardTests` validates retrieved source handles. Original commit `75cd9eae` introduces grounded Auto. The `a62fdf79` minimal experiment removed grounding, but `540278de` restored it on August 28. The October 17 trim retained it, and `ff879f5a` subsequently improved citation handling. Recorded decision DEC-20261017-01 retains capture, recall and assist, not transcript-only Auto.

Actual scope is project-first: `VaultSearch.retrieve` broadens to the whole notes folder after no project hits. It is not strict project isolation. No project selected means Auto skips this retrieval branch. Existing tests validate citation mapping, not end-to-end scope, model faithfulness or live retrieval latency.

No unresolved decision blocks this lifecycle repair. A separate product choice remains if retrieval scope changes: after no project hits, return transcript/context-only cards, or search other projects with clear source/scope disclosure. The current fallback is preserved; no rule file was edited.

### Remaining findings, ranked after this repair

| Rank | Finding | Impact / evidence | Implementation risk and next proof |
|---|---|---|---|
| 1 | Pending screenshot consumed before admission/persistence | Lost pending context; confirmed direct control flow | Low-medium. Give ready attachments identity; test blocked route, failed write, replacement during save, cancel/reset and success. |
| 2 | Concurrent upgrades share an archive and output paths | Potential durable write/processing races; multiple entry points confirmed, no runtime reproduction | High. Per-directory job ownership must define coalescing, cancellation, manual edits and downstream processing. |
| 3 | Manual Notes/Auto can outlive ordinary stop | Late content may miss archive; scheduler owns only its own tasks, source evidence | Medium-high. Decide await versus discard for manual work; test stop/drain and exact archive snapshot before changing. |
| 4 | Old asynchronous backend recovery after stop/start | Potential capture disruption; source evidence, hardware unverified | Medium-high. Suspended fake backend start must prove old generation cannot replace new capture. |
| 5 | Finalize while disconnected leaves reconnect retry armed | Extra connection during stop flush; confirmed guard ordering | Low-medium. Controlled retry scheduler test, preserving current final words. |
| 6 | Armed Auto debounce can fire after disabling | Unwanted provider work/context after opt-out; source evidence | Low. Recheck enabled at fire with deterministic debounce test; preserve manual action semantics. |
| 7 | Failed session preparation leaves ID/time metadata | Idle and metadata disagree; source evidence | Medium. Roll back without erasing recoverable artifacts or session chat. |
| 8 | Auto fallback scope lacks clear UI disclosure | Other-project material may appear; code/history support existing behavior | Product trade-off. Resolve strict-project versus clearly labelled fallback separately. |
| 9 | Failed update check reports up to date | Misleading diagnostic; confirmed nil/error collapse | Low. Distinguish error from successful no-update result. |

The previous receipt-only fix did not make all callback transitions safe. This repair addresses queued STT delivery and client ownership; it does not claim atomicity for every concurrent socket-internal mutation, every backend recovery or every archive transaction.

### Focused regression evidence

Before production edits, four new tests ran against 6b4e91f4: 16 selected tests executed and the four additions produced 11 assertion failures. Queued old words, health and errors reached their consumers; retired pipeline clients also delivered. This reproduces the selected defect under controlled scheduling.

The final five additions use explicit main-queue drain ordering, saved fake-client callbacks and synthetic nonempty words. Coverage includes current-at-receipt/obsolete-at-delivery, disconnect/re-adopt on the same client, both legs replaced, synchronous disconnect notifications, current final-word flush, finished/aborted clients and the next capture. The fifth test attempts an old captured retry after adoption cancels it. It proves the combined cancellation/adoption protection, not the retry generation check in isolation.

An independent reviewer checked the runtime diff and final retry addition with no blocking finding. Current lifecycle calls and callback delivery are serialized on the main actor/queue; these tests do not establish arbitrary off-main callers' atomicity. Archive protection is inferred from rejecting obsolete upstream delivery, not a new end-to-end archive-content test. Existing archive recovery tests are run alongside the focused cases.

### Follow-up verification results

- Red baseline: 16 selected tests, four new failing cases, 11 failed assertions before production changes.
- Green focused suite: 51 tests, zero skipped, zero failures. Includes all five additions, LiveNotesTests, SessionArchiveRecoveryTests, SessionStopErrorTests, SessionCaptureFailurePolicyTests and WorkspaceVisibilityRegressionTests.
- `make check` and `make build`: passed; all targets compiled with warnings-as-errors policy unchanged.
- `make test`: 786 tests, two skipped, zero failures.
- Strict changed-file design lint: zero hits in two touched runtime files. Source scrub: `SCRUB_CLEAN`. `git diff --check`: passed.
- Full render suite was not repeated for this nonvisual change; the relevant capture-policy and workspace visibility proofs ran in the focused suite. Previous full-render counts above belong to 6b4e91f4 and are not presented as new verification.
- Tests use fake provider clients, explicit queued delivery, synthetic PCM and fixture files. No real audio device, Bluetooth transition, Soniox network reconnect, live model request or real meeting archive race was exercised.
