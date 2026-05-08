# Module Map — RTI

## App Core
- **RTIApp.swift** — `@main` SwiftUI `App` entry, delegates to `AppDelegate`.
- **AppDelegate.swift** — Application lifecycle orchestrator. Wires `WindowCoordinator`, `MenuCoordinator`, `HotkeyCoordinator`, `SessionCoordinator`, `LLMController`, `ModeStore`, `CorpusManager`. Single-instance enforcement. `applicationShouldTerminate` guard.
- **GlobalHotkey.swift** — Carbon `RegisterEventHotKey` wrapper with `EventHotKeyID` dispatch.
- **Secrets.swift** — API key facade over `CredentialStore` (file-backed, not Keychain).
- **OverlayWindowController.swift** — Borderless `NSPanel` with `sharingType=.none`, frame persistence, fade animations, multi-screen positioning.
- **OverlayPanelView.swift** — SwiftUI content of the overlay panel: `ResponseView` + `PromptActionRow` + `AssistantInputView`.

## Audio (5 files)
- **AudioPipeline.swift** — Owns `AudioCaptureManager` + `SystemAudioCapture` + `WAVWriter` + dual `SonioxClient`. Dual-channel (mic + system) capture coordinator.
- **AudioCaptureManager.swift** — `AVAudioEngine` tap, 16kHz mono PCM buffer output.
- **SystemAudioCapture.swift** — `ScreenCaptureKit` system audio loopback.
- **AudioInputDevice.swift** — Mic permission request wrapper.
- **WAVWriter.swift** — WAV file writer with proper header finalization.

## Soniox (4 files)
- **SonioxClient.swift** — Starscream WebSocket delegate with exponential backoff retry (1s→8s, max 5). Config send, word dispatch, error classification via `SonioxFailure`.
- **SonioxProtocol.swift** — Data types: `SonioxWord`, `SonioxConfigMessage`, `SonioxTranscriptMessage`, `RawToken`.
- **SonioxFileTranscribeClient.swift** — File-based transcription (offline/non-streaming).
- **SonioxFailure.swift** — Typed error enum: `.auth`, `.clientBug`, `.transient`, `.unknown` with `shouldRetry`, `isAuth`, `userMessage(didOpen:)`.

## LLM (5 files)
- **DeepSeekClient.swift** — SSE streaming `AsyncThrowingStream<String, Error>` over `URLSession.bytes`. Timeout race via `TaskGroup`. Reasoning/content delta dispatch. Used by LLMController, SummaryController, SessionTitleController, SessionQAController.
- **DeepSeekProtocol.swift** — Request/response/chunk types for DeepSeek API.
- **DeepSeekError.swift** — Typed error enum: `.missingAPIKey`, `.unauthorized`, `.httpError`, `.badResponse`, `.streamError`.
- **LLMController.swift** — `@MainActor @ObservableObject`. Chat entry list, streaming state, smart mode toggle. Four prompt actions (Assist, Say Something, Follow-ups, Recap). Transcript context injection (6-min window). Mode system prompt + reference text attachment. Screen context attachment.
- **LLMRequest.swift** — Thin wrapper around `DeepSeekClient`, providing cancellation and callback-based stream API.

## Session (11 files)
- **SessionCoordinator.swift** — Central session lifecycle: start/stop, bootstrap, resume, delete, prune, emergency shutdown. Owns `AudioPipeline` + `TranscriptPipeline`. Dual-channel word routing. JSONL live-write via `CorpusManager`. Session-end markdown render trigger.
- **TranscriptPipeline.swift** — Per-channel live transcript aggregation. Owns two `TranscriptAggregator` instances (mic/system) + note entries. Produces `liveEntries` + `interimLine`. JSONL write on turn collapse.
- **TranscriptAggregator.swift** — Per-channel `SonioxWord` dedup (lastEndMs watermark, ZeroMs dedup), interim text tracking, `SpeakerTurn.collapse` invocation.
- **SpeakerTurn.swift** — `SonioxWord` → SpeakerTurn collapse logic. Groups contiguous words by speaker, computes mean confidence.
- **TranscriptContext.swift** — LLM-facing transcript rendering: raw speaker IDs (`self`, `them_1`, `note`), note tagging (`[user note]:`), time windowing via `sinceMs`.
- **TranscriptRegenerator.swift** — Markdown body → `TranscriptEntry` list reconstruction (reads `## Transcript` section).
- **SessionQAController.swift** — Follow-up question generation via LLM.
- **SessionTitleController.swift** — LLM-driven session title generation with in-memory cache.
- **SessionSearch.swift** — Full-text search across session transcripts/summaries via FTS5.
- **ActiveSessionProjection.swift** — Projection layer for active session state.
- **SessionExport.swift** — Session export functionality.

## Database (2 files + Models/)
- **RTIDatabase.swift** — GRDB `DatabasePool` singleton at `~/Library/Application Support/RTI/rti.db`. 11-version migration chain: v1 (sessions, transcript_entries), v2 (chat_messages, modes), v3 (mode reference_text), v4 (session_summaries), v5 (mode_id + calendar), v6 (session title), v7 (FTS5 search), v8 (transcript_quality), v9 (speaker_overlays), v10 (corpus_migration_log), v11 (drop legacy tables, chat_messages FK recreation).
- **Models/Session.swift** — In-memory `Session` value type (not GRDB-backed post-v11).
- **Models/ChatMessage.swift** — GRDB `PersistableRecord` for chat_messages.
- **Models/TranscriptEntry.swift** — In-memory `TranscriptEntry` (not GRDB-backed post-v11).
- **Models/Mode.swift** — GRDB `PersistableRecord` for modes.
- **Models/SessionSummary.swift** — GRDB-backed (pre-v11) / in-memory session summary.

