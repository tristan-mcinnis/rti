# Coupling Report — Top Cross-Module Dependencies

Ranked by (edit-frequency × fan-in). Each entry cites the coupling direction and file:line evidence.

## C1: SessionCoordinator ↔ LLMController (bidirectional 6-way)
**Severity**: High | **Files**: `SessionCoordinator.swift` ⇄ `LLMController.swift`
- SessionCoordinator calls `LLMController.shared.resetMemory()` (line: startSession), `.loadHistoryForCurrentSession()` (line: launchSession)
- LLMController calls `SessionCoordinator.shared.currentSessionId` (line: performSend, loadHistoryForCurrentSession), `.clearCurrentSessionMessages()` (line: clear), `.startedAt` (line: recentTranscriptText)
- LLMController persists `ChatMessage` to `RTIDatabase.shared.pool` (line: persistMessage)
- **Risk**: Any change to session lifecycle propagates to LLM state management. Two `@MainActor` singletons that each hold references to the other — hard to test in isolation.

## C2: SessionCoordinator ↔ CorpusManager (dual-write path)
**Severity**: High | **Files**: `SessionCoordinator.swift:launchSession` → `CorpusManager.swift:openLive`; `SessionCoordinator.swift:completeStop` → `CorpusManager.swift:renderSession`
- SessionCoordinator opens JSONL on start, passes session-end trigger to CorpusManager
- CorpusManager reads `SessionTitleController` and `SummaryController` cache during render
- CorpusManager writes FTS via `CorpusFTSReindexer`
- **Risk**: Session-end orchestration spans 4 modules (SessionCoordinator → CorpusManager → MarkdownRenderer + TitleController + SummaryController + CorpusFTSReindexer). The stopSession → 1.5s delay → completeStop → render chain is fragile.

## C3: AppDelegate → All Coordinators (God-object wiring)
**Severity**: Medium | **Files**: `AppDelegate.swift` ↔ `WindowCoordinator`, `MenuCoordinator`, `HotkeyCoordinator`, `SessionCoordinator`, `LLMController`, `ModeStore`, `ScreenshotManager`, `CommandRegistry`, `CorpusManager`
- applicationDidFinishLaunching wires 8+ singleton references with callback closures
- ~80 lines of closure-based wiring
- **Risk**: Adding a new feature requires touching AppDelegate even when the feature is self-contained. Testing requires the full app to be running.

## C4: LLMController → RTIDatabase (direct ORM write)
**Severity**: Medium | **Files**: `LLMController.swift:persistMessage` → `RTIDatabase.swift`
- LLMController writes `ChatMessage` rows directly to the database pool
- Not routed through any repository or coordinator
- **Risk**: LLMController knows about database schema. If chat_messages schema changes, LLMController must be updated.

## C5: TranscriptPipeline → CorpusManager (live write)
**Severity**: Medium | **Files**: `TranscriptPipeline.swift:writeJSONL` → `CorpusManager.swift:liveWriter`
- TranscriptPipeline accesses `CorpusManager.shared.liveWriter(sessionId:)` to write JSONL
- Depends on SessionCoordinator.shared.currentSessionId being set
- **Risk**: Two indirect singleton accesses in a hot path (every final Soniox word).

## C6: AudioPipeline ↔ SonioxClient (WebSocket lifecycle)
**Severity**: Medium | **Files**: `AudioPipeline.swift` → `SonioxClient.swift`
- AudioPipeline creates, connects, and tears down SonioxClient instances
- PCM buffer callback → sendAudio chain is performance-sensitive
- **Risk**: AudioPipeline owns two SonioxClient instances (mic + system). Error handling differs between them (mic errors propagate to UI; system errors are soft-logged). Asymmetric error handling could mask system-audio transcription failures.

## C7: CorpusManager → RTIDatabase (FTS reindex)
**Severity**: Medium | **Files**: `CorpusManager.swift:renderSession` → `RTIDatabase.swift:pool` via `CorpusFTSReindexer.reindex`
- Every session-end render triggers a full FTS5 reindex of the entire corpus directory
- **Risk**: O(n) where n = all markdown files. With 100s of files, this becomes a perf bottleneck on session-end.

## C8: DeepSeekClient.shared (4 consumers)
**Severity**: Medium | **Files**: `LLMController`, `SummaryController`, `SessionTitleController`, `SessionQAController` → `DeepSeekClient.swift`
- All four consumers use `DeepSeekClient.shared` directly
- `URLSession` is already shared underneath via the static session
- **Risk**: Rate-limiting or queuing is decentralized — each consumer manages its own concurrency. Two simultaneous LLM calls (e.g., summary + title on session-end) could double API costs.

## C9: SessionCoordinator → SpeakerLabelMapping (implicit contract)
**Severity**: Low | **Files**: `SessionCoordinator.swift` → `SpeakerLabelMapping.swift`
- `SpeakerLabelMapping.rawLabel(speaker:channel:)` is called from `TranscriptAggregator` and `TranscriptContext`
- The mapping (`speaker:0 → "self"`, `speaker:1+ → "them_N"`) is a convention, not an enforced type
- **Risk**: If Soniox changes speaker ID semantics, label mapping might silently break. No compile-time guard.

## C10: KeychainStore (misleading name)
**Severity**: Low | **Files**: `Secrets.swift` → `CredentialStore` → `KeychainStore.swift`
- `KeychainStore` is file-backed (`credentials.json`), not Keychain
- Named "KeychainStore" for historical reasons — comment explains the ad-hoc signing issue
- **Risk**: Future developer sees "KeychainStore" and assumes `SecItem*` — could lead to confusion during security review.
