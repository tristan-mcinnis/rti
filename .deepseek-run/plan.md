# Implementation Plan

Generated: 2026-05-07 | Baseline: Build blocked by TCC sandbox (see `.deepseek-run/blocked.md`)
**North Star**: Consolidate tightly-coupled code; extract protocol boundaries; deepen existing modules.

---

## T00 — Resolve build blocker (TCC sandbox)
**Lane**: infra | **Size**: S | **Depends on**: none
**Rationale**: `xcodebuild` cannot resolve packages because `~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/*.dia` files have `com.apple.provenance` protection. User must delete them from Terminal.app.
**Files touched**: none (environment fix)
**Acceptance criteria**:
- `xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build` succeeds
- Full test suite passes with `xcodebuild test`
**Deepening check**: Unblocks all subsequent work by restoring green build.

---

## T01 — Rename KeychainStore → FileCredentialStore
**Lane**: backend | **Size**: S | **Depends on**: T00
**Rationale**: `KeychainStore` is file-backed (`credentials.json`), not macOS Keychain (S6). The misleading name caused confusion during security review. Rename to match implementation.
**Files touched**: `RTI/Sources/Settings/KeychainStore.swift` → `FileCredentialStore.swift`, `RTI/Sources/Secrets.swift` (update references), `RTI/project.yml` (update source path)
**Acceptance criteria**:
- `KeychainStore` type renamed to `FileCredentialStore`
- All call sites updated (`CredentialStore`)
- Full test suite green
- No Keychain references in file that doesn't use it
**Deepening check**: Clarifies the security boundary — file-backed vs Keychain — rather than hiding it behind a misleading name.

---

## T02 — Extract ChatMessageRepository from LLMController
**Lane**: backend | **Size**: M | **Depends on**: T00
**Rationale**: LLMController directly writes `ChatMessage` rows to GRDB (S5). This leaks database knowledge into the presentation/streaming layer. Extract a thin repository.
**Files touched**: New `RTI/Sources/Database/ChatMessageRepository.swift` (~60 LOC), `RTI/Sources/LLM/LLMController.swift` (replace direct GRDB with repository calls), `RTI/project.yml` (add to sources)
**Acceptance criteria**:
- `ChatMessageRepository` provides `insert`, `fetchBySession`, `deleteBySession` methods
- LLMController calls repository, not `RTIDatabase.shared.pool` directly
- All existing tests pass
- LLMController no longer imports GRDB
**Deepening check**: Moves database concern from LLM module back into Database module where it belongs.

---

## T03 — Define SpeakerId enum (type-safe speaker labels)
**Lane**: backend | **Size**: S | **Depends on**: T00
**Rationale**: Speaker labels are raw strings (`"self"`, `"them_1"`, `"note"`) across 5+ files (S8). A typo in a comparison is a runtime error. Define an enum for compile-time safety.
**Files touched**: New type in `RTI/Sources/Support/SpeakerLabelMapping.swift`, update consumers: `TranscriptContext.swift`, `TranscriptAggregator.swift`, `TranscriptPipeline.swift`, `SessionCoordinator.swift`, UI views
**Acceptance criteria**:
- `enum SpeakerId: String` with `.self`, `.them(Int)`, `.note`
- No raw string comparisons for speaker IDs in any file
- Tests green
**Deepening check**: Replaces stringly-typed convention with a compiler-enforced type. Reduces surface for bugs.

---

## T04 — Break LLMController ↔ SessionCoordinator bidirectional dependency
**Lane**: backend | **Size**: M | **Depends on**: T00, T02
**Rationale**: C1 — two `@MainActor` singletons call each other in 6 places. Impossible to test in isolation. Inject session ID as parameter; route through a protocol.
**Files touched**: `RTI/Sources/LLM/LLMController.swift` (accept sessionId parameter), `RTI/Sources/Session/SessionCoordinator.swift` (pass sessionId to LLMController calls), `RTI/project.yml`
**Acceptance criteria**:
- LLMController methods accept `sessionId: String?` parameter instead of reading `SessionCoordinator.shared.currentSessionId`
- SessionCoordinator passes currentSessionId when calling LLMController
- No `SessionCoordinator.shared` call from LLMController
- Tests green
**Deepening check**: Unwinds the tightest coupling in the app (C1). Each singleton gets closer to being independently testable.

