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
- [ ] Prune old screenshots / temp data on launch (30-day retention) — deferred to Stage 5

---

## Stage 3 — POC-6: Three-window layout

- [ ] Split-panel overlay: dark translucent left 60%, hit-test-disabled right 40%
- [ ] Full-width transparent overlay window (spans screen) instead of fixed 420×560 panel
- [ ] Top widget window (always-on-top minimal controls)
- [ ] Mini widget window (collapsed state)
- [ ] Smooth show/hide animations between layouts
- [ ] Multi-display handling (overlay on active display, follow mouse / key window)

---

## Stage 4 — POC-7: Modes, reference files, settings

- [ ] Mode selector UI (Meeting / Interview / Coding / Custom)
- [ ] Per-mode system prompt templates stored in GRDB
- [ ] Reference file upload (paste resume, notes, etc.) — indexed locally
- [ ] Settings pane: hotkeys, audio device, display, retention, API keys
- [ ] Keychain-backed credential storage (completes Stage 0 migration if deferred)
- [ ] Launch-at-login toggle (`SMAppService`)

---

## Stage 5 — Release prep

- [ ] Code-sign + notarize the app
- [ ] Crash reporting (simple local log rotation, no third-party SDK for v1)
- [ ] README with install + setup + demo GIF
- [ ] Privacy doc: what's captured, what leaves the device, retention policy
- [ ] Create GitHub release + DMG

---

## Backlog / nice-to-have (not scheduled)

- [ ] System-audio loopback via ScreenCaptureKit (currently mic-only)
- [ ] Multi-language transcription toggle
- [ ] Export session as markdown
- [ ] Dark/light overlay theme variants
- [ ] iCloud sync of sessions (opt-in)
