# RTI Plan

Staged task list for the POC-by-POC build. Check items off as they land.
Stages are roughly sequential; mark `[x]` when done, `[~]` for in-progress.

---

## Stage 0 — POC-3 polish (before adding more features)

- [x] Move API keys out of `Secrets.swift` plaintext into macOS Keychain (`SecItemAdd`)
- [x] Add first-run Settings sheet to paste + store Kimi / Soniox keys
- [x] Wire a visible Stop button while `streaming == true` (calls `LLMController.cancel()`)
- [x] Persist `smartMode` across app relaunches (UserDefaults)
- [x] Show a subtle "thinking…" state while Smart is on and no deltas have arrived yet
- [x] Handle Kimi 401 (bad key) with a clear error + link to Settings
- [x] Kill the leftover deferred-button hint banner once POC-4/POC-5 wire those actions for real

---

## Stage 1 — POC-4: Smart Screenshot + Vision OCR

- [x] Register ⌘+H global hotkey (Carbon, same pattern as ⌘+\\)
- [x] Integrate `SCScreenshotManager` to capture the active display
- [x] Request Screen Recording permission on first use; handle denial gracefully
- [x] Run Vision `VNRecognizeTextRequest` on the captured image (fast, on-device)
- [x] Attach OCR text as a system message prefix on the next LLM call, discard the image
- [x] Show "Viewed screen" label on the user bubble when screen context was used
- [x] Verify screenshots are excluded from other apps' capture (sharingType=.none check)
- [x] Write POC-4 findings doc + user-attestation table

---

## Stage 2 — POC-5: Persistence layer

- [x] Finalize GRDB schema: `sessions`, `transcript_entries` (exists), `chat_messages`, `modes`
- [x] Migrate `LLMController.entries` to load + persist via GRDB
- [x] Session lifecycle: start new on launch, resume active session on ⌘+\\ if recent
- [x] "Clear" button on overlay wipes current session entries (keeps transcript)
- [x] Session list UI in menubar dropdown (recent N sessions)
- [x] Prune old sessions / transcripts / chat_messages on launch (30-day retention — landed in Stage 5)

---

## Stage 3 — POC-6: Three-window layout

- [x] Split-panel overlay: dark translucent left 60% (right 40% intentionally empty — click-through is free)
- [x] Full-width transparent overlay window (spans left 60% of screen) instead of fixed 420×560 panel
- [x] Top widget window (always-on-top minimal controls)
- [x] Mini widget window (collapsed state)
- [x] Smooth show/hide animations between layouts
- [x] Multi-display handling (overlay on active display, follows mouse at show-time)

---

## Stage 4 — POC-7: Modes, reference files, settings

- [x] Mode selector UI (Meeting / Interview / Coding / Custom) — in Settings tab; top-widget dropdown deferred
- [x] Per-mode system prompt templates stored in GRDB
- [x] Reference file upload (paste resume, notes, etc.) — per-mode `reference_text`, capped 8k chars
- [x] Settings pane: hotkeys (read-only), API keys, launch-at-login, modes — audio device + retention tabs deferred
- [x] Keychain-backed credential storage (already shipped in Stage 0; Secrets.swift confirmed literal-free)
- [x] Launch-at-login toggle (`SMAppService`)

---

## Stage 5 — Release prep

- [~] Code-sign + notarize the app — RELEASE.md documents the full flow; requires user's Developer ID to execute
- [x] Crash reporting (`Support/CrashLog.swift`, `NSSetUncaughtExceptionHandler`, 1 MB rotation)
- [x] README with install + setup (demo GIF still to be recorded)
- [x] Privacy doc: what's captured, what leaves the device, retention policy — `PRIVACY.md`
- [~] Create GitHub release + DMG — scripted in RELEASE.md; final `gh release create` requires user action with signing credentials

---

## Stage 6 — POC-8: Post-session summary & action items

- [ ] AI-generated structured meeting summary after recording stops (sections: Action Items, Key Topics, Decisions, Follow-ups)
- [ ] Action items extraction with speaker-assigned ownership
- [ ] Summary | Transcript | Usage tabbed view in the session detail panel
- [ ] Regenerate summary button (re-prompts LLM with full transcript)
- [ ] Copy summary / Copy transcript clipboard buttons

---

## Stage 7 — POC-9: Post-session Q&A & follow-up

- [ ] "Ask about this session" — contextual LLM Q&A scoped to the session transcript + summary
- [ ] Follow-up email generation from meeting content (paste-able into Mail.app)
- [ ] Session resume — re-open a past session, continue appending transcript + LLM messages
- [ ] Usage tab shows what context was consumed (screenshots taken, reference files attached, mode used)

---

## Stage 8 — POC-10: Session search & archive

- [ ] Full-text search across all sessions (transcripts, summaries, action items, chat messages)
- [ ] Session history browser with sort/filter (date, mode, duration) — replaces menubar-only list
- [ ] Session detail panel opens from search result or history browser
- [ ] Export session as markdown with frontmatter (title, date, mode, action items)

---

## Stage 9 — POC-11: Calendar integration

- [ ] Read system calendar events via EventKit (read-only, permission-gated)
- [ ] Detect active meeting from calendar when recording starts; attach event metadata to session
- [ ] Show calendar event title + attendees in session header
- [ ] Calendar tab in Settings (grant/revoke Calendar permission, link behavior)

---

## Backlog / nice-to-have (not scheduled)

- [ ] System-audio loopback via ScreenCaptureKit (currently mic-only)
- [ ] Multi-language transcription toggle
- [ ] Dark/light overlay theme variants
- [ ] iCloud sync of sessions (opt-in)