---

## T05 — Extract AppBootstrap from AppDelegate
**Lane**: backend | **Size**: M | **Depends on**: T00
**Rationale**: S1 — AppDelegate.applicationDidFinishLaunching wires 8+ singletons in ~80 lines of closure spaghetti. Extract bootstrapping into a coordinator registry pattern.
**Files touched**: New `RTI/Sources/AppBootstrap.swift` (~100 LOC), `RTI/Sources/AppDelegate.swift` (reduced to ~40 LOC), `RTI/project.yml`
**Acceptance criteria**:
- `AppBootstrap` owns the wiring: each module registers callbacks via a protocol
- AppDelegate delegates to `AppBootstrap.install()`
- No change in behavior
- Tests green
**Deepening check**: AppDelegate becomes a thin shell. New features register themselves without touching AppDelegate.

---

## T06 — Add protocol for DeepSeekClient (LLMService)
**Lane**: backend | **Size**: M | **Depends on**: T00
**Rationale**: S7 — four consumers call `DeepSeekClient.shared` directly. No protocol means no testing with a fake. Extract a protocol so LLMController, SummaryController, etc. can be tested in isolation.
**Files touched**: New protocol in `RTI/Sources/LLM/LLMService.swift`, `RTI/Sources/LLM/DeepSeekClient.swift` (conform), `RTI/Sources/LLM/LLMController.swift`, `RTI/Sources/LLM/LLMRequest.swift`, `RTI/Sources/Summary/SummaryController.swift`, `RTI/Sources/Session/SessionTitleController.swift`, `RTI/Sources/Session/SessionQAController.swift`, `RTI/project.yml`
**Acceptance criteria**:
- `protocol LLMService` with `streamChat` and `collectStreamedResponse` signatures
- `DeepSeekClient` conforms
- All consumers accept `LLMService` via init injection (defaulting to `DeepSeekClient.shared`)
- Existing tests green
**Deepening check**: Establishes the first protocol boundary at the LLM layer. Enables future testing with fakes.

---

## T07 — Add protocol for SonioxClient (TranscriptionService)
**Lane**: backend | **Size**: M | **Depends on**: T00
**Rationale**: S7 — AudioPipeline creates `SonioxClient` directly. Extracting a protocol enables testing the audio pipeline with a fake transcriber and prepares for local STT replacement.
**Files touched**: New protocol in `RTI/Sources/Soniox/TranscriptionService.swift`, `RTI/Sources/Soniox/SonioxClient.swift` (conform), `RTI/Sources/Audio/AudioPipeline.swift` (accept protocol), `RTI/project.yml`
**Acceptance criteria**:
- `protocol TranscriptionService` with `connect`, `disconnect`, `sendAudio`, `finalize` and callback properties
- `SonioxClient` conforms
- `AudioPipeline` accepts `TranscriptionService` factory
- Tests green
**Deepening check**: Opens the door to swapping Soniox for local WhisperKit/Apple Speech without touching SessionCoordinator.

---

## T08 — Incremental FTS reindex (replace full reindex on session-end)
**Lane**: backend | **Size**: S | **Depends on**: T00
**Rationale**: S4 — every session-end triggers full FTS5 reindex walking all markdown files. O(n) per session with n sessions. Reindex only the new file.
**Files touched**: `RTI/Sources/Corpus/CorpusFTSReindexer.swift` (add single-file method), `RTI/Sources/Corpus/CorpusManager.swift` (call single-file reindex)
**Acceptance criteria**:
- `CorpusFTSReindexer.reindex(file:)` indexes a single markdown file
- `CorpusManager.renderSession` calls single-file reindex instead of full
- `CorpusFTSReindexer.reindex(from:)` kept for recovery/launch paths
- Tests green
**Deepening check**: Takes a linear perf degradation off the hot path. Session-end stays fast regardless of corpus size.

---

