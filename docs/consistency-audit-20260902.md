# RTI consistency audit — 2026-09-02

Goal: one way of doing each thing. Grep-driven, whole `RTI/Sources` (147 Swift
files) plus `RTI/Core` and the top-level contract files. Companion to
`docs/engineering-audit-20260901.md`, which ranks correctness and safety;
this one ranks "same mechanism, N implementations".

## Found

### Repo contract
- `AGENTS.md` is already a symlink to `CLAUDE.md`. No drift possible. Kept.
- `CLAUDE.md` described the overlay as a "borderless `NSPanel`" (lines 120,
  126) after commit 355b847 / c2b5572 (2026-09-01) made it a titled
  `NSWindow` Dock app. **Fixed.**
- `README.md` line 3 ("menubar-only", "translucent overlay") and line 12
  ("Borderless `NSPanel`") described the retired window. **Fixed.**
- `CHANGES.md` stopped at 2026-08-29; eleven commits (08-30 → 09-01)
  unlogged. **Backfilled** from `git log`.
- `PRODUCTION-GOAL.md` "Progress (updated 2026-06-07)" is three months
  stale; it is a roadmap, not a status file. **Left**, noted below.
- `RELEASE.md` "Released versions" lists narrative milestones, not tags;
  the last tag is `v0.1.0-beta9`. **Left**, noted below.
- `rti_feature_tracker.tsv` / `.xlsx` are tracked in git at the repo root.
  **Left** as instructed; they belong in `docs/` or out of git.

### Duplicated mechanisms (counts before this pass)
| Mechanism | Count | Locations | Verdict |
|---|---|---|---|
| Logging | 1 | `Support/AppLog.swift` (`AppLog` + `RTILog.log`); 0 `print`, 1 `NSLog` (inside AppLog) | Already unified. No severity levels (audit-0901 item 7). |
| Application Support/RTI resolver | 6 | `KeychainStore.swift:21`, `ModeStore.swift:79`, `CrashLog.swift:20`, `GeneralTab.swift:506,513`, `SessionArchive.swift:982` | **Fixed** → `AppSupportPaths`. |
| Vault git-root derivation (`databases` → up two) | 3 | `SessionArchive.swift:351` (router), `SpeakerEnrollment.swift:23`, `VaultSearchCLI.swift:120` | **Fixed** → `VaultPaths.gitRootDirectory` / `vaultToolURL`. |
| Binary discovery (candidate lists) | 3 + 2 literals | `claude` in `SessionArchive.swift:587`, `bun` in `VaultSearchCLI.swift:107`, python in `SpeakerEnrollment.swift:38`; literal `/usr/bin/python3` at `SessionArchive.swift:358` and twice in `TranscriptUpgradeService.swift` | **Fixed** → `ExternalTools`. |
| `Process()` sites | 7 | `VoiceProfilesStore:80`, `VaultSearchCLI:25,49`, `SpeakerEnrollment:14`, `SessionArchive:357,418`, `TranscriptUpgradeService:265` | 2 fire-and-forget copies collapsed into `ExternalTools.launchDetached`; the other 5 differ legitimately (pipes, timeout, log file, continuation). No `/bin/sh -c` anywhere. |
| Hardcoded `/Users/user` | 2 | `TranscriptUpgradeService.swift:213,235` (also audit-0901 item 3) | **Fixed** → config keys with home-relative defaults. |
| `UserDefaults` reads outside a settings object | 67 uses / 25 files | key constants are centralised in `NotificationNames.swift` (`OverlayAppearanceDefaults`, `AudioSettingsDefaults`, `TranslationDefaults`, `AnalysisSettingsDefaults`, `VisualContextSettingsDefaults`); ad-hoc `Self.xKey` strings remain in `LLMController` (8), `SonioxClient` (4), `AudioInputDevice` (4), `PromptStore` (4), `AnalysisScheduler` (4) | Left. Rename/move is a mechanical follow-up (below). |
| Keychain (`SecItem*`) | 0 | `KeychainStore` is a 0600 JSON file; name is historical and documented in-file | Left; consider renaming to `CredentialStore`. |
| HTTP clients | 2 | `LLMClient.swift` (SSE), `UpdateChecker.swift`; transcription providers are WebSocket (`SonioxClient`) and python scripts | Not duplicated. |
| `NotificationCenter` as control bus | 11 names, 14 posts, 0 ad-hoc strings | all in `Support/NotificationNames.swift` | Already unified. |
| `reset`/`clear` functions | 27 | four `AnalysisController`s each have `reset(for:)` + `clear()` on the shared protocol; the rest are per-store and distinct | Not duplicated; consistent by protocol. |
| Magic keyCodes | 1 | `AssistantInputView.swift:185` (36/76 Return) | Trivial; left. |
| 16 kHz literal | 5 | `CoreAudioTapCapture:41`, `WAVWriter:33,167`, `AudioCaptureManager:16`, `SonioxClient:473`, `SonioxProtocol:113` | Left (audit-0901 item 10). |