## Corpus (11 files)
- **CorpusEntry.swift** — Frontmatter YAML codec (Yams-based), `render()` and `parse()`. `SpeakerMapEntry` type.
- **CorpusManager.swift** — `@MainActor` coordinator: owns corpus directory (`~/meetings/`), per-session `LiveJSONLWriter`, session-end `renderSession` (JSONL→markdown), crash recovery (`recoverOrphans`).
- **CorpusReader.swift** — Directory walker (`listMarkdownFiles`), file parser (`read`, `readFrontmatter`).
- **CorpusWriter.swift** — Atomic markdown write (`.tmp` then rename), slug generation, collision-safe unique URL.
- **CorpusBackedStore.swift** — Reads markdown corpus into in-memory `Session` and `TranscriptEntry` lists.
- **CorpusCatalog.swift** — Corpus file listing/indexing.
- **MarkdownRenderer.swift** — Pure function: `(JSONL events + metadata) → CorpusEntry`. Transcript formatting, speaker label resolution.
- **LiveJSONLWriter.swift** — Append-only JSONL stream writer with fsync.
- **TranscriptRender.swift** — Transcript markdown section rendering.
- **SpeakerOverlay.swift** — GRDB-backed cross-session speaker name corrections.
- **CorpusFTSReindexer.swift** — Walks `~/meetings/`, populates FTS5 `session_search` table.

## MCP (3 files)
- **RTIMCPMain.swift** — `@main` stdio JSON-RPC 2.0 dispatch loop. Four tools: `search_corpus`, `read_meeting`, `list_meetings`, `read_live_transcript`. CLI args: `--corpus`, `--live`, `--db`.
- **MCPProtocol.swift** — JSON-RPC types (`InitializeRequest`, `InitializeResult`, `ToolListing`, `ToolCallResult`) plus `AnyCodable`.
- **MCPTools.swift** — Tool implementations: FTS5 search, markdown file reading, directory listing, live JSONL reading.

## Screenshot (2 files)
- **ScreenshotManager.swift** — `SCScreenshotManager.captureImage` on display under mouse. Vision OCR. OCR text truncation (12k chars). TCC denial prompting.
- **OCRService.swift** — Vision framework `VNRecognizeTextRequest` wrapper.

## Modes (1 file)
- **ModeStore.swift** — `@MainActor @ObservableObject`. Four builtin modes (Meeting, Interview, Coding, Custom). Seed on first launch. Active mode persistence.

## Summary (1 file)
- **SummaryController.swift** — LLM-driven meeting summary generation with structured parsing (`## Summary`, `## Key Topics`, `## Decisions Made`, `## Action Items`, `## Open Questions`, `## Next Steps`). In-memory cache, consumed by `CorpusManager.renderSession`.

## Calendar (1 file)
- **CalendarManager.swift** — Calendar event association for sessions.

## Widgets (5 files)
- **TopWidgetView.swift / TopWidgetWindowController.swift** — Top-center widget: session status, duration, controls.
- **MiniWidgetView.swift / MiniWidgetWindowController.swift** — Collapsed compass mini widget.
- **ShortcutsWindowController.swift** — Keyboard shortcuts reference window.

## Settings (6 files)
- **SettingsView.swift** — Tabbed settings (General, Keys, Modes, Overlay Appearance, Command Palette, Corpus).
- **SettingsWindowController.swift** — Settings NSPanel host.
- **KeychainStore.swift** — File-backed credential storage at `~/Library/Application Support/RTI/credentials.json` (mode 0600). Named "KeychainStore" historically but not using macOS Keychain.
- **OnboardingWindowController.swift** — First-launch onboarding flow.
- **LogsWindowController.swift** — Application log viewer.
- **LaunchAtLogin.swift** — `SMAppService.mainApp` integration.

## Support (6 files)
- **AppLog.swift** — `RTILog` logging utility.
- **CrashLog.swift** — Crash log file rotation at `~/Library/Application Support/RTI/crash.log`.
- **NotificationNames.swift** — Centralized `Notification.Name` constants.
- **SpeakerLabelMapping.swift** — `speaker: Int + channel → "self"/"them_N"` mapping.
- **TimeFormat.swift** — Time formatting utilities.
- **SummaryFormatting.swift** — Summary section text formatting.

## UI (12 files)
- **UI/Overlay/** — `AssistantInputView`, `OverlayInputState`, `PromptActionRow`, `ResponseView`.
- **UI/DebugConsole/** — `DebugConsoleView`, `DebugConsoleWindowController`, `TranscriptRowView`.
- **UI/CommandPalette/** — `CommandRegistry`, `CommandPaletteView`, `CommandPaletteWindowController`, `CommandPaletteFactory`.
- **UI/SessionHistory/** — `SessionHistoryView`, `SessionHistoryWindowController`.
- **UI/SessionDetail/** — `SessionDetailView`, `SessionDetailComponents`.
- **UI/WindowCoordinator.swift** — Central window state machine.
- **UI/MenuCoordinator.swift** — Menubar menu builder.
- **UI/HotkeyCoordinator.swift** — Hotkey registration dispatch.
- **UI/SpeakerLabels.swift** — Speaker label UI utilities.
- **UI/RTIDesign.swift** — Design constants/tokens.

## Tests (11 files)
- `DeepSeekErrorTests.swift`
- `SonioxFailureTests.swift`
- `CorpusFTSReindexerTests.swift`
- `CorpusWriterTests.swift`
- `MCPSpawnIntegrationTests.swift`
- `WritePathIntegrationTests.swift`
- `CommandRegistryTests.swift`
- `CorpusEntryTests.swift`
- `MarkdownRendererTests.swift`
- `SpeakerTurnTests.swift`
- `LiveJSONLWriterTests.swift`