## T09 — Add windowWillClose frame save to OverlayWindowController
**Lane**: backend | **Size**: S | **Depends on**: T00
**Rationale**: S9 — debounced drag-based frame save can miss the final position if the window closes during the 0.2s debounce window. Add a separate save on close.
**Files touched**: `RTI/Sources/OverlayWindowController.swift`
**Acceptance criteria**:
- `windowWillClose` notification observer saves frame
- No duplicate saves (debounce and close-save don't race)
- Frame persists correctly after rapid close-after-move
**Deepening check**: One-line fix that closes a data-loss window. No new abstraction needed.

---

## T10 — Session-end state machine (observable finalize window)
**Lane**: backend | **Size**: L | **Depends on**: T00, T04
**Rationale**: S2 — session-end is a cascade of 4 modules with a hardcoded 1.5s sleep. Model as states: `.running` → `.finalizing` → `.rendered`. Make the finalize window observable so UI can show "Finalizing…" and the render happens on a clear trigger.
**Files touched**: `RTI/Sources/Session/SessionCoordinator.swift` (add SessionPhase enum, state machine), `RTI/Sources/Audio/AudioPipeline.swift` (finalization callback)
**Acceptance criteria**:
- `SessionPhase` enum: `.idle`, `.running`, `.finalizing`, `.rendering`, `.ready`
- `@Published var phase: SessionPhase` on SessionCoordinator
- 1.5s delay replaced with `finalize()` callback triggering phase transition
- UI observes `phase` for state-dependent rendering
- Tests green
**Deepening check**: Replaces a timing-based assumption with a state machine. Makes session-end observable and testable.

---

## T11 — Test coverage floor: ChatMessageRepository
**Lane**: tests | **Size**: M | **Depends on**: T02
**Rationale**: T02 extracts a new repository — needs tests. Write unit tests for insert, fetchBySession, deleteBySession against an in-memory GRDB database.
**Files touched**: New `RTI/Tests/ChatMessageRepositoryTests.swift`, `RTI/project.yml` (add to test sources)
**Acceptance criteria**:
- Insert then fetch returns the message
- Delete by session removes only that session's messages
- Empty fetch returns empty array
**Deepening check**: Tests the repository boundary. Ensures the layer separation in T02 doesn't regress.

---

## T12 — Test coverage floor: LLMController with fake LLMService
**Lane**: tests | **Size**: M | **Depends on**: T06
**Rationale**: T06 introduces `LLMService` protocol. Write a test that injects a fake LLM service and verifies LLMController's entry management, streaming state, and error handling without network calls.
**Files touched**: New `RTI/Tests/LLMControllerTests.swift`
**Acceptance criteria**:
- FakeLLMService delivers deltas; LLMController correctly accumulates entries
- Error delivery sets `lastError` and `lastErrorIsAuth` correctly
- Cancel stops streaming and prunes trailing empty entry
- Smart mode flag toggles correctly
**Deepening check**: First integration-level test of LLMController. Protocol makes it possible to test without API keys.

---

## T13 — ADR: Markdown-canonic corpus architecture
**Lane**: docs | **Size**: S | **Depends on**: none (read-only)
**Rationale**: The markdown-corpus design (SQLite as derived index, JSONL live stream, atomic write) is a non-trivial architectural decision not yet documented as an ADR.
**Files touched**: New `docs/adr/0001-markdown-canonical-corpus.md`
**Acceptance criteria**:
- ADR covers: context (SQLite-canonical → markdown-canonical shift), decision (markdown as canonical, SQLite as sidecar), consequences (grep-ability, external agent access, migration risk)
- References `docs/specs/markdown-corpus-and-companions.md` and `CONTEXT.md`
**Deepening check**: Documents a key architectural boundary so future contributors understand why SQLite is "just" an index.

---

## Backlog (deferred)
- **T14**: Add protocol for `RTIDatabase` (DatabaseService) — S7 continuation
- **T15**: Replace 1.5s Soniox sleep with `end_of_stream` message handler — S10
- **T16**: Rename remaining singleton `.shared` access points to injected dependencies
- **T17**: Extract `SessionRepository` protocol for CorpusBackedStore
- **T18**: Add MCP tool test suite with fixture corpus
- **T19**: Add Snapshot/UI tests for OverlayPanelView
- **T20**: Add perf test for FTS reindex with 1000-file corpus