### Vault archive and `/meeting` hand-off
One funnel, three triggers. `SessionArchive` owns every write; the hand-off
is `runVaultRouter` (route-rti-session.py, detached) plus the canonical
export into `meetings/transcripts-raw/` followed by `runMeetingProcessor`
(headless `claude -p`). Triggers: `SessionCoordinator.completeStop` (normal
stop, via the upgrade pipeline's `runRouter` and `refreshCanonicalMeetingTranscript`),
`SessionCoordinator.archiveCurrentSession` (emergency shutdown), and
`TranscriptUpgradeService.upgrade` (manual re-upgrade). The empty-session
branch in `completeStop` exports and routes directly. This is one code path
with three entry points, not three implementations. The vault-side
`rti-meeting-drain` LaunchAgent is a second consumer of the same
`-transcript.txt` file, so a transcript can be processed twice (app-side
`claude -p` and drain); the drain skips already-processed files, so this is
belt-and-braces, not a bug, but it is worth writing down.

### Dead code
- `Secrets._legacy*` constants: read once on first launch for migration;
  provably empty in the checked-in file. Left (audit-0901 item 10).
- No unreferenced Swift files found by symbol grep of type names.

### Tests
`xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -destination
'platform=macOS' test` runs headless. Baseline on clean main: 275 passed,
1 skipped, 1 failed (`VaultFilesTests.testMentionCandidates_largePathSetStaysResponsive`,
a wall-clock `< 1 s` assertion that failed at exactly 1 s with the machine
under load from parallel agents). After this pass: 278 passed, 1 skipped,
0 failed, including that test.

## Fixed (this commit)
1. `Support/AppSupportPaths.swift` (new): single `~/Library/Application Support/RTI` resolver; six call sites switched.
2. `VaultPaths.gitRootDirectory` + `vaultToolURL`: three git-root derivations collapsed; unit test added.
3. `Support/ExternalTools.swift` (new): `claude()`, `bun()`, `stackPython()`, `systemPython`, `firstExecutable`, `launchDetached`; five sites switched. Added to the `RTITests` source list in `project.yml`; `xcodegen generate` re-run.
4. `TranscriptUpgradeService`: `soniox_file_script` / `aliyun_file_script` config keys, home-relative defaults; no `/Users/…` literal left in `RTI/Sources`.
5. Docs: README + CLAUDE.md window description; CLAUDE.md gains a "paths and binaries, one resolver each" convention; CHANGES.md backfilled 08-30 → 09-02.

Behaviour is identical on this Mac: same directories, same executables in
the same order, same detached launch semantics.

## Left, ranked
1. **Settings keys**: move the `Self.xKey` strings in `LLMController`,
   `SonioxClient`, `AudioInputDevice`, `PromptStore`, `AnalysisScheduler`
   into the `*Defaults` enums and rename `NotificationNames.swift` to
   `SettingsKeys.swift` + `NotificationNames.swift`. Mechanical, ~1 h.
2. **Log levels + category enum** on `RTILog` (audit-0901 item 7).
3. **16 kHz constant** in one `AudioFormat` enum in RTICore (5 sites).
4. **Rename `KeychainStore` → `CredentialStore`** to match what it is.
5. **`PRODUCTION-GOAL.md` progress block**: refresh or delete the
   2026-06-07 section; `RELEASE.md` should list tags.
6. **Feature tracker** `.tsv`/`.xlsx`: move under `docs/` or out of git.
7. **Double meeting processing** (app `claude -p` + vault drain): pick one
   owner; the drain is the safer one since it is not launched with
   `--dangerously-skip-permissions` from meeting audio (audit-0901 item 2).
