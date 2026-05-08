# Smell Report — Top 10 Most Impactful

Severity = blast radius × frequency of encounter. Sorted by severity descending.

## S1: AppDelegate God Object (Orchestrator sprawl)
**Severity**: High | **File**: `AppDelegate.swift` ~140 lines of wiring
- `applicationDidFinishLaunching` wires 8+ singletons with ~25 callback closures
- Every new feature requires a line in AppDelegate — even fully self-contained modules
- No DI container, no coordinator protocol — everything is hard-wired
- **Fix**: Extract wiring into `AppBootstrap` or a coordinator registry. Each module registers itself.

## S2: Session-end orchestration chain (4-module cascade)
**Severity**: High | **Files**: `SessionCoordinator.swift:stopSession` → `completeStop` (1.5s delay) → `CorpusManager.renderSession` → `MarkdownRenderer` + `SessionTitleController` + `SummaryController` + `CorpusFTSReindexer`
- Stop session has a 1.5s `Task.sleep` to wait for Soniox finals
- If the app terminates during that window, data is lost (mitigated by `emergencyShutdown` but still fragile)
- `triggerSummaryIfNeeded` checks `LiveJSONLReader.readAll` for content → generates title + summary + render in a fire-and-forget `Task`
- **Fix**: Model session-end as a state machine (ended → finalizing → rendered). Make the 1.5s window observable.

## S3: Dual singletons calling each other (LLMController ⇄ SessionCoordinator)
**Severity**: High | **Files**: `LLMController.swift` ⇄ `SessionCoordinator.swift`
- Bidirectional `@MainActor` singleton dependencies
- `LLMController.persistMessage` calls `SessionCoordinator.shared.currentSessionId`
- `SessionCoordinator.startSession` calls `LLMController.shared.resetMemory()`
- Impossible to instantiate either in test isolation
- **Fix**: Pass session ID as parameter; inject dependencies rather than reaching for `.shared`.

## S4: Full FTS reindex on every session-end
**Severity**: Medium | **Files**: `CorpusManager.swift:renderSession` → `CorpusFTSReindexer.reindex`
- Every session-end triggers full reindex of all markdown files
- `CorpusFTSReindexer.reindex` walks entire `~/meetings/` directory and rebuilds FTS table
- O(n) where n = all sessions. With many sessions this is a perf degradation
- **Fix**: Reindex only the new/changed file. Use mtime tracking or incremental index.

## S5: Chat message persistence in LLMController (leaky layer)
**Severity**: Medium | **File**: `LLMController.swift:persistMessage`
- LLMController (presentation/streaming logic) directly writes to `RTIDatabase.shared.pool`
- Knows about `ChatMessage` ORM type and column names
- Same pattern in `loadHistoryForCurrentSession` — direct GRDB query
- **Fix**: Extract `ChatMessageRepository` that LLMController calls into. Database concern stays in Database module.

## S6: CredentialStore is file-backed, named KeychainStore
**Severity**: Low (correctness) / Medium (security review) | **Files**: `KeychainStore.swift`, `Secrets.swift`
- `KeychainStore` name implies `SecItem*` — actually writes to `credentials.json` (mode 0600)
- Comment explains ad-hoc signing breaks Keychain ACL; but the name is misleading
- `credentials.json` lacks encryption at rest
- **Fix**: Rename to `FileCredentialStore`. Consider `Data(protection: .complete)` or `CryptoKit` encryption if threat model warrants it.

## S7: No protocol abstractions for any service
**Severity**: Medium | **Files**: All singleton types
- `DeepSeekClient` — no protocol, consumers call `.shared` directly
- `SonioxClient` — instantiated directly by `AudioPipeline`, no abstraction
- `RTIDatabase` — accessed via `.shared.pool` from 5+ modules
- `CorpusManager` — `.shared` from 4+ modules
- **Fix**: Introduce protocols at module boundaries. Enables testing with fakes and enables swapping implementations (e.g., local STT replacing Soniox).

## S8: Speaker label mapping is stringly-typed
**Severity**: Low | **Files**: `SpeakerLabelMapping.swift`, all consumers
- Speaker IDs are raw strings: `"self"`, `"them_1"`, `"them_2"`, `"note"`
- No enum, no type safety — typos in speaker ID comparisons are runtime errors
- `TranscriptContext.format` checks `e.speakerId == "note"` via string comparison
- **Fix**: Define `enum SpeakerId: String` with cases `.self`, `.them(Int)`, `.note`. 

## S9: OverlayWindowController frame persistence debounce is fragile
**Severity**: Low | **File**: `OverlayWindowController.swift`
- `DispatchWorkItem` debounce for frame save — cancel on every move, reschedule at 0.2s
- If the window is closed during the debounce window, the `[weak self]` guard skips the save
- No guarantee the final position is saved if the user closes quickly after moving
- **Fix**: Save on `windowWillClose` notification in addition to the debounced move handler.

## S10: No error recovery for Soniox `finalize()` → finals race condition
**Severity**: Low (rare) | **File**: `SessionCoordinator.swift:stopSession`
- `finalize()` signals end-of-audio to Soniox, then 1.5s sleep, then `finish()` disconnects
- If finals arrive after `finish()`, they're lost (WebSocket disconnected)
- Soniox docs recommend waiting for a specific "end of stream" message before disconnecting
- **Fix**: Wait for Soniox `end_of_stream` message or a timeout, whichever comes first, rather than a fixed 1.5s sleep.
