# RTI — Production-Readiness Goal Prompt

> Paste this whole file as the kickoff prompt for a focused work session (or feed it to
> a planning agent). It is the contract. Work top-to-bottom; do not skip the verification
> step on any item. When everything in §"Definition of Done" is checked, RTI is
> beta-ready.

---

## Mission

Take RTI from a *working personal build* to a **bulletproof, private-beta-ready** real-time
meeting copilot. The bar is **trustworthy, not bigger**. A handful of friends will run this on
their own Macs during real meetings, so it has to fail gracefully, tell the truth about its
state, set itself up cleanly on a fresh machine, and never leak meeting content.

**"Awesome" here means:** I can hand someone a DMG, they open it, and within two minutes
they're live-transcribing a call with zero confusion — and it keeps working when the network
hiccups, AirPods drop, or a key is wrong, *and tells them what happened*.

This is the **personal, ephemeral, real-time-only** fork. Read `CLAUDE.md` before touching
anything. Hardening only — **no new product surface**.

---

## Rules of engagement (non-negotiable)

1. **Ephemeral-by-design is law.** No database, no history UI, no cross-session search, no
   corpus, no audio retention. The only disk writes remain: config (Keychain-style store +
   `modes.json`) and the write-only `SessionArchive` Markdown. If a change tempts you toward
   persistence, stop — you've misread the task. Do not revive any removed surface (the
   `CLAUDE.md` "History note" lists it; treat any stray reference as a leftover to delete,
   not revive).
2. **Surgical changes.** Every changed line traces to an item below. Don't refactor adjacent
   code, restyle, or "improve" things that aren't in scope. Match existing style.
3. **Simplicity first.** Minimum code that solves the item. No speculative abstractions, no
   config knobs nobody asked for, no error handling for impossible states.
4. **Verify by looking, not by faith.** "It compiled / returned 200 / the diff looks right"
   is **not** verification. For each item, do the literal `verify:` step and report the real
   result. If you can't observe it (no mic, no second device), say so explicitly — never
   claim success on faith.
5. **Stay green.** `xcodegen generate` + Debug build + the test suite must pass after every
   phase. Never land a phase red.
6. **Commit per item or small group**, with a message that names the item. Branch off `main`;
   open a PR per phase. End commit messages with the project's required Co-Authored-By line.

### Baseline (already verified — start here, confirm it still holds)
```bash
cd RTI && xcodegen generate
xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Debug build      # expect: ** BUILD SUCCEEDED **
xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Debug test       # expect: 63 tests, 0 failures
```
Runtime artifact: `~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app`

---

## Progress (updated 2026-06-07)

Merged to `main` (each its own CI-green PR):

