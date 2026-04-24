# POC-5 — Persistence layer — findings

Stage 2 of the post-POC-3 plan. Adds GRDB persistence for chat messages + modes table, session resume on launch within a 5-minute window, "Clear current chat" action, and a "Recent Sessions" submenu.

## Files

- `RTI/Sources/Database/RTIDatabase.swift` — new migration `v2_chat_and_modes` (additive only): `chat_messages` table (`id`, `session_id` FK→sessions, `role`, `action`, `content`, `had_screen_context`, `had_transcript_context`, `created_at`) + `modes` table (`id`, `name`, `system_prompt`, `is_builtin`, `created_at`). Indexed on (session_id, created_at).
- `RTI/Sources/Database/Models/ChatMessage.swift` — NEW.
- `RTI/Sources/Database/Models/Mode.swift` — NEW (table only used in Stage 4).
- `RTI/Sources/Session/SessionCoordinator.swift`:
  - `bootstrapChatSession()` — at launch, resume the most recent session if it ended (or started, if still open) within `resumeWindowSeconds` (300 s); otherwise create a new chat-only session row with `wav_path = nil`.
  - `launchSession()` — when audio starts, reuse the current chat session by `UPDATE`-ing its `wav_path`, instead of inserting a new row, so transcripts and chat messages share one session.
  - `completeStop()` — no longer clears `currentSessionId` / `startedAt`; chat continues against the same session after audio stops.
  - `recentSessions(limit:)`, `switchToSession(id:)`, `clearCurrentSessionMessages()`.
- `RTI/Sources/LLM/LLMController.swift`:
  - `loadHistoryForCurrentSession()` repopulates `entries` from `chat_messages` ordered by `created_at`.
  - `performSend` writes the user `ChatMessage` immediately and the assistant `ChatMessage` once the stream completes (skipped if assistant text is empty due to error/cancel).
  - `clear()` also calls `clearCurrentSessionMessages()` so the DB and the in-memory list stay in sync.
- `RTI/Sources/AppDelegate.swift`:
  - Calls `bootstrapChatSession()` + `loadHistoryForCurrentSession()` at launch (before installing UI).
  - "Clear Current Chat" menu item.
  - "Recent Sessions" submenu (last 10 by started_at desc; `•` marks the active one). Switching sessions only allowed when audio is not running.

No new SPM deps. Migration is additive — `v1` remains unchanged so existing DBs upgrade in place.

## Build

```
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build
** BUILD SUCCEEDED **
```

## Automated checks (✅ passed)

- [x] Migration `v2_chat_and_modes` defined as a separate registered migration; `v1` unchanged.
- [x] FK `chat_messages.session_id → sessions.id` with `ON DELETE CASCADE`.
- [x] `ChatMessage` and `Mode` map snake_case columns via `CodingKeys`.
- [x] `loadHistoryForCurrentSession` filters out non-user/assistant rows (e.g., future system rows).
- [x] User row persisted before stream begins; assistant row persisted only if streamed text is non-empty.
- [x] Session resume window = 300 s; `bootstrapChatSession` creates a new row past that.
- [x] `launchSession` no longer inserts a duplicate row when the user starts audio on an existing chat session.
- [x] POC-2 transcript flow untouched (only `launchSession` reuse change is in `SessionCoordinator`; transcript insert unchanged).
- [x] POC-3 streaming + Smart toggle unaffected; persistence is a side-effect at end of stream.
- [x] POC-4 screen-context chip is preserved in persisted `had_screen_context` column and re-applied on history reload.

## User-attestation (manual)

| # | Step | Pass? |
|---|------|-------|
| 1 | Fresh launch with empty DB → `sqlite3 ~/Library/Application\ Support/RTI/rti.db "select count(*) from sessions"` returns 1. | [ ] |
| 2 | Send an Ask Anything turn → `select count(*) from chat_messages` returns 2 (user + assistant). | [ ] |
| 3 | Quit and relaunch within 5 min → same `session_id`; previous turns appear in the overlay. | [ ] |
| 4 | Quit and relaunch after >5 min → new session row; overlay starts empty. | [ ] |
| 5 | "Clear Current Chat" empties the overlay AND `select count(*) from chat_messages where session_id=<current>` returns 0. | [ ] |
| 6 | `transcript_entries` count is unchanged after Clear (only chat_messages cleared). | [ ] |
| 7 | "Recent Sessions" submenu lists prior sessions newest-first; clicking one loads its chat history. | [ ] |
| 8 | Start an audio session (⌘⇧R), speak, stop → transcripts are attached to the SAME session as chat (single row in `sessions`). | [ ] |
| 9 | Send a message after stopping audio → still persisted to the same session. | [ ] |
| 10 | After ⌘+H + Ask, the persisted user row has `had_screen_context = 1`; reloading history shows the "Viewed screen" chip again. | [ ] |

## Known limitations (by design for POC-5)

- Recent Sessions submenu rebuilds on `menuWillOpen` (not reactive).
- No retention sweep yet — old sessions are kept indefinitely. Pruning will land in Stage 5 or Stage 4 settings.
- Switching sessions while audio is running is rejected with `NSSound.beep()`; no toast.
- Modes table exists but is unused until Stage 4 wires the selector.
- "Clear Current Chat" is the only Clear surface (menubar). An overlay-local Clear button is deferred to Stage 3 (overlay redesign).
- No multi-turn editing/regeneration.

## Decision gate for Stage 3 (POC-6)

Once user-attestation rows pass, Stage 3 (three-window layout, split-panel overlay, mini widget, multi-display) is unblocked.
