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

This file also provides project-specific guidance to Claude Code (claude.ai/code) when working with this repository.

## Project identity

**Project name:** RTI (Real Time Intelligence). Use only this name in code, UI copy, bundle identifiers, and docs.

## Project focus — personal, real-time only

This is the **personal fork** of RTI: a single-user, real-time meeting copilot. It deliberately does **not** keep anything after a meeting ends. There is no database, no markdown corpus, no session history, no audio/video import, no cross-meeting search or Q&A, and no post-hoc analysis. If a feature isn't about helping *live, in the current conversation*, it doesn't belong here — the whole point of this fork was to strip that surface away.

> History note: an earlier build had all of the above (SQLite + markdown corpus, FTS5 + dense-embedding search, "Ask Your Corpus", projects, dossiers/notes/themes/discussion-guide analysis, drag-to-import, an `rti-mcp` JSON-RPC server, calendar integration). All of it was removed in the personal refocus. If you find a stray reference to any of it, it's a leftover — delete it, don't revive it.

Layout:

- `RTI/` — Xcode project. Generated via `xcodegen` from `RTI/project.yml`. Build with `xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build`. Runtime artifact at `~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app`. Bundle id `com.tristan.rti.personal`, macOS 14+, menubar-accessory app (`LSUIElement=YES`).
- `RTI/Sources/` — all Swift sources (overlay, audio, Soniox, LLM, screenshot, session, modes, panels, widgets, settings, UI).
- `RTI/Tests/` — XCTest unit tests.
- `RTI/POC*-findings.md` — historical per-POC validation logs. Reference for "why was this built this way?" — but note much of what they describe (persistence, corpus) is gone.
- `RTI/VERIFY.md` — manual verification steps for running builds.
- `docs/adr/` — architecture decision records (ADR 0001 is superseded — it describes the removed corpus).

## Architecture

Single-process macOS app. Coordination is distributed across `@Observable @MainActor` singletons (`SessionCoordinator`, `LLMController`, `WindowCoordinator`, `ModeStore`, etc.), wired together by `AppDelegate`. There is no single `AppState` class — each module owns its slice of state.

**Everything is ephemeral.** A "session" is just a run of live audio. The transcript (`SessionCoordinator.liveEntries`) and the chat (`LLMController.entries`) live in memory for the duration and are dropped when a new session starts. Nothing is written to a database or corpus. The WAV recording is streamed to a temp file while recording and **deleted** on stop. The only things on disk are config: API keys in `KeychainStore` and modes in `~/Library/Application Support/RTI/modes.json`.

**One deliberate exception — the session archive.** When a session ends, `SessionArchive.write` (called from `SessionCoordinator.completeStop`) saves a Markdown record of that session to `~/Library/Application Support/RTI/sessions/<yyyy-MM-dd HHmmss>/`: `transcript.md` (the live transcript with user notes inline — notes are `LiveEntry` rows with `speakerId == "note"`) and `chat.md` (the assistant chat log, only if non-empty). This is the *only* thing kept across sessions besides config. **Audio is still discarded** — only text is saved. There is no in-app reader or search for these files and there should not be one — it's a side record you open in Finder. (A convenience launcher is allowed and exists: the overlay's `⋯` menu has a "Recent sessions" submenu — `SessionArchive.recentSessions()` — that just *reveals the folders in Finder*. It opens Finder; it does not read or search content in-app.) This is not the old corpus coming back — do not build an in-app reader, search, indexing, or cross-session Q&A on top of it.

Three pipelines feed into the app:

