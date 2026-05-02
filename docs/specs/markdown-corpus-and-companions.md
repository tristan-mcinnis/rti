# Spec: Markdown Corpus, Soniox Error Classification, Command Palette

Status: ready to implement
Date: 2026-05-03
Owner: Tristan
Source of decisions: Q1–Q6 grilled in conversation, recorded inline below.

## Why this lands as one spec

Three features were chosen together as part of a single push to make RTI snappier, more lightweight, and more native to Apple Silicon. They are independent in implementation but share a domain framing (the **Corpus** as the user's permanent meeting record — see `CONTEXT.md`). Implementing them in one ladder keeps the architectural intent visible. The order below is least-risk-first, biggest-swing-last.

1. **Soniox error classification** — small, isolated, mirrors the just-landed `DeepSeekError.userMessage` pattern.
2. **Command palette (⌘⇧K)** — medium, isolated, single new UI surface backed by a typed command registry.
3. **Markdown Corpus + MCP server** — large, structurally consequential. Markdown becomes the canonical store; SQLite becomes a derived index/sidecar; a standalone `rti-mcp` binary exposes the Corpus to external agents.

---

## Landing 1 — Soniox error classification

### Goal
Stop blindly retrying on non-transient Soniox failures (auth, client bug). Surface auth errors in <100ms instead of after 23s of pointless retries. Distinguish handshake failures (network/proxy) from post-connect drops in user-facing copy.

### Decision summary
- **Mirror the `DeepSeekError.userMessage` pattern.** Same shape, same idiom, same testing approach.
- **User copy differs by phase** (handshake vs post-connect drop) — Q5 picked (b).

### Design

New file: `RTI/Sources/Soniox/SonioxFailure.swift`

```swift
enum SonioxFailure: Error {
    case auth                       // 401, 402, 403
    case clientBug(String)          // 400 — RTI's bug, log it
    case transient(String)          // 408, 429, 5xx, network drop, dns
    case unknown(code: Int, body: String)
}

extension SonioxFailure {
    var userMessage: String { /* phase-aware copy lives below in callsite */ }
    var shouldRetry: Bool { ... }   // false for auth + clientBug
    var isAuth: Bool { ... }
}
```

Phase-aware user copy lives where the failure is surfaced (SessionCoordinator), not on the enum itself, since the same case (`transient`) reads differently pre-open vs post-open.

```swift
extension SonioxFailure {
    func userMessage(didOpen: Bool) -> String {
        switch (self, didOpen) {
        case (.auth, _):
            return "Soniox rejected the API key. Open Settings to update it."
        case (.clientBug(let detail), _):
            return "RTI sent a bad request to Soniox: \(detail.prefix(200))"
        case (.transient, false):
            return "Couldn't reach Soniox — check internet connection or proxy settings."
        case (.transient, true):
            return "Soniox connection dropped — reconnecting…"
        case (.unknown(let code, let body), _):
            return "Soniox error \(code): \(body.prefix(200))"
        }
    }
}
```

### Files touched

- `RTI/Sources/Soniox/SonioxFailure.swift` — new (~80 LOC)
- `RTI/Sources/Soniox/SonioxClient.swift`:
    - Track `didOpen: Bool` (set on `.connected`, reset on `disconnect`/`teardown`).
    - Classify HTTP codes and disconnect reasons into `SonioxFailure`.
    - Change `onError` callback type from `((String) -> Void)?` to `((SonioxFailure, Bool) -> Void)?`.
    - In `scheduleReconnect`: consult `failure.shouldRetry`; bail immediately for `auth` / `clientBug`.
- `RTI/Sources/Session/SessionCoordinator.swift`: update `onError` consumer to use `failure.userMessage(didOpen:)` and surface `failure.isAuth` for "Open Settings" affordance.
- `RTI/project.yml` test target: add `Sources/Soniox/SonioxFailure.swift` to `RTITests` sources.
- `RTI/Tests/SonioxFailureTests.swift` — new, mirrors `DeepSeekErrorTests` shape.

### Tests
- `userMessage(didOpen:)` returns auth-specific copy for `.auth` regardless of phase.
- `userMessage(didOpen:)` differs for `.transient` between `didOpen=true` and `didOpen=false`.
- `shouldRetry` is false for `.auth` and `.clientBug`.
- `shouldRetry` is true for `.transient` and `.unknown`.
- `isAuth` is true only for `.auth`.

### Success criteria
- Connecting with an invalid API key surfaces the auth message in under 1s.
- Pulling the network mid-session shows "connection dropped — reconnecting…", not the same copy as a fresh-launch network failure.
- All `RTITests` continue to pass.

---

## Landing 2 — Command palette (⌘⇧K)

### Goal
Add a keyboard-first command palette opened by ⌘⇧K (with ⌘⇧O / ⌘⇧U fallbacks for IDE collisions). Backed by a typed command registry that's the single source of truth for "what the user can do right now," with state-aware visibility.

### Decision summary
- **Build the central registry now**, drive the palette from it. Menubar items migrate to the registry incrementally as future work touches them — no big-bang rewrite.
- **v1 commands are nullary actions only** (one prompt-taking exception: Insert Note). Arg-taking commands (`Search transcripts: <query>`) deferred to v2.
- **Recents persisted**, top 5, deduped by `command.id`, no arg storage in v1.
- **Skip first-launch notification.** Add the keybinding to the existing `OnboardingWindowController` flow.

### Design

New types:

```swift
struct RTICommand: Identifiable {
    let id: String                       // "session.start", "chat.assist", …
    let title: String
    let subtitle: String?                // "⌘⇧R" or other shortcut hint
    let keywords: [String]               // for fuzzy match boosting
    let isAvailable: () -> Bool
    let perform: () -> Void
}

@MainActor
final class CommandRegistry: ObservableObject {
    static let shared = CommandRegistry()
    func availableCommands() -> [RTICommand]
    func search(_ query: String) -> [RTICommand]   // fuzzy substring + position scoring
    func recordExecution(_ id: String)             // pushes into recents
    func recents(limit: Int = 5) -> [RTICommand]   // empty when no query
}
```

Command list (v1) — see the inline list in the conversation; ~25 entries across Session / Overlay / Chat / Capture / Modes / Other.

Palette UI:

- `CommandPaletteWindowController` owns a borderless `NSPanel` (level `.floating`, hides on `Esc` or focus loss). Same idiom as `OverlayWindowController`.
- SwiftUI body via `NSHostingView`: single `TextField` at top, scrollable `List` of matching commands below, keyboard navigation (↑↓ select, ⏎ execute, Esc dismiss).
- Center on active screen on open. No frame persistence.
- Width 600pt, max 480pt height, dynamic to result count.

Hotkey wiring:
- New entry in `AppDelegate.applicationDidFinishLaunching` registering `⌘⇧K` via the existing `GlobalHotkey` Carbon path.
- Settings adds a Command Palette section: enable/disable + alt shortcut chooser (⌘⇧K / ⌘⇧O / ⌘⇧U).

Recents storage:
- `UserDefaults` key `rti.palette.recents` — `[String]` of command ids, capped to 5.
- On `recordExecution`, prepend if not present, drop oldest beyond cap.
- Recents list is filtered by `isAvailable` at display time (a recent "Stop Session" doesn't appear when no session is running).

### Files touched / created

- `RTI/Sources/UI/CommandPalette/CommandRegistry.swift` — new (~150 LOC).
- `RTI/Sources/UI/CommandPalette/CommandPaletteView.swift` — new, SwiftUI palette body (~150 LOC).
- `RTI/Sources/UI/CommandPalette/CommandPaletteWindowController.swift` — new, NSPanel host (~100 LOC).
- `RTI/Sources/AppDelegate.swift`:
    - Instantiate `CommandPaletteWindowController` alongside other window controllers.
    - Register ⌘⇧K hotkey to `paletteController.toggle()`.
- `RTI/Sources/Settings/SettingsView.swift`: add a "Command Palette" section.
- `RTI/Sources/Settings/OnboardingWindowController.swift`: add the keybinding to the keyboard-shortcuts step (no separate notification).

### Tests

- `CommandRegistry.search` returns expected ranking for fuzzy matches: `"sst"` matches "Start Session" before "Stop Session" if the latter isn't a recent (or vice-versa with recency boost).
- `CommandRegistry.recents` deduplicates by id, caps at limit, filters by `isAvailable`.
- (No UI tests for the panel itself in v1; manual smoke test.)

### Success criteria
- ⌘⇧K opens the palette anywhere in the app, in under a frame (16ms).
- Typing "asst" jumps to "Assist" command; ⏎ runs it; palette closes.
- "Stop Session" only appears when recording.
- Used commands float to the top on next palette open.
- IDE-collision: switching to ⌘⇧O via Settings unbinds ⌘⇧K cleanly.

---

## Landing 3 — Markdown Corpus + MCP server

### Goal

Replace SQLite-canonical session storage with **markdown-canonical storage**: every Session is one file in `~/meetings/YYYY-MM-DD-<slug>.md`. SQLite (`rti.db`) becomes a derived FTS index plus a small set of overlay/sidecar tables. A standalone `rti-mcp` Swift CLI binary exposes the Corpus to external agents (Claude Code, Codex, Gemini CLI, Claude Desktop) over JSON-RPC stdio.

### Decision summary (Q1–Q4)

- **Q1: Markdown is canonical.** SQLite is a derived index/sidecar.
- **Q2: Knowledge in markdown, interactions in SQLite.** Transcript + summary + frontmatter (decisions, action items, key topics, attendees, speaker_map) live in markdown. Chat messages with the LLM stay in SQLite (interaction log, not knowledge).
- **Q3: One file per session, JSONL during live, atomic markdown write at session-end.** WAVs continue in app-support, referenced by `wav_path`. User edits to canonical markdown are honored on FTS regeneration but never round-tripped back into RTI.
- **Q4: One MCP server, standalone CLI, stdio transport, read-only in v1.** Tools: `search_corpus`, `read_meeting`, `list_meetings`, `read_live_transcript`. Distributed inside the .app bundle.

### Frontmatter schema (canonical for `~/meetings/*.md`)

```yaml
---
id: 9C8A7B6D-3E2F-4A1B-9D8C-1234567890AB        # session UUID, immutable
date: 2026-05-02T14:30:00-05:00                   # ISO-8601, meeting start
captured_at: 2026-05-02T14:29:55-05:00            # optional, when capture began
duration: 42m                                     # human-friendly
title: Pricing discussion with Alex
mode: sales-prep                                  # ModeStore mode id, optional
attendees: [Tristan, Alex Kim]                    # display names
speaker_map:                                      # snapshot at session-end
  self: { name: Tristan, source: deterministic }
  them_1: { name: Alex Kim, source: llm }
decisions:
  - text: Move to monthly billing
    topic: pricing
    authority: high
action_items:
  - assignee: alex-kim
    task: Send revised contract by Friday
    due: 2026-05-09
    status: open
key_topics: [pricing, billing-cadence, contracts]
transcript_quality: hifi                          # "realtime" | "hifi"
wav_path: ~/Library/Application Support/RTI/audio/9C8A...wav
---
## Summary
…the markdown summary as written by SummaryController…

## Transcript
[self 0:00] Let's talk pricing
[them_1 0:08] Sure, what are you thinking
…
```

### Storage layout

```
~/meetings/                                          # canonical Corpus (default; user-configurable)
  2026-05-02-pricing-discussion.md
  2026-05-03-standup.md
  …

~/Library/Application Support/RTI/
  rti.db                                             # SQLite sidecar
    chat_messages                                    # interaction log (kept)
    modes                                            # config (kept)
    session_search (FTS5)                            # derived index (kept, regenerated)
    speaker_overlays                                 # NEW: cross-session corrections
  audio/<uuid>.wav                                   # raw audio per session (existing path)
  live/<session-id>.jsonl                            # NEW: in-flight session live stream
```

Tables to **drop after migration** (data moves to markdown):
- `sessions`
- `transcript_entries`
- `session_summaries`

### Live-write architecture

During a live session, `SessionCoordinator` writes append-only JSONL events to `~/Library/Application Support/RTI/live/<session-id>.jsonl`. One line per event:

```json
{"t":"word","ts":1234,"speaker":1,"text":"hello","is_final":true,"confidence":0.93}
{"t":"word","ts":1240,"speaker":1,"text":" world","is_final":true,"confidence":0.95}
{"t":"note","ts":1500,"text":"action: send contract"}
{"t":"chat","ts":1900,"role":"user","content":"what was decided"}
{"t":"chat","ts":1903,"role":"assistant","content":"…"}
```

On session-end:

1. `SessionTitleController` generates title (existing flow).
2. `SummaryController` generates summary + parses sections (existing flow).
3. New `MarkdownRenderer.render(sessionId:)` reads the JSONL, joins it with title+summary+frontmatter, and atomically writes `~/meetings/YYYY-MM-DD-<slug>.md` (`.tmp` then rename).
4. JSONL is deleted only after the markdown file exists.
5. FTS index regenerated for the new file.

`MarkdownRenderer` is a pure function over `(JSONLContents, SessionMetadata) -> String`. Test surface is the full markdown body; no DB needed.

### Crash recovery

On launch, scan `~/Library/Application Support/RTI/live/`. For each orphaned JSONL:
- If a session row still exists in the legacy `sessions` table (during migration window): consolidate using whatever metadata is available, generate title/summary on next user trigger.
- If no session row (post-migration): render with a placeholder title (`Recovered session 2026-05-02 14:30`) and surface in the menubar's Recent Sessions for the user to rename / regenerate.

### Speaker overlays

New SQLite table:
```sql
CREATE TABLE speaker_overlays (
  speaker_key TEXT NOT NULL,    -- "self" | "them_1" | …
  display_name TEXT NOT NULL,
  scope TEXT NOT NULL,          -- "global" | "session:<id>"
  source TEXT NOT NULL,         -- "deterministic" | "llm" | "manual"
  updated_at DATETIME NOT NULL,
  PRIMARY KEY(speaker_key, scope)
);
```

UI affordance "Rename `them_1` → Alex Kim everywhere" writes a `scope='global'` row. FTS query layer applies overlays at result-render time, never rewrites markdown.

### FTS5 reindex

Migrations register triggers on the `speaker_overlays` table for invalidation. The reindex job:
- Walks `~/meetings/*.md` for files with `mtime` newer than the FTS index's last seen `mtime`.
- Parses frontmatter + body, splits transcript into row entries (speaker + line + offset), inserts into `session_search`.
- For chat messages, indexes from SQLite (existing path).

The reindex runs on:
- App launch (background, low priority)
- File-add detected via `DispatchSource.makeFileSystemObjectSource` watcher on `~/meetings/`
- After session-end markdown write

### `rti-mcp` standalone binary

New xcodegen target `RTIMCP` of type `tool` (commandline). Single `@main` enum (`RTIMCPMain`) implementing JSON-RPC over stdio per the MCP spec.

```
RTI.app/Contents/Resources/rti-mcp                  # bundled binary
```

Tools exposed:

| Tool | Inputs | Returns |
|---|---|---|
| `search_corpus` | `{ query: string, limit?: int=10, since?: iso8601, until?: iso8601 }` | `[{ path, date, title, snippet, score }]` |
| `read_meeting` | `{ path: string }` *or* `{ date: iso, slug: string }` | `{ frontmatter: object, body: string }` |
| `list_meetings` | `{ limit?: int=20, since?: iso8601, until?: iso8601 }` | `[{ path, date, title, attendees, key_topics }]` |
| `read_live_transcript` | `{ since_line?: int=0 }` | `{ session_id?, events: [{...}], next_line }` |

The MCP module shares the FTS query code with the main app via a Swift package internal to the project (or a shared sources path in xcodegen — same trick used by the test target). It must NOT pull in AppKit / SwiftUI.

User onboarding affordance: Settings adds a "Copy MCP config" button that copies the Claude-Desktop-format JSON to clipboard:

```json
{
  "mcpServers": {
    "rti": {
      "command": "/Applications/RTI.app/Contents/Resources/rti-mcp",
      "args": ["--corpus", "~/meetings"]
    }
  }
}
```

Single button. No second affordance for Codex / Cursor / etc. — the JSON shape is the same; users adapt as needed.

### One-shot migration

On first launch with this version:

1. Create `~/meetings/` if absent (default location; check user setting first).
2. For every row in legacy `sessions` table:
    - Read its `transcript_entries`, `session_summaries`.
    - Synthesise frontmatter from existing columns.
    - Write `~/meetings/YYYY-MM-DD-<slug>.md`.
    - Mark in a new `migration_log` row (idempotent re-runs).
3. After all sessions are migrated and verified, drop the legacy tables.

Migration is gated behind a one-time `migration_log` check. If interrupted, resumes on next launch from where it stopped.

### Files touched / created

**New (large):**
- `RTI/Sources/Corpus/CorpusEntry.swift` — frontmatter type + YAML codec wrapper (~150 LOC).
- `RTI/Sources/Corpus/MarkdownRenderer.swift` — pure renderer (~200 LOC).
- `RTI/Sources/Corpus/CorpusReader.swift` — directory walker + parser (~150 LOC).
- `RTI/Sources/Corpus/CorpusWriter.swift` — atomic write (~80 LOC).
- `RTI/Sources/Corpus/LiveJSONLWriter.swift` — append-only JSONL stream (~120 LOC).
- `RTI/Sources/Corpus/CorpusFTSReindexer.swift` — walks ~/meetings, populates session_search (~200 LOC).
- `RTI/Sources/Corpus/SpeakerOverlay.swift` + GRDB record (~80 LOC).
- `RTI/MCP/RTIMCPMain.swift` — `@main`, JSON-RPC dispatch (~250 LOC).
- `RTI/MCP/MCPTools.swift` — the four tool implementations (~250 LOC).
- `RTI/MCP/MCPProtocol.swift` — MCP types (~150 LOC).

**Modified:**
- `RTI/Sources/Session/SessionCoordinator.swift` — write to `LiveJSONLWriter` alongside (eventually instead of) writing to `transcript_entries`.
- `RTI/Sources/Session/SessionCoordinator.swift` — on session-end, invoke `MarkdownRenderer`.
- `RTI/Sources/Database/RTIDatabase.swift` — add `speaker_overlays` migration; register `migration_log` table.
- `RTI/Sources/Settings/SettingsView.swift` — add Corpus section (path picker, "Copy MCP config" button, Reindex Corpus action).
- `RTI/project.yml` — add `RTIMCP` target; add `Corpus/` sources to test target where applicable.

**Deleted (post-migration):**
- `RTI/Sources/Database/Models/Session.swift` — superseded by frontmatter.
- `RTI/Sources/Database/Models/TranscriptEntry.swift` — superseded by markdown body.
- `RTI/Sources/Database/Models/SessionSummary.swift` — folded into markdown.
- (Or kept as legacy types only used by the migration code, then deleted in a follow-up.)

### Tests

- `MarkdownRenderer` tests (pure): renders empty session, single-speaker session, note-bearing session, with frontmatter validation by re-parsing the output.
- `CorpusReader.parse(_:)` round-trips frontmatter cleanly: write → read → equal.
- `LiveJSONLWriter` append concurrency test: 100 concurrent appends produce 100 lines, no corruption.
- `CorpusFTSReindexer` test: write 3 markdown files, reindex, search returns expected hits.
- `SpeakerOverlay` apply-at-query test: `them_1` row + global overlay returns "Alex Kim" in search snippet.
- `MCPTools` tests: each tool tested with a fixture corpus directory + in-memory SQLite; assert exact JSON-RPC response shape.

### Success criteria

- Starting and stopping a session produces a valid `~/meetings/YYYY-MM-DD-<slug>.md` file. Frontmatter parseable. Body contains transcript + summary.
- `grep "decision"` across `~/meetings/` returns expected matches.
- `~/meetings/` survives `rm rti.db`; on next launch, FTS index rebuilds from markdown.
- Migrating an existing user's database produces one markdown file per existing session, with no data loss (transcript text + summary text intact).
- `rti-mcp` binary launched with stdio responds to MCP `initialize` + each of the four tool calls correctly, against a fixture corpus.
- Settings → Copy MCP Config produces clipboard JSON that, pasted into Claude Desktop's config, results in a working RTI MCP connection on next Claude restart.
- All `RTITests` continue to pass; new tests for renderer/reader/reindexer all pass.

### Risks

- **Migration data loss** is the highest-risk part. Mitigation: migration writes to `~/meetings/` first, validates that markdown re-parses cleanly, and only *then* registers the migration_log entry. Legacy tables are not dropped until a separate verify step confirms file count matches session row count.
- **JSONL append corruption on crash** during a live session. Mitigation: `LiveJSONLWriter` `fsync`s after every batch (every ~250ms), uses line-oriented append-only writes; recovery code tolerates a partial last line.
- **MCP protocol drift** — hand-rolling JSON-RPC is small but brittle. Mitigation: target a specific MCP protocol version, write protocol tests against published examples, fail loudly on version mismatch in `initialize`.
- **`rti-mcp` codesigning** — the bundled binary needs to be signable as a separate executable inside the .app. xcodegen `tool` target type handles this; verify on first build.
- **User edits during reindex** — the watcher could fire mid-edit. Mitigation: debounce file events by 500ms; reindex re-tries on parse failure.

### Out of scope (deferred)

- Embedding-based semantic search over the Corpus.
- MCP write tools (`write_meeting`, `edit_speaker_map`).
- MCP tools for action items / decisions / participants directly (agents compose from `read_meeting` + frontmatter).
- Brew-tap distribution for `rti-mcp`.
- Cross-corpus operations (merge two RTI vaults, import from minutes).
- Arg-taking palette commands (`Search transcripts: <q>`).
- Menubar refactor onto `CommandRegistry` (incremental as touched).
- Per-mode markdown render templates.

---

## Implementation order (ladder)

1. **Soniox failure classification** + tests.
2. **Command palette** + central registry.
3. **Markdown Corpus phase A** — frontmatter codec, MarkdownRenderer, CorpusReader/Writer, CorpusFTSReindexer, SpeakerOverlay table. Wire SessionCoordinator to write JSONL during live + render markdown on session-end. SQLite still holds legacy tables; both stores are populated dual-write.
4. **Markdown Corpus phase B** — one-shot migration + drop legacy tables. Verify against a snapshot of an existing user database.
5. **`rti-mcp` binary** — new xcodegen target, MCP protocol, four tools, test fixture corpus.
6. **Settings affordances** — Corpus path setting, Copy MCP Config, Reindex Corpus action.

Each phase is independently shippable; phases 3–6 must land in order but can be staged across multiple commits.

---

## Verification at each phase

- **Phase 1 (Soniox):** `xcodebuild ... test` passes; manual: pull network during a live session, observe phase-aware copy.
- **Phase 2 (Palette):** Tests pass; manual: ⌘⇧K opens, fuzzy-find runs, recents persist across launches.
- **Phase 3 (Corpus phase A, dual-write):** Tests pass; manual: start/stop a session; observe `~/meetings/<file>.md` written, frontmatter parses, body matches Debug Console transcript.
- **Phase 4 (Corpus phase B, migration + drop):** Tests pass; manual: copy a real user `rti.db` to a test path, run migration, diff resulting markdown against transcripts in the original DB; only after that, allow legacy table drop.
- **Phase 5 (`rti-mcp`):** Tests pass; manual: run `rti-mcp --corpus ~/meetings` and `echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'` over stdin returns valid response. Then connect from Claude Desktop and run a real query.
- **Phase 6 (Settings):** Manual: changing Corpus path migrates files; Copy MCP Config produces working JSON in clipboard.

---

## Non-goals for this spec

- Replacing Soniox with on-device transcription (Apple Speech / WhisperKit / Parakeet). That was discussed and acknowledged as the bigger snappy win, but it's a separate landing.
- Rewriting `LLMController` or any other DeepSeek consumer beyond what's necessary for chat-message JSONL writes.
- Reworking `OverlayWindowController` or any other window surface.
- Cross-session speaker registry beyond what `speaker_overlays` supports.
- Persisted recents-with-args in the palette.
- Embedding/vector search.
