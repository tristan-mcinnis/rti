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

## Repository status

The POC series (POC-1 through POC-7) is complete; per-POC findings live in `RTI/POC*-findings.md`. The build is now in active development, no longer POC-by-POC. There is no consolidated spec — when in doubt about intended behavior, read the relevant POC findings file plus the current code, not an external spec.

Layout:

- `RTI/` — Xcode project. Generated via `xcodegen` from `RTI/project.yml`. Build with `xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build`. Runtime artifact at `~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app`. Bundle id `com.tristan.rti`, macOS 14+, menubar-accessory app (`LSUIElement=YES`).
- `RTI/Sources/` — all Swift sources (overlay, audio, Soniox, LLM, screenshot, GRDB, sessions, corpus, modes, widgets, settings, UI).
- `RTI/MCP/` — `rti-mcp` standalone JSON-RPC server, bundled into Resources for external agents.
- `RTI/Tests/` — XCTest unit + integration tests.
- `RTI/POC*-findings.md` — historical per-POC validation logs (1–7). Reference for "why was this built this way?" — not a spec.
- `RTI/VERIFY.md` — manual verification steps for running builds.
- `docs/adr/` — architecture decision records.
- `docs/specs/` — feature specs.
- `.omc/` — oh-my-claudecode state. `plans/` contains saved plans; `prd.json` tracks user stories. Do not hand-edit.

## POC inventory (historical)

All seven POCs landed; the findings files are the canonical record of what was decided and why.

| POC | Element |
|-----|---------|
| POC-1 | Invisible overlay — borderless translucent `NSPanel`, `sharingType=.none`, ⌘\\ Carbon hotkey, menubar status item |
| POC-2 | Audio → Soniox WebSocket → GRDB/SQLite transcript |
| POC-3 | LLM SSE streaming + overlay assistant UI (provider-agnostic, DeepSeek default) |
| POC-4 | Smart Screenshot — ⌘H, `SCScreenshotManager`, Vision OCR; image discarded after OCR |
| POC-5 | Persistence layer — sessions, transcripts, messages, modes in GRDB/SQLite |
| POC-6 | Three-window layout — split-panel overlay, top widget, mini widget |
| POC-7 | Modes, reference files, settings, Keychain |

Read the corresponding findings file before changing behavior in any of these areas.

## Architecture

Single-process macOS app. `AppState` (`@MainActor ObservableObject`) is the app-wide singleton.

Three pipelines feed into `AppState`:

1. **Audio pipeline** — `AVAudioEngine` tap → 16 kHz mono PCM → Soniox WebSocket (`wss://api.soniox.com/transcribe-websocket`) → interim + final transcript entries written to SQLite. System-audio loopback via `ScreenCaptureKit` is opt-in.
2. **Screen pipeline** — on-demand `SCScreenshotManager` capture + Vision OCR. Screenshots are passed to the LLM then discarded (never persisted).
3. **LLM pipeline** — provider-agnostic OpenAI-compatible streaming chat (default DeepSeek at `https://api.deepseek.com/v1`) via SSE. Provider config lives in `RTI/Sources/LLM/LLMProvider.swift` (`LLMProviders` registry); swap by changing `LLMProviders.activeId`. Prompt shapes: Assist, "What should I say?", Follow-up questions, Recap.

Persistence: GRDB/SQLite at `~/Library/Application Support/RTI/rti.db`. The markdown corpus at `~/meetings/*.md` is the canonical record; the SQLite store is a derived index.

"Undetectability" = `NSWindow.sharingType = .none`. POC-1's `screencapture -x` test confirms exclusion against that capture path; QuickTime and Zoom are user-attested (see `RTI/POC1-findings.md`).

Global hotkeys use Carbon `RegisterEventHotKey` so they fire from any frontmost app. Registrations live in `RTI/Sources/UI/HotkeyCoordinator.swift` — that file is the source of truth, not the README table.

## Conventions

- **Secrets**: never commit API keys, never put them in `UserDefaults`, never `.env` files. Keys live in `KeychainStore` (backed by `~/Library/Application Support/RTI/credentials.json`, mode 0600).
- **Transcript semantics**: Soniox emits words with `is_final: false` (interim, update in place) and `is_final: true` (commit, persist to `transcript_entries`). Map `speaker: 0` → `"self"`, `1+` → `"them_1"`, `"them_2"`, etc.
- **Streaming responses**: The LLM SSE parser handles the `data: [DONE]` sentinel and concatenates `choices[].delta.content`. DeepSeek's `reasoning_content` field (gated by `LLMProviderConfig.supportsThinking`) is surfaced through a separate `onReasoning` callback.
- **Soniox reconnect policy**: exponential backoff 1s → 2s → 4s → 8s, max 5 retries, then surface error.
- **Swift/SwiftUI scope**: the overlay is a hand-rolled `NSPanel`, not a SwiftUI `WindowGroup`. SwiftUI is used inside the panel via `NSHostingView`.
- **Dependencies**: keep SPM deps minimal — only add when a feature needs it (current set: GRDB, Starscream).