1. **Audio pipeline** — `AVAudioEngine` tap → 16 kHz mono PCM → Soniox WebSocket (`wss://api.soniox.com/transcribe-websocket`) → interim + final transcript entries held in memory (`TranscriptPipeline` → `SessionCoordinator.liveEntries`). System-audio (the other party) is captured on a second Soniox leg via the `SystemAudioCapturing` protocol: a CoreAudio process tap (`CoreAudioTapCapture`, macOS 14.2+, preferred — no Screen Recording permission, doesn't disturb screenshot OCR, follows the default output device) with `ScreenCaptureKit` (`SystemAudioCapture`) as automatic fallback. `AudioPipeline` picks the backend at start. Apple Voice-Processing I/O (acoustic echo cancellation) is enabled on the mic input by default (`AudioCaptureManager`, toggle `AudioSettingsDefaults.echoCancellationKey`) so the other party's voice from the speakers doesn't double-transcribe.
2. **Screen pipeline** — on-demand `SCScreenshotManager` capture + Vision OCR. Screenshots are passed to the LLM then discarded (never persisted). OCR only.
3. **LLM pipeline** — provider-agnostic OpenAI-compatible streaming chat (default DeepSeek at `https://api.deepseek.com/v1`) via SSE. Provider config lives in `RTI/Sources/LLM/LLMProvider.swift` (`LLMProviders` registry); swap by changing `LLMProviders.activeId`. Prompt shapes: Assist, "What should I say?", Follow-up questions, Recap. Recent-transcript context for each turn is built from `SessionCoordinator.liveEntries` (last ~6 minutes), not from any stored transcript.

"Undetectability" = `NSWindow.sharingType = .none`. POC-1's `screencapture -x` test confirms exclusion against that capture path; QuickTime and Zoom are user-attested (see `RTI/POC1-findings.md`).

Global hotkeys use Carbon `RegisterEventHotKey` so they fire from any frontmost app. Registrations live in `RTI/Sources/UI/HotkeyCoordinator.swift` — that file is the source of truth, not the README table.

## Conventions

- **Secrets**: never commit API keys, never put them in `UserDefaults`, never `.env` files. Keys live in `KeychainStore` (backed by `~/Library/Application Support/RTI/credentials.json`, mode 0600).
- **Transcript semantics**: Soniox emits words with `is_final: false` (interim, update in place) and `is_final: true` (commit, appended to the in-memory `liveEntries`). Map `speaker: 0` → `"self"`, `1+` → `"them_1"`, `"them_2"`, etc.
- **Streaming responses**: The LLM SSE parser handles the `data: [DONE]` sentinel and concatenates `choices[].delta.content`. DeepSeek's `reasoning_content` field (gated by `LLMProviderConfig.supportsThinking`) is surfaced through a separate `onReasoning` callback.
- **Soniox reconnect policy**: exponential backoff 1s → 2s → 4s → 8s, max 5 retries, then surface error.
- **Swift/SwiftUI scope**: the overlay is a hand-rolled `NSPanel`, not a SwiftUI `WindowGroup`. SwiftUI is used inside the panel via `NSHostingView`.
- **Ephemeral by design**: don't reach for a database or on-disk store to "remember" something across sessions — that's explicitly out of scope. New state is in-memory unless it's user config (then JSON under Application Support, like `ModeStore`). The lone exception is the end-of-session Markdown archive (`SessionArchive`); it's write-only and must not grow into a corpus or a search surface.
- **Dependencies**: keep SPM deps minimal — only add when a feature needs it (current set: Starscream, Yams, MarkdownUI). GRDB was dropped in the personal refocus.

## Where to look for what

- **Overlay implementation (one tabbed master panel)** → `RTI/Sources/OverlayWindowController.swift` (the borderless `NSPanel`) + `RTI/Sources/OverlayPanelView.swift` (hosts the tab bar + an inline Record control + the Assist chat surface) + `RTI/Sources/UI/Overlay/OverlayTabs.swift` (the tabs — **Assist, Transcript, Notes, Context, Guide** — plus `OverlayRecordButton` and shared tab chrome). The overlay is the single surface for everything; toggle with ⌘\. The old free-floating record pill (`TopWidgetView`) and the separate Notes/Dossiers/Guide floating panels were folded into this in the 2026-06 overlay-tabs work — **don't reintroduce a floating record widget or per-feature floating panels.** Translation is the lone remaining `FloatingPanel` (`RTI/Sources/UI/FloatingPanel.swift` now has only `.translation`).
- **Hotkey registration** → `RTI/Sources/UI/HotkeyCoordinator.swift` (with `RTI/Sources/GlobalHotkey.swift` as the Carbon wrapper)
- **App entry / status item** → `RTI/Sources/RTIApp.swift` + `RTI/Sources/AppDelegate.swift`
- **Soniox wire shapes** → `RTI/Sources/Soniox/SonioxProtocol.swift`
- **LLM wire shapes** → `RTI/Sources/LLM/LLMWireShapes.swift`
- **Meeting detection** → there is none built into RTI. The old app-launch + camera auto-detect (`MeetingDetector`, `CameraActivityMonitor`) was removed in the 2026-05-27 streamline. The Sentinel banner's **"Go live"** button (below) is the only way a session starts from a detected meeting.
- **System audio capture (tap + SCK)** → `RTI/Sources/Audio/CoreAudioTapCapture.swift` (CoreAudio process tap, preferred) + `RTI/Sources/Audio/SystemAudioCapture.swift` (ScreenCaptureKit fallback); both conform to `SystemAudioCapturing`
- **Echo cancellation** → `RTI/Sources/Audio/AudioCaptureManager.swift` (`setVoiceProcessingEnabled` on the input node, before format read)
- **Live session lifecycle (start/stop, in-memory transcript)** → `RTI/Sources/Session/SessionCoordinator.swift` + `RTI/Sources/Session/TranscriptPipeline.swift`
- **End-of-session Markdown archive** → `RTI/Sources/Session/SessionArchive.swift` (invoked from `SessionCoordinator.completeStop`): writes `transcript.md` (notes inline), `chat.md`, `notes.md`, and `discussion-guide.md`, each only when non-empty. Also folds notes + chat + analysis into the linked-meeting `-rti.md` hand-off.
- **Meeting Sentinel bridge (RTI senses the external `meet start/stop` tool)** → `RTI/Sources/Session/MeetingSentinelMonitor.swift`. Sentinel (`~/.local/bin/meet` → `meeting-sentinel-repo/meet.py`) owns recording + the accurate post-meeting transcript and feeds the iCloud vault; RTI is a *follower* that polls Sentinel's `~/.config/meeting-sentinel/state.json` to know when a meeting is live. RTI keeps its own audio ephemeral (mic-only, low quality) — Sentinel is the keeper-of-record. Banner UI in `SessionsControlView` (`SentinelMeetingBanner`) carries a **"Go live"** button that starts RTI's live session linked to the meeting (`SessionCoordinator.startSession(linkedTo:)` sets `linkedMeeting`) and shows the overlay. Don't expand RTI into a recorder. **Step 3:** on stop, if linked, `SessionArchive.writeLinkedMeetingNotes` drops RTI's notes + chat (not the rough transcript) into the meeting's vault record as `transcripts-raw/<stem>-rti.md` (path derived from Sentinel's audio path, not hardcoded; only written if that dir already exists). The downstream fold is **done (2026-05-26)** on the vault side: the Mac `/meeting` skill (`.claude/skills/meeting/SKILL.md`) — which is what actually turns a Sentinel batch transcript into the polished `meetings/YYYYMMDD-slug.md` note — now checks for the sibling `-rti.md`, adds a `## Live notes (RTI)` section, and treats it as priority signal for decisions/actions. (It is a Mac-side skill change, not a VPS job; no Ava cron creates the polished note.) **Step 4 (pre-meeting brief):** RTI *reads* (never generates) the briefs Hermes' "Meeting Prep" job writes to the vault `<meetings>/briefs/` dir. (As of 2026-05-26 that job is fixed to actually write there — it previously targeted a non-existent path; the `briefs/` dir is now tracked in the vault so this store finds it even before the first brief lands.) `MeetingBriefStore` locates that dir via Sentinel's `recordings_dir` config (sibling `briefs/`, not hardcoded); `MeetingBriefView` + `MeetingBriefWindowController` render them with `RTIMarkdown`. Surfaced on demand via the "Pre-meeting Brief" command and a "Brief" button on the Sentinel banner. Empty state until Hermes writes the first brief there.
- **Real-time analysis (Notes + Discussion Guide)** → `RTI/Sources/Analysis/` + `RTI/Sources/Session/AnalysisScheduler.swift` + `RTI/Sources/Session/TranscriptContext.swift`. One `AnalysisScheduler` timer drives two `AnalysisController`s (`NotesGenerationController`, `DiscussionGuideController`), both built on the shared `TranscriptAnalysis` pipeline; each ticks an LLM pass over the live transcript (`SessionCoordinator.liveEntries` — there is **no** corpus/DB). Results live in memory and render in the overlay's **Notes** and **Guide** tabs (`OverlayTabs.swift`); the shared guide-rendering views (`ObjectiveSection` etc.) live in `RTI/Sources/Analysis/DiscussionGuideSections.swift`. Settings toggles + interval live in `GeneralTab` (`RealTimeAnalysisSection`, keys in `AnalysisSettingsDefaults`). Discussion Guide is import-driven (NSOpenPanel → parse) then match-on-tick. The **Dossiers** analyzer and **Themes** are gone — Dossiers was removed in the 2026-06 cleanup (it had been cut from the UI but was still running headless every tick); **don't revive either.** **Do not reintroduce persistence** — the only on-disk write is the end-of-session `SessionArchive` (`notes.md`/`discussion-guide.md`), which also folds these into the linked-meeting `-rti.md` vault hand-off.
- **Live chat / assist / recap** → `RTI/Sources/LLM/LLMController.swift`
- **Chat tools** → `RTI/Sources/LLM/LLMTools.swift` (`capture_screen` only — the `spawn_panel` counter-panel tool and the whole `Panels/` dir were removed in the 2026-05-27 streamline)
- **Screen capture + OCR** → `RTI/Sources/Screenshot/ScreenshotManager.swift` (ScreenCaptureKit capture) + `OCRService.swift` (on-device Apple Vision `VNRecognizeTextRequest`, `.accurate`). Vision OCR is covered by `RTI/Tests/OCRServiceTests.swift` (verified working 2026-05-27)
- **Prompt assembly** → `RTI/Sources/LLM/PromptBuilder.swift` (PromptContext + system message ordering; used by LLMController)
- **Modes (JSON-backed prompt presets)** → `RTI/Sources/Modes/ModeStore.swift` + `Mode.swift`
- **Command definitions** → `RTI/Sources/UI/CommandPalette/CommandPaletteFactory.swift` (CommandBuilder with section methods; consumed by palette, menu, hotkeys)
- **Live transcript / Settings / Logs window** → `RTI/Sources/UI/SessionsControl/SessionsControlView.swift`
- **Manual verification steps** → `RTI/VERIFY.md`
- **Regenerate the Xcode project after editing `project.yml`** → `cd RTI && xcodegen generate`
