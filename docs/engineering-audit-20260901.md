# RTI engineering audit — 2026-09-01

Question asked: "this still feels a bit vibecoded — what would a professional look at?"
Method: full-tree survey of RTI/Sources (112 files, ~24.7k LOC), RTI/Core (~4.2k LOC), RTI/Tests (~3.5k LOC).
Status of items: none fixed yet except where noted; this is the worklist.

**Headline:** the architecture is above hobby grade (testable RTICore split, CI, notarized release
script, design tokens, zero TODO/FIXME in the tree). What separates it from professional is:
failure semantics (the durable write path swallows every error), Swift 6 concurrency correctness
(the strict-executor check is disabled process-wide), app-layer test coverage (0 of 95 app files),
and single-user assumptions in shipping code (absolute /Users/<user> paths, unattended
`--dangerously-skip-permissions` launch).

## Ranked top 10 (highest leverage first)

1. **Make the archive write path fail loudly.** `SessionArchive.writeOwnerOnly`
   (SessionArchive.swift:656) is the single funnel for every session file and its whole error
   handling is `try? ... else return`. Full disk / read-only vault = the meeting record is lost
   with no log, no alert. Same for `writeMetadata` (:683) and the Sessions browser's user-initiated
   saves (SessionsBrowserView.swift:779, 837, 857). Nothing else on this list matters as much.
2. **Default `auto_process_yolo` to false** (SessionArchive.swift:609). It launches
   `claude --dangerously-skip-permissions` in the vault git root, unattended, on a prompt built
   from meeting audio (attacker-influenceable: anyone in the meeting can say words). Require
   explicit opt-in; cap at `--permission-mode acceptEdits`.
3. **Remove the two absolute `/Users/<user>` script paths**
   (TranscriptUpgradeService.swift:198, 220 — they even disagree on `Code` vs `code` casing, and
   one points into `archive/`). Resolve via config with the existing candidate-search pattern.
4. **Retire the `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE` escape hatch**
   (RTIApp.swift:19 + Info.plist). It suppresses one AppKit-teardown abort by disabling the
   check that would catch every real isolation bug — including item 5.
5. **Fix the three known-racy shared variables.** AudioPipeline.swift:116/119
   (`lastSystemBufferAt`, `systemSTTLinkArmed` — "tearing is benign" is untrue for
   `Optional<Date>`) and LLMRequest.swift:12 (`currentTask` — its `defer` can nil a newer
   request's handle, breaking single-flight cancel). Lock or actor each.
6. **Get the session lifecycle under test.** SessionCoordinator (828 LOC) and SessionArchive
   (1063 LOC) have zero tests; all 40 test files target RTICore only. Extract the state machine
   and archive rendering behind a filesystem protocol, then test phase transitions,
   checkpointing, and archive layout.
7. **Log levels + os.Logger.** RTILog (AppLog.swift:109) has no severity, freeform category
   strings ("audio" vs "system-audio", camel vs kebab), uses NSLog, and appends every audio-path
   trace to an @Observable array on the main actor. Add a level enum, a category enum, and stop
   observable-appending from the real-time path.
8. **Split the giant views; move file I/O off main.** OverlayTabs.swift (1579 LOC, six screens),
   SessionsBrowserView.swift (1318 LOC, ~20 synchronous filesystem ops inside SwiftUI
   body/actions on the main actor — beachballs on a slow vault), AssistantInputView.swift (1158).
9. **Real crash reporting.** CrashLog.swift catches only NSException — no Swift traps, no
   signals. Add signal handlers or a proper reporter; today most real crashes leave no trace.
10. **Consolidate settings/constants.** Half the settings keys live in NotificationNames.swift
    (misleading name); 16 kHz is independently declared in five places
    (CoreAudioTapCapture.swift:41, WAVWriter.swift:33+167, AudioCaptureManager.swift:16,
    SonioxClient.swift:473); three different binary-discovery helpers; the provably dead
    `Secrets._legacy*` pair.

## Other findings worth knowing

- **Process handling:** `runVaultRouter` (SessionArchive.swift:359) is `try? proc.run()` with no
  termination handler or output capture, while `runMeetingProcessor` (:428) does it right —
  inconsistent rigor between adjacent launchers. VoiceProfilesStore.swift:91 has the classic
  stdout-then-stderr pipe deadlock. VaultSearchCLI.swift:64 terminates on timeout without
  `waitUntilExit`, and its `warmUp` blocks a utility thread unboundedly.
- **Deinit deadlock risk:** CoreAudioTapCapture deinit → stop() → `processingQueue.sync`
  self-deadlocks if the last reference dies on that queue.
- **Timer leak:** MenuCoordinator.swift:51 `elapsedTimer` is never invalidated; fires 1 Hz
  forever even when idle.
- **Version truth:** Info.plist version vs release.sh stamping — two sources, unvalidated.
  CI runs on a self-hosted runner (this Mac), so the net is down when the Mac is.
- **Update path:** UpdateChecker opens a browser at a hardcoded personal repo; no signature
  verification, no Sparkle.
- **UI polish debt:** design tokens exist (RTIDesign.swift, with measured contrast) but ~100 raw
  color/padding literals bypass them; RTIDesign colors are light-mode literals while
  OverlayTheme handles dark separately — two theming systems that can drift. Accessibility: 37
  modifiers total, all in the overlay; SessionsBrowser, Settings, Onboarding have zero.
- **Genuinely strong areas** (keep the pattern): resource lifecycle (CoreAudio teardown order,
  notification-token cleanup, stale-WAV sweeping), restrained notification coupling, namespaced
  defaults keys, comment quality, zero print() calls, CI + notarized release scripts.

## Suggested sequencing

Wave 1 (correctness, ~a session each): items 1, 2, 3, 5.
Wave 2 (foundations): items 4, 7, and the small fixes above.
Wave 3 (structure, background-able): items 6, 8, 10.
Item 9 whenever a crash actually bites.