## Where to look for what

- **Overlay implementation** → `RTI/Sources/OverlayWindowController.swift` + `RTI/Sources/OverlayPanelView.swift`
- **Hotkey registration** → `RTI/Sources/UI/HotkeyCoordinator.swift` (with `RTI/Sources/GlobalHotkey.swift` as the Carbon wrapper)
- **App entry / status item** → `RTI/Sources/RTIApp.swift` + `RTI/Sources/AppDelegate.swift`
- **Soniox wire shapes** → `RTI/Sources/Soniox/SonioxProtocol.swift`
- **LLM wire shapes** → `RTI/Sources/LLM/LLMWireShapes.swift`
- **Per-session Q&A** → `RTI/Sources/Session/SessionQAController.swift` (scoped to one session's transcript + summary)
- **Cross-corpus Q&A ("Ask Your Corpus")** → `RTI/Sources/Session/AskCorpusController.swift` + `RTI/Sources/UI/SessionsControl/AskCorpusView.swift`
- **Chat history persistence** → `RTI/Sources/Session/AskCorpusHistoryStore.swift` (JSON files under `~/Library/Application Support/RTI/ask-corpus/`)
- **Drag-to-import (audio / video / folder)** → `RTI/Sources/Session/SessionImporter.swift` (queueing + AVAssetReader transcode + Soniox file-mode + corpus write)
- **Live transcript-driven panels** → `RTI/Sources/Panels/PanelSpawner.swift` + `PanelKind.swift` (chat tool routes here)
- **Lexical search across corpus** → `RTI/Sources/Session/SessionSearch.swift` (SQLite FTS5, BM25-ranked, prefix tokens AND-ed)
- **Manual verification steps** → `RTI/VERIFY.md`
- **Why a feature looks the way it does** → the matching `RTI/POC*-findings.md`
- **Regenerate the Xcode project after editing `project.yml`** → `cd RTI && xcodegen generate`

## Notes on the corpus Q&A pipeline (post-POC additions)

Ask Your Corpus is retrieval-augmented generation over **hybrid retrieval** (BM25 + dense embeddings, RRF-merged). `AskCorpusController.retrieve` and `ProjectQAController.retrieve` both call `HybridRetriever.retrieve` (`RTI/Sources/Corpus/HybridRetriever.swift`), which pulls top-20 from `SessionSearch.search` (SQLite FTS5) and top-20 sessions from cosine over `corpus_embeddings`, then fuses by `1/(60+rank)`. The top 6 sessions plus the 4 most-recent (deduped, capped at 8) get title + date + summary (≤1500 chars) + best-snippet packaged for the LLM. One streaming call with prior-turn memory (last 6 turns) and citation-aware system prompt produces the answer; the controller then parses `[Session Title]` from the response to surface only actually-cited sessions as clickable chips. Conversations auto-persist to `~/Library/Application Support/RTI/ask-corpus/` after each completed turn.

**Dense index.** `corpus_embeddings(session_id, chunk_idx, text, vector, indexed_at)` — one row per chunk, `vector` is L2-normalised Float32 BLOB. Cosine is a plain dot product. Brute-force scan over every row at query time — at our scale (<50k chunks) this is ~5 ms, no ANN structure needed.

**Embedder (v1):** Apple's built-in `NLEmbedding.sentenceEmbedding(for: .english)` via `RTI/Sources/Corpus/Embedder.swift` — 512-dim, zero deps, zero install friction. Word2vec-style and lower quality than modern transformer embeddings, but already a large recall jump over lexical-only (verified: `"luxury cars"` → `"Maserati"` session matches in practice). v2 upgrade path (bge-small via MLX + swift-transformers) is sketched in `docs/specs/embeddings.md`; the swap is confined to `Embedder.swift`.

**Chunking.** `ChunkPolicy.split` is paragraph-greedy with ~500-word windows and 60-word overlap. Summary and transcript are indexed separately so the snippet text in the DB matches what the model embedded.

**Indexing triggers.** `CorpusIndexer.reindex` runs alongside `CorpusFTSReindexer.reindex` at every call site (session finalise, import, regenerate, launch recovery, Settings rebuild). On first launch after the v17 migration, `CorpusIndexer.backfillIfEmpty` runs once in the background to populate the dense index from existing markdown. Fallback: if `NLEmbedding` is unavailable or the dense table is empty, `HybridRetriever` silently falls back to FTS-only.

**Diagnostic log.** Every retrieve emits `[corpus] retrieve — fts=X dense=Y denseSessions=Z denseOnly=N ftsOnly=M fused=F used=U`. The number to watch is `denseOnly` — sessions the embedder surfaced that FTS missed entirely. > 0 is the proof embeddings are doing useful work.
