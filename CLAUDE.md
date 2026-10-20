# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions below.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

This file also provides project-specific guidance to coding agents (Claude Code, Codex — AGENTS.md symlinks here) when working with this repository.

## Release workflow

When making a change to RTI, verify it, commit the intended changes to `main`, and push `main`. For a change that should be used in the installed app, build from that committed revision and replace `/Applications/RTI.app` with that exact build.

**Run/install reality:** The maintainer launches the installed app at `/Applications/RTI.app`, not the DerivedData build product. When a change needs to be tested in the running Mac app, do not stop after `xcodebuild` — install via `scripts/install-local.sh` (stable signing identity, so TCC permission grants survive) and relaunch. Check binary timestamps for both paths when behavior still looks stale.

## Project identity

**Project name:** RTI (Real Time Intelligence). Use only this name in code, UI copy, bundle identifiers, and docs.

## Project focus — personal, real-time only

This is the **personal fork** of RTI: a single-user, real-time meeting copilot and the sole meeting recorder. **RTI captures and assists; it does not analyse (2026-10-17 trim).** House's job is to CAPTURE what happens, make it RECALLABLE, and ASSIST in the moment; synthesis, analysis, judging and deciding happen downstream in the `/meeting` skill and Pi. So RTI keeps capture (recording, live Soniox transcript, screenshots, the session store, archiving the raw session to the meetings folder, the automatic offline transcript upgrade) and live Notes, and the in-meeting copilot (overlay, modes, live answers, Auto cards, hotkeys). The live surface is primary; persistence is deliberately thin: each finished session archives to the sessions folder (Markdown + retained WAV legs), gets an automatic offline transcript upgrade, and is browsable in the in-app Sessions window. Cross-meeting search is a local keyword scan of the notes folder via the assistant's `search_vault` tool — RTI holds no database of its own. (The 2026-08-19 "minimal" strip that removed the tabs, slash commands, palette, and vault grounding was reverted wholesale on 2026-08-28 — that experiment is settled, don't re-strip the copilot.)

**Sole recorder (2026-08-28):** RTI owns meeting recording end to end — durable WAV legs, automatic transcript upgrade, and the hand-off to the `/meeting` skill. Meeting Sentinel was deleted; nothing external records meetings anymore.

> History note: an earlier build carried its own SQLite + markdown corpus, FTS5 + dense-embedding search, "Ask Your Corpus", dossiers/themes, drag-to-import, and an `rti-mcp` JSON-RPC server. Those stay dead — retrieval is the local keyword scan behind `search_vault`. The Sessions browser and the `search_vault` tool are CURRENT features. The discussion guide and intelligence ledger (Findings), the end-of-session summary and generated title, and the saved-meeting outputs (follow-up, decision log, debrief) were REMOVED on 2026-10-17 as analysis; they do not come back into RTI. Live Notes were restored the same day at the owner's request. Downstream analysis belongs to the vault `/meeting` skill and Pi.

Layout:

- `RTI/` — Xcode project. Generated via `xcodegen` from `RTI/project.yml`. Build with `xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build`. Runtime artifact at `~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app`. Bundle id `com.tristan.rti.personal`, macOS 14+, regular Dock app (`LSUIElement=NO` since 2026-09-01, so window managers and ⌘Tab see its window; menubar status item retained).
- `RTI/Sources/` — all Swift sources (overlay, audio, Soniox, LLM, screenshot, session, modes, panels, widgets, settings, UI).
- `RTI/Tests/` — XCTest unit tests. Run `scripts/scrub.sh` first (publish scrub; client and colleague names live in the untracked, gitignored `.scrub-private`; it must print `SCRUB_CLEAN`). Then test with `xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug -derivedDataPath .deriveddata test -only-testing:RTITests`; render proofs with `-only-testing:RTIRenderTests/<ProofClass>` (PNGs in `/tmp/rti-render-proof/`; proof classes subclass `RenderProofTestCase`, which points RTI at an invented fixture vault, never the real one).
- `RTI/POC*-findings.md` — historical per-POC validation logs. Reference for "why was this built this way?" — but note much of what they describe (persistence, corpus) is gone.
- `RTI/VERIFY.md` — manual verification steps for running builds.
- `docs/adr/` — architecture decision records (ADR 0001 is superseded — it describes the removed corpus).

## Architecture

Single-process macOS app. Coordination is distributed across `@Observable @MainActor` singletons (`SessionCoordinator`, `LLMController`, `WindowCoordinator`, `ModeStore`, etc.), wired together by `AppDelegate`. There is no single `AppState` class — each module owns its slice of state.

**Live transcript state and saved chat have distinct lifecycles.** The active
transcript (`SessionCoordinator.liveEntries`) stays session-scoped. The
2026-09-17 approved chat contract retains each submitted conversation and its
attachments for later follow-up: structured threads belong to the existing
vault RTI owner under `chats/threads/`; immutable attachment and credential-free
request blobs belong to local `Application Support/RTI/chat-assets/`. This is
an explicit exception to the old session-only attachment rule, not permission
for an RTI database, semantic index or expanded capture. `/new` clears the
active chat and pending context but does not erase its saved thread or stop
recording. Retain saved chat content until explicit deletion; no automatic
pruning. Daily logs and meeting chat exports are compatibility projections
linked to the owning structured threads, not independent histories.

The durable per-leg recordings (`MeetingRecorder`) are the only audio copy
and remain in the session archive (the old temp mic WAV is gone). Do not duplicate those audio
or frame owners in the chat asset store. Config on disk: API keys in
`CredentialStore`, modes in `~/Library/Application Support/RTI/modes.json`.

**One deliberate exception — the session archive.** When a session ends, `SessionArchive.write` (called from `SessionCoordinator.completeStop`) saves a Markdown record of that session at `<sessions_dir>/<yyyy-MM-dd HHmmss>/` (`sessions_dir` in RTI's config, `~/.config/rti/config.json`; default `~/Documents/Work/Inner-Chapter/meetings/sessions`): `transcript.md` (the live transcript with user notes inline — notes are `LiveEntry` rows with `speakerId == "note"`) and `chat.md` (the assistant chat log, only if non-empty). Alongside it, `VaultLogStore` appends one JSONL line per assistant turn to `…/rti/turns/<yyyy-MM-dd>.jsonl` (prompt metadata + output; session **or** standalone chats). These text records — plus config — are what's kept across sessions. **Audio is kept**: `audio-mic.wav` / `audio-system.wav` land in the archive folder and feed the automatic transcript upgrade. The Sessions browser (`SessionsControlView`) lists and renders archived sessions in-app. What must NOT come back is RTI-side indexing: no embedded DB, no in-app full-text/semantic index — retrieval is the keyword scan behind `search_vault`.

Three pipelines feed into the app:

1. **Audio pipeline** — `AVAudioEngine` tap → 16 kHz mono PCM → Soniox WebSocket (`wss://stt-rt.soniox.com/transcribe-websocket`, hosted: live transcription leaves the Mac) → interim + final transcript entries held in memory (`TranscriptPipeline` → `SessionCoordinator.liveEntries`). System-audio (the other party) is captured on a second Soniox leg via the `SystemAudioCapturing` protocol: a CoreAudio process tap (`CoreAudioTapCapture`, macOS 14.2+, preferred — no Screen Recording permission, doesn't disturb screenshot OCR, follows the default output device) with `ScreenCaptureKit` (`SystemAudioCapture`) as automatic fallback. `AudioPipeline` picks the backend at start. Apple Voice-Processing I/O (acoustic echo cancellation) is an opt-in toggle (`AudioCaptureManager`, `AudioSettingsDefaults.echoCancellationKey`) — it cancels the other party's speaker bleed so it isn't double-transcribed. **Default OFF (2026-06-09):** on some Macs VPIO, enabled on an input node we only *tap* (no running output graph), delivers silent buffers and kills transcription entirely. Leave it off until VPIO is wired with a live output; the system-audio tap already captures the other party separately.
2. **Screen pipeline** — explicit `SCScreenshotManager` capture + on-device Vision OCR. A manual screenshot can be sent as image content directly to the chat's effective vision-capable provider, including cloud DeepSeek. It does not require an extra local-vision description first. Show that destination before Send and retain the submitted screenshot with its chat, per the approved 2026-09-17 retention contract. During a recording, session-scoped frame archival and ambient OCR remain separately governed by their existing controls. The optional local-models description lane runs only when ambient description is enabled; an enabled `local_vision` block alone does not mean every image stays on this Mac. **Screen privacy (2026-08-30):** deny-listed windows (`ScreenPrivacy.swift`, editable in Settings → General) remain excluded at the shared `SCContentFilter` so their pixels never enter the captured image. Chat retention must not widen those capture permissions.
3. **LLM pipeline** — provider-agnostic OpenAI-compatible streaming chat (default DeepSeek at `https://api.deepseek.com/v1`) via SSE. Provider config lives in `RTI/Sources/LLM/LLMProvider.swift` (`LLMProviders` registry); swap by changing `LLMProviders.activeId`. Prompt shapes: Assist, "What should I say?", Follow-up questions, Recap. Recent-transcript context for each turn is built from `SessionCoordinator.liveEntries` (last ~6 minutes), not from any stored transcript.

"Undetectability" = `NSWindow.sharingType = .none`. POC-1's `screencapture -x` test confirms exclusion against that capture path; QuickTime and Zoom are user-attested (see `RTI/POC1-findings.md`).

Global hotkeys use Carbon `RegisterEventHotKey` so they fire from any frontmost app. Registrations live in `RTI/Sources/UI/HotkeyCoordinator.swift` — that file is the source of truth, not the README table.

## Conventions

- **Secrets**: never commit API keys, never put them in `UserDefaults`, never `.env` files. Keys live in `CredentialStore` (backed by `~/Library/Application Support/RTI/credentials.json`, mode 0600).
- **Paths and binaries, one resolver each**: local config files go through `AppSupportPaths` (`~/Library/Application Support/RTI`); everything in the notes folder goes through `VaultPaths` (`~/.config/rti/config.json` anchors it; `sessions_dir` places the session archives); external executables (`claude`, python) go through `ExternalTools`. Never hardcode `/Users/...`, never `FileManager.urls(for: .applicationSupportDirectory)` at a call site, never a bare `Process()` with a literal executable path outside those helpers.
- **Transcript semantics**: Soniox emits words with `is_final: false` (interim, update in place) and `is_final: true` (commit, appended to the in-memory `liveEntries`). `SpeakerLabelMapping.rawLabel(speaker:channel:)` is the one mapping: mic leg speaker 0 or 1 → `"self"`, 2+ → `"room_N"`; system leg → `"remote_N"` (speaker 0 folds into `remote_1`). The live view shows `You`, `Room speaker N`, `Speaker N`, and a live name always wins. The channel-less `rawLabel(speaker:)` (file mode) still maps 0 → `"self"`, 1+ → `"them_N"`.
- **Streaming responses**: The LLM SSE parser handles the `data: [DONE]` sentinel and concatenates `choices[].delta.content`. DeepSeek's `reasoning_content` field (gated by `LLMProviderConfig.supportsThinking`) is surfaced through a separate `onReasoning` callback.
- **Soniox reconnect policy**: exponential backoff 1s → 2s → 4s → 8s, max 5 retries, then surface error. Every socket is a new stream whose word timestamps restart at 0 (a reconnect, the system leg rejoining after a park, a client swap); `AudioPipeline.onStreamRestarted` re-bases that leg on the session timeline via `TranscriptPipeline.restartStream`. `SonioxClient` acts only on the current socket's lifecycle events.
- **Swift/SwiftUI scope**: the overlay is a hand-rolled titled `NSWindow` (`OverlayWindowController`; a normal Dock-app window since 2026-09-01, no float, no translucency), not a SwiftUI `WindowGroup`. SwiftUI is used inside the window via `NSHostingView`.
- **No RTI database or index**: durable chat threads and meeting records stay with the existing vault owner under `…/databases/projects/personal/rti/`. The approved local `chat-assets/` exception retains submitted attachment bytes and request snapshots, not a second conversation registry. Keep assets owner-only, out of Git and automatic vault ingestion, and eligible for ordinary local backups. Do not configure a new cloud sync. Structured threads reference assets and existing meeting artifacts; deletion must respect references and never remove original user documents or linked recordings. The `/meeting` skill owns meeting processing.
- **Shared chat implementation**: consume house-chat-core at the macOS 14 floor. It is its own repo (extracted from quick-launch 2026-10-16, one package, two consumers), pinned by GitHub URL and tag in `RTI/project.yml`, so a fresh clone builds with no sibling folder; the design tokens come from the design-system package the same way. To take a change, raise the `from:` pin, regenerate with xcodegen and commit the resolved file. Share command/context/schema/extraction interfaces, not app defaults or histories. The approved implementation contract is `../quick-launch/docs/chat-harmonization-plan-20260917.md`; a combined history remains future exploration.
- **Dependencies**: keep SPM deps minimal — only add when a feature needs it (current set: Starscream, Yams, MarkdownUI). GRDB was dropped in the personal refocus.

## Where to look for what

- **Overlay implementation (one tabbed master panel)** → `RTI/Sources/OverlayWindowController.swift` (the titled `NSWindow`, `sharingType = .none`) + `RTI/Sources/OverlayPanelView.swift` (hosts the tab bar + an inline Record control + the Assist chat surface) + `RTI/Sources/UI/Overlay/OverlayTabs.swift` (the tabs — **Prepare (`setup`), Assist, Auto, Transcript, Notes** (`OverlayTab`, ⌘1…⌘5; Auto is opt-in, Notes defaults on) — plus `OverlayRecordButton` and shared tab chrome). The overlay is the single surface for everything; toggle with ⌘\. The old free-floating record pill (`TopWidgetView`) and separate feature panels were folded into this surface — **don't reintroduce a floating record widget or per-feature floating panels** (the floating RecordingHUD was likewise deleted 2026-08-28; the menubar timer is the one recording indicator). Translation renders inline in the Transcript tab.
- **Hotkey registration** → `RTI/Sources/UI/HotkeyCoordinator.swift` (with `RTI/Sources/GlobalHotkey.swift` as the Carbon wrapper)
- **App entry / status item** → `RTI/Sources/RTIApp.swift` + `RTI/Sources/AppDelegate.swift`
- **Soniox wire shapes** → `RTI/Sources/Soniox/SonioxProtocol.swift`
- **LLM wire shapes** → `RTI/Sources/LLM/LLMWireShapes.swift`
- **Meeting detection** → there is none built into RTI. The old app-launch + camera auto-detect (`MeetingDetector`, `CameraActivityMonitor`) was removed in the 2026-05-27 streamline. Sessions start explicitly with ⌘⇧R.
- **System audio capture (tap + SCK)** → `RTI/Sources/Audio/CoreAudioTapCapture.swift` (CoreAudio process tap, preferred) + `RTI/Sources/Audio/SystemAudioCapture.swift` (ScreenCaptureKit fallback); both conform to `SystemAudioCapturing`
- **Echo cancellation** → `RTI/Sources/Audio/AudioCaptureManager.swift` (`setVoiceProcessingEnabled` on the input node, before format read)
- **Live session lifecycle (start/stop, in-memory transcript)** → `RTI/Sources/Session/SessionCoordinator.swift` + `RTI/Sources/Session/TranscriptPipeline.swift`
- **End-of-session Markdown archive** → `RTI/Sources/Session/SessionArchive.swift` (invoked from `SessionCoordinator.completeStop`): writes `transcript.md` (notes inline), `chat.md`, `notes.md` (generated live notes), and `screen-context.md`, each only when non-empty, into `<sessions_dir>/<stamp>/`. Also exports the canonical `-transcript.txt` + `-rti.md` sidecar into `meetings/transcripts-raw/`. The `⋯` "Recent sessions" launcher (`SessionArchive.recentSessions`) lists these and reveals them in Finder.
- **Per-turn vault log** → `RTI/Sources/Session/VaultLogStore.swift`: appends one JSONL line per completed assistant turn to `…/databases/projects/personal/rti/turns/<yyyy-MM-dd>.jsonl` (prompt metadata + output; captures standalone chats too). Written off-thread from `LLMController.logCompletedTurn`; drops a self-documenting `README.md` in `rti/` on first use. Text only — no DB, no in-app reader/search.
- **Meeting Sentinel** → DELETED 2026-08-28. RTI is the sole meeting recorder; `VaultPaths.swift` (config `~/.config/rti/config.json`, override `RTI_CONFIG_HOME`) is the single path authority. The monitor/coordinator/command-builder, the linked-meeting flow, and the `meet` CLI are gone — do not revive them. Legacy `.meeting.json` sidecars in the vault's recordings dir still render in the Sessions browser as recorded meetings. The pre-meeting briefs dir is still read via `MeetingBriefStore` (sibling `briefs/` of `recordings_dir`).
- **Live Notes** → `RTI/Sources/Notes/` (`NotesGenerationController`, `GeneratedNote`) + `RTI/Sources/Session/TranscriptContext.swift`. The shared `AutoAssistScheduler` timer (interval from `NotesSettings.intervalKey`, 1 to 10 min, default 2) fires one LLM pass over the transcript since the controller's own watermark; the manual "Write notes now" button shares that watermark. Each pass appends a titled bullet block (prompt `PromptID.liveNotes`, editable in Settings > Prompts) to the overlay's **Notes** tab. Toggle `NotesSettings.enabledKey` (default on) in Prepare and Settings > General. Notes live in memory; `SessionArchive` writes them to `notes.md` and the `-rti.md` sidecar at stop. Notes feed no summary or title.
- **Auto mode (copilot cards)** → `RTI/Sources/Auto/` (`AutoAssistController`, `AutoAssistCard`, `AutoAssistScheduler`) + `RTI/Sources/Session/TranscriptContext.swift`. A debounced trigger plus a scheduler tick runs an LLM pass over the recent live transcript window (`SessionCoordinator.liveEntries`, no corpus/DB) and surfaces say/ask/recall/flag cards in the overlay's **Auto** tab. Opt-in via `AutoAssistSettings.enabledKey`. Results live in memory only. **The Discussion Guide, Findings (intelligence ledger), the end-of-session summary and generated title, and the saved-meeting outputs were removed 2026-10-17 (analysis belongs downstream); don't revive them. Live Notes are the one analysis feature kept.**
- **Live chat / assist / recap** → `RTI/Sources/LLM/LLMController.swift`
- **Chat tools** → `RTI/Sources/LLM/LLMTools.swift`: `capture_screen`, `highlight_screen_text`, `search_vault` (local keyword scan), `recent_meetings`, `read_document`, `grep_vault`, `list_files` — the agentic file/retrieval toolkit runs through `ToolExecutor`/`ToolLoop` (the `spawn_panel` counter-panel tool and the `Panels/` dir stay removed)
- **Screen capture + OCR** → `RTI/Sources/Screenshot/ScreenshotManager.swift` (ScreenCaptureKit capture) + `OCRService.swift` (on-device Apple Vision `VNRecognizeTextRequest`, `.accurate`). Vision OCR is covered by `RTI/Tests/OCRServiceTests.swift` (verified working 2026-05-27)
- **Prompt assembly** → `RTI/Sources/LLM/PromptBuilder.swift` (PromptContext + system message ordering; used by LLMController)
- **Modes (JSON-backed prompt presets)** → `RTI/Sources/Modes/ModeStore.swift` + `Mode.swift`
- **Command definitions** → `RTI/Sources/UI/CommandPalette/CommandPaletteFactory.swift` (CommandBuilder with section methods; consumed by palette, menu, hotkeys)
- **Live transcript / Settings / Logs window** → `RTI/Sources/UI/SessionsControl/SessionsControlView.swift`
- **Manual verification steps** → `RTI/VERIFY.md`
- **Regenerate the Xcode project after editing `project.yml`** → `cd RTI && xcodegen generate`