- **Phase 0 — CI** ✅ (PR #3). Build+test+lint on `macos-15`/Xcode 26.x; red-gate proven.
- **Phase 1 — RTICore extraction** ✅ (PRs #4–#6). Pure-Swift `RTICore` static lib now holds
  the transcription/LLM/analysis value+logic types; app + tests link it; no `@MainActor` on
  core types. Seams extracted: TranscriptPipeline, ModeStorage, the LLM wire types +
  `PromptBuilder` + `LLMProviderConfig`/`LLMToolDefinition`, and the **SSE parser**. `CoreLog`
  logging seam added.
- **Phase 3 — tests for the seams** ✅ (PRs #6, #8, #12). 63 → **103 tests**: SSE parser (12),
  ModeStorage (7), TranscriptPipeline (6), PromptBuilder (6), SemanticVersion (9).
- **Phase 5 — security** ✅ (PR #7). No transcript content in logs; session files `0600`/dirs
  `0700`; stale-WAV sweep at launch.
- **Phase 2 — resilience** ✅ (PRs #11, #13). Mic dead-air watchdog (covers device-drop, mute,
  mid-session permission loss — 2.1/2.6), double-start guard (2.4), LLMRequest error visibility
  (2.3), connection-health state model (2.7), and system-audio non-fatal notice (2.2).
- **Phase 4 — onboarding/UX** ✅ (PRs #10, #13). Guided first-run window (keys + permissions,
  screenshot-verified) and the connection-health indicator in the Live Transcript header.
- **Phase 6 — distribution** ✅/⏳ (PR #12). GitHub-Releases auto-update + `SemanticVersion`;
  ad-hoc DMG packaging verified. **Signed/notarized DMG still needs your Apple Developer ID.**

**Deliberately deferred** (diminishing value / higher risk than the rest):

- Moving the *live networking classes* (`LLMClient`/`ToolLoop`/`LLMRequest`/`SonioxClient`)
  fully into RTICore. The bug-prone kernel (SSE parsing) is already extracted + tested; moving
  the network shells needs a mock-transport seam and refactors live code for limited extra
  value.
- A dedicated dismissible error banner in the **overlay** (4.3): the overlay already shows
  `lastError`, and the overlay is `sharingType = .none` so it can't be screenshot-verified.

**Remaining — needs a hands-on Mac (can't be verified headlessly):** see the
"Production-readiness checklist" in `RTI/VERIFY.md`. In short: signed/notarized DMG (your Apple
cert), and a real-meeting smoke test (both-sides transcription, watchdog no-false-positive,
overlay invisibility, archive-on-stop).

---

## Phase 0 — CI & guardrails (build the safety net first)

You cannot "loop until verified" without a harness. Do this before any code change.

- **0.1 — GitHub Actions CI.** Add `.github/workflows/ci.yml` that, on push + PR to `main`:
  installs `xcodegen` (Homebrew), runs `xcodegen generate`, builds Debug, and runs the test
  suite. Use a runner whose Xcode matches the local dev toolchain (currently Xcode 26.x on
  `macos-15`) so "CI green" faithfully mirrors local — an older Xcode (e.g. 16.2 on
  `macos-14`) diverges on Swift 6 strict-concurrency diagnostics. Cache SPM where sensible.
  - `verify:` push a branch, confirm the Action goes green in the GitHub UI (read the run log,
    don't assume). Confirm it goes **red** if you deliberately break a test, then fix it.
- **0.2 — Lint gate (lightweight).** Add `swiftformat --lint` (minimal config, default
  rules) as a CI step. The legacy tree follows none of SwiftFormat's conventions and the
  repo must **not** be mass-reformatted, so the gate lints **only newly-added files** — new
  code (notably the growing RTICore) stays clean for free, while touching a legacy file never
  forces a full reformat.
  - `verify:` CI shows the lint step; an intentional style violation in a new file fails it.
  - *Done (PR #3, refined in Phase 1):* started diff-scoped on all changed files, narrowed to
    added-only once the Phase 1 refactor showed that one-line touches were triggering huge
    reformats of files the change didn't otherwise alter.

---

## Phase 1 — RTICore extraction (unlock testability)

**Problem:** ~92% of the code is unreachable by tests because logic lives behind `@MainActor`
and the test bundle hand-picks ~12 source files (see `project.yml` `RTITests` target). Fix the
*structure* so the *logic* is testable, without spinning up a second `NSApplication`.

- **1.1 — Create a pure-Swift `RTICore` module/target** (no AppKit, no SwiftUI, no
  `@MainActor` on the core types). Move the *logic* (not the AppKit glue) of these into it,
  leaving thin `@MainActor` wrappers in the app:
  - `SonioxClient` transport/reconnect/parse logic (keep Starscream usage behind a small
    `WebSocketTransport` protocol so tests can inject a mock).
  - `LLMClient` + `ToolLoop` streaming/SSE/tool-call logic (inject `URLProtocol`-mock or a
    `StreamSource` seam so SSE can be replayed).
  - `TranscriptPipeline` merge/buffer/cap logic → a `nonisolated` model struct; keep the
    `@MainActor` publisher thin.
  - `ModeStore` load/save/active-id logic (inject a file location so tests use a temp dir).
  - `PromptBuilder` assembly/truncation/ordering.
  - The already-pure types (`TranscriptAggregator`, `SpeakerTurn`, `SonioxFailure`,
    `LLMError`, `JSONExtractor`, `DiscussionGuide`, `CommandRegistry`, `OCRService`) move in
    too, so the test bundle depends on **one** core target instead of a hand-picked file list.
  - `verify:` `project.yml` no longer enumerates individual `Sources/...` paths under
    `RTITests`; it depends on `RTICore`. Build + existing 63 tests still pass unchanged.
- **1.2 — Update `project.yml`** so `RTICore` is a dependency of both the app target and the
  test target. Regenerate, build, test.
  - `verify:` green build + green tests; `git grep` shows no `@MainActor` on the moved core
    types.

> This phase is plumbing — behavior must be **identical**. If any of the 63 tests change
> meaning, you've moved logic incorrectly. Keep going only when the suite is green.

---

## Phase 2 — Resilience hardening (the failure modes that bite in real meetings)

These are ordered by how badly they hurt a live call. File/line references are starting
points from an audit — confirm by reading before editing.

- **2.1 — [HIGH] Mic input-device-change detection.** Today `AudioCaptureManager` has **no**
  listener for the input device disappearing (AirPods/USB headset unplugged mid-session →
  the engine reads silence, Soniox transcribes nothing, **user never told**). System-audio
  *output* changes are already handled in `CoreAudioTapCapture` (~line 433) — mirror that
  pattern for input: detect the change, and either auto-switch to the system default or
  surface a clear "mic disconnected" state and stop cleanly.
  - `verify:` start a session on AirPods, disconnect them mid-session; confirm RTI either
    recovers on the default mic or shows an explicit error (not silent dead air). Observe it
    live — this is the headline reliability fix.
- **2.2 — [HIGH] Surface system-audio Soniox failures, not just auth.** In `AudioPipeline`
  (~line 109) only `failure.isAuth` is surfaced; transient/network failures on the
  *other-party* leg are logged and hidden, so the user silently loses the far side of the
  call. Surface non-auth system-audio failures too (informational, mic continues), distinct
  from a mic-leg failure.
  - `verify:` simulate a system-audio leg drop (kill network briefly / force the tap to
    fail); confirm a visible "system audio lost — capturing mic only" signal appears.
- **2.3 — [HIGH] Stop swallowing real errors in `LLMRequest`.** `withSingleFlight` (~line 36)
  uses `try?` which discards *all* errors, not just cancellation — a JSON-encode or unexpected
  error vanishes and looks like an empty reply. Catch `CancellationError` explicitly, log +
  handle unexpected errors, return cleanly.
  - `verify:` add a unit test (now possible via RTICore) that injects a throwing work closure
    and asserts the error is observed, not silently nil'd.
- **2.4 — [MED] Fix the permission-vs-stop race.** `SessionCoordinator.startSession` →
  `requestPermission` callback (~line 120) calls `launchSession()` even if the user pressed
  stop while the OS permission dialog was up. Re-check `isRunning == false` (i.e. not
  cancelled) inside the callback before launching.
  - `verify:` start, immediately stop while the mic prompt is showing, grant — confirm no
    session launches into a torn-down state.
- **2.5 — [MED] SSE decode gaps shouldn't vanish silently.** In `LLMClient` (~line 247) a
  malformed SSE chunk is logged and skipped; if it carried content, the user sees a gap with
  no signal. Decide a deliberate policy (surface a stream error, or emit a visible marker) and
  implement it — don't leave it silent.
  - `verify:` RTICore unit test feeds a malformed chunk mid-stream and asserts the chosen
    behavior (error surfaced / marker emitted), not a silent drop.
- **2.6 — [MED] Mid-session mic-permission revocation.** If the user revokes mic access in
  System Settings during a session, RTI keeps "recording" silence. Detect it (cheap check on
  audio-route/permission change is fine — don't poll hot) and surface + stop cleanly.
  - `verify:` revoke mic permission mid-session; confirm RTI notices and tells the user.
- **2.7 — [MED] Connection-health state model (logic only; UI lands in Phase 4).** Add a
  single source of truth for "is transcription actually flowing?" — e.g. a
  `TranscriptionHealth` enum (`connecting / live / reconnecting / failed`) driven by the
  Soniox client lifecycle (open, drop, backoff attempt, give-up). This is the data Phase 4's
  indicator binds to.
  - `verify:` RTICore unit test drives the client through connect → drop → reconnect → live
    and asserts the health transitions.

---

## Phase 3 — Test coverage (now that the core is reachable)

Target the highest-value, previously-untestable logic. Use the RTICore seams from Phase 1.

- **3.1 — `SonioxClient` reconnect/backoff/parse** — assert the `1→2→4→8→8` schedule, the
  `maxRetries` cap, `intentionalDisconnect` race handling, and message parsing (incl.
  malformed frames). Mock the `WebSocketTransport`.
- **3.2 — `LLMClient` + `ToolLoop` streaming** — replay recorded SSE: content deltas,
  `reasoning_content`, the `[DONE]` sentinel, mid-stream `{"error":...}`, the 4-iteration
  tool-loop cap, malformed `tool_calls`.
- **3.3 — `TranscriptPipeline` merge** — multi-channel (mic + system) ordering, interim→final
  replacement, the entry cap, note insertion (`speakerId == "note"`), timestamp alignment.
- **3.4 — `ModeStore` persistence** — temp-dir load/save round-trip, malformed JSON recovery,
  active-id survival across a builtin-prompt upgrade.
- **3.5 — `PromptBuilder` assembly** — reference-text truncation cap, glossary/screenshot
  context ordering stability, behavior with missing pieces.
- **3.6 — `DiscussionGuideController`** — guide import → match round-trip with a mocked LLM
  request; malformed guide JSON doesn't crash.
- `verify:` total test count climbs well past 63; `xcodebuild test` green locally **and** in
  CI. Each new test fails first when you break the code it covers (spot-check 2-3).

---

## Phase 4 — First-run, permissions & state legibility (the "feels like a product" phase)

Onboarding was deleted (commit `c54e5e6`); first launch currently cold-drops the user into
Settings. Rebuild a *minimal, honest* on-ramp — not a marketing wizard.

- **4.1 — Guided first-run.** On first launch with no keys: a small, focused setup panel that
  (a) explains in one line what RTI does, (b) takes the Soniox + LLM keys with helpful
  placeholders and a link to where to get each, (c) explains and triggers Microphone (and, on
  demand, Screen-Recording) permission *with the why*, (d) ends on "Ready — ⌘⇧R to start."
  Keep it ephemeral/config-only; don't add state beyond what's already stored.
  - `verify:` on a machine (or fresh user account) with no `credentials.json` and no
    permissions granted, launch the built app and walk the flow end-to-end. Actually click
    through it. Screenshot each step and read them.
- **4.2 — Proactive permission UX.** Don't let the user discover missing permissions only by
  failing. Show needed/granted state, with deep-links to the right System Settings pane (the
  existing NSAlert deep-link pattern in `ScreenshotManager` is the model). Block "Start" until
  mic is granted, with a clear reason.
  - `verify:` deny mic, try to start — confirm a clear, actionable prompt (not a silent
    no-op).
- **4.3 — Persistent, legible error surfacing.** LLM/Soniox errors currently appear as
  easy-to-miss text. Add a consistent, dismissible banner/toast on the overlay for failures
  (auto-clear on next success). A missing-key error must say *which* key and offer "Open
  Settings."
  - `verify:` with a deliberately bad LLM key, ask the assistant — confirm a clear banner
    naming the problem + a settings shortcut. With a bad Soniox key, start a session — same.
- **4.4 — Connection-health indicator (binds Phase 2.7).** Surface transcription health where
  the user already looks (live-transcript header + the recording pill): a calm "● live" when
  audio is flowing, "reconnecting…" on drop, "failed" on give-up. The user should *always*
  know whether words are actually being captured.
  - `verify:` start a session, kill wifi for ~10s, restore it — watch the indicator go
    live → reconnecting → live. Observe it; don't infer it.
- **4.5 — Polish sweep (small, high-ROI only).** Tighten empty-state copy ("Start a session
  with ⌘⇧R…"), make the Settings "missing keys" state visible on every tab (not just the Keys
  tab), add a "Show Sessions" Finder shortcut, warn on closing Settings with unsaved keys, and
  remove non-committal "planned" copy. Skip anything that smells like scope creep.
  - `verify:` click through each touched surface in the running app and read the copy.

---

## Phase 5 — Security hardening (private-beta bar)

Beta = other people's meetings on their machines. Close the leaks.

- **5.1 — Stop logging transcript content by default.** `SonioxClient` (~line 105) logs
  `recv <first 400 chars>` of every message — that's live meeting content in AppLog + NSLog,
  which violates the ephemeral promise. Log metadata only ("recv N tokens"), or gate verbose
  content logging behind an explicit debug flag that is **off** by default.
  - `verify:` run a session, open Settings → Logs, confirm no transcript words appear in the
    default log stream.
- **5.2 — Lock down session-archive files.** `SessionArchive` writes Markdown with default
  umask (world-readable on multi-user Macs). Write each file `0600` and the session dirs
  `0700` (reuse `KeychainStore`'s owner-only write pattern).
  - `verify:` finish a session, `ls -le ~/Library/Application\ Support/RTI/sessions/*/` and
    confirm `-rw-------` on files, `drwx------` on dirs.
- **5.3 — Log-copy hygiene.** The Logs view can copy the whole buffer. Ensure copied logs
  can't contain transcript content (follows from 5.1) and add a one-line caution if any
  session data could still appear.
  - `verify:` copy logs after a session, paste, confirm no meeting content.
- **5.4 — WAV-deletion audit.** Confirm the temp WAV is deleted on **every** stop path —
  normal stop, emergency shutdown (`applicationWillTerminate`), and start-failure. Add a
  belt-and-suspenders sweep of stale `RTI/sessions/*.wav` temp files on launch.
  - `verify:` force-quit mid-session, relaunch, confirm no orphaned WAV remains.

---

## Phase 6 — Distribution, auto-update & release

The release scaffolding (`RELEASE.md`, `scripts/release.sh`, entitlements, hardened runtime)
is already sound. Make a clean, updatable beta artifact.

- **6.1 — Cut a real signed+notarized DMG and actually validate it.** Run the documented
  release path. Don't trust exit codes — `spctl --assess`, `codesign --verify --deep
  --strict`, and **install from the DMG on a Mac that has never run RTI**, then complete the
  Phase 4 first-run on it.
  - `verify:` Gatekeeper accepts the notarized DMG without right-click-open; the app launches
    and onboarding works on the clean machine. Report the actual `spctl` output.
- **6.2 — Lightweight auto-update.** For a small beta, add Sparkle with a signed appcast over
  HTTPS (EdDSA key, public key pinned in-app), **or** a minimal "check for update" that points
  at the GitHub Releases latest tag and tells the user a newer DMG exists. Pick the simpler
  one that you can fully verify. Document the chosen mechanism in `RELEASE.md`.
  - `verify:` with a lower version installed, trigger the update check and confirm it detects
    the newer release (observe the real prompt/notice).
- **6.3 — Crash visibility.** Confirm `CrashLog` captures enough to debug a beta tester's
  report (no PII/keys/transcript) and that there's an easy way for a tester to grab it
  ("Show RTI Folder" / a copy button). Wire a friendly "RTI hit a problem" notice if a prior
  run left a crash log.
  - `verify:` force a crash in a debug build, relaunch, confirm the crash log exists, is
    `0600`, contains no secrets, and the user is told.

---

## Phase 7 — Final acceptance gauntlet (the "did you actually check?" pass)

No item here is done on faith. Run the real thing.

- **7.1 — Full `RTI/VERIFY.md` pass** on a Release build: overlay invisibility
  (`screencapture -x`, QuickTime, and a real Zoom/Meet share with a second device if
  available), hotkeys, clean quit (no zombie process).
- **7.2 — Real-meeting smoke test.** Join an actual call. Both sides transcribe. ⌘↵ assist is
  fast and useful. ⌘⇧H screenshot-OCR attaches. Notes/Dossiers/Discussion-Guide panels
  populate. Kill + restore wifi mid-call — health indicator reflects it, transcription
  recovers. Stop — confirm the Markdown archive is written, the WAV is gone, the mic is
  released (orange dot clears; another app can take the mic).
- **7.3 — Doc truth-up.** README, `RELEASE.md`, and `VERIFY.md` match the shipped behavior
  (hotkey table, first-run, auto-update, security notes). Update the memory note
  `rti-sentinel-integration` if any Sentinel-facing behavior changed.

---

## Definition of Done (the beta gate)

- [ ] CI green on `main`; red on a broken test (proven once).
- [ ] `RTICore` extracted; test bundle depends on it; behavior identical; suite green.
- [ ] All Phase 2 resilience items fixed and observed live (esp. mic-device-drop and
      connection-health).
- [ ] New tests cover Soniox reconnect, LLM/ToolLoop streaming, TranscriptPipeline merge,
      ModeStore, PromptBuilder, DiscussionGuide — count well above 63, green in CI.
- [ ] Fresh-machine first-run takes a non-technical friend from DMG to live transcription in
      <2 min, with permissions explained, **screenshot-verified**.
- [ ] Errors are always visible and actionable; the user can always tell if audio is flowing.
- [ ] No transcript content in logs by default; session files `0600`/dirs `0700`; WAV deleted
      on every path.
- [ ] Notarized DMG installs clean on a never-run Mac (real `spctl` output reported);
      auto-update mechanism verified.
- [ ] Full `VERIFY.md` + one real meeting passed; docs match reality.

---

## Explicitly OUT of scope (do not do these)

- Any persistence, history, search, corpus, Q&A-over-past-sessions, or session-browser UI.
- Audio retention of any kind.
- New "modes," new panels, new LLM features, plugin systems, multi-account/multi-tenant.
- Cross-platform (iOS/iPadOS), App Store sandboxing, public distribution.
- Reviving any feature listed in `CLAUDE.md`'s removed-surface "History note."
- Mass reformatting / opportunistic refactors outside the items above.

When in doubt: smaller, simpler, more observable. Ship trust, not features.
