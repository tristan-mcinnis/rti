# RTI — POC-2 Findings

**Date:** 2026-04-24
**Scope:** Audio → Soniox → SQLite pipeline (per `.omc/plans/2026-04-24-rti-poc2-audio-pipeline.md`)

## ⚠️ Paste your Soniox API key before live-transcript tests

Open `RTI/Sources/Secrets.swift` and replace `<paste real key here>` with your real key. `Secrets.swift` is gitignored. Do NOT edit `Secrets.swift.example` — that's the committed template.

```swift
// RTI/Sources/Secrets.swift
enum Secrets {
    static let sonioxAPIKey = "sx_live_..."  // <-- your key
    static let sonioxURL = URL(string: "wss://api.soniox.com/transcribe-websocket")!
}
```

## Automated results (ralph-verified)

| Check | Result | Notes |
|-------|--------|-------|
| `xcodebuild clean build` with GRDB 6.29 + Starscream 4.0.8 resolved | **PASS** | Zero warnings in RTI sources. |
| `plutil -lint RTI/Sources/Info.plist` | **PASS** | `NSMicrophoneUsageDescription` added. |
| `.gitignore` excludes `RTI/Sources/Secrets.swift` | **PASS** | Created at repo root. `Secrets.swift.example` committed as template. |
| POC-1 overlay regression (source identity) | **PASS** | `OverlayWindowController.swift` (53 lines) and `OverlayPanelView.swift` (34 lines) byte-identical to POC-1 final state. Not touched this session. |
| POC-1 overlay regression (screencapture) | **PASS** | App launched, `screencapture -x` produced a file that does not show the overlay (same mechanism as POC-1, unchanged). |
| Launch smoke test | **PASS** | Process runs stable, menubar item present, `⌘+\\` toggle still works, `⌘+Shift+R` registered (no key pressed yet, just wired). |

## User-attestation (requires your Soniox API key)

Run after pasting the key into `Secrets.swift` and rebuilding.

| Check | Result | Notes |
|-------|--------|-------|
| Pressing `⌘+Shift+R` triggers the macOS mic TCC prompt on first run | ☐ | |
| After granting mic, menubar title shows `RTI ●` within 2s | ☐ | |
| "Show Debug Console" opens a 600×800 window with "Recording…" status dot | ☐ | |
| Speaking produces interim words in dim italic within ~500ms | ☐ | |
| Words solidify to final rows within ~2s, colored speaker chip = `self` | ☐ | |
| `afinfo ~/Documents/RTI/sessions/*.wav` reports 16000 Hz, mono, LEI16 | ☐ | |
| SQLite inspection: `sqlite3 ~/Library/Application\ Support/RTI/rti.db "SELECT speaker_id, text, is_final FROM transcript_entries LIMIT 20"` shows rows with speaker_id=self, non-empty text, is_final=1 | ☐ | |
| `⌘+Shift+R` again: menubar drops the dot, debug console shows "Idle" within 1s | ☐ | |
| `sqlite3 ... "SELECT ended_at FROM sessions"` — last row has non-null `ended_at` | ☐ | |
| Wi-Fi cycle mid-session: see `[RTI] SonioxClient: reconnect attempt N` in Console.app; transcript resumes on reconnect | ☐ | |

## Anomalies / surprises

_(Fill in during manual testing.)_

- …

## Known limitations (by design for POC-2)

- Mic-only. System-audio loopback via `ScreenCaptureKit` is a later POC — speaker diarization is wired but in practice only `self` will appear.
- Only `is_final` words are persisted to SQLite. Interim words live in memory only. This avoids UPSERT churn and is cheaper; a later POC may change this if we want playable interim history.
- No session list UI, no copy-transcript, no export.
- Debug console window is NOT excluded from screen capture (deliberate — it's a dev tool).
- Soniox config uses `model: "precision"` and English-only language hints. Change in `SonioxProtocol.swift` → `SonioxConfigMessage.default()` if you need something else.
- Reconnect gives up after 5 retries. Surfacing that condition to the UI is a future polish item — for POC-2 it just logs.
- WAV rotation/retention: not implemented. `~/Documents/RTI/sessions/` grows unbounded. Clean up manually for now.
- GlobalHotkey was refactored to support multi-registration (POC-1 only used one). The extension is additive — POC-1 hotkey registration still works.

## Decision gate for POC-3

POC-3 (Kimi LLM + overlay integration) can start once the user-attestation rows above are confirmed green. The key unknown is whether the Soniox config schema matches current reality — if the WebSocket immediately errors on connect, check `SonioxProtocol.swift` against Soniox docs for drift.

If the transcription works but the quality is off (wrong speaker labels in a multi-speaker test, garbled audio), the fix is almost certainly in `AudioCaptureManager.handleInputBuffer` — the `AVAudioConverter` ratio math is the likely suspect.

## Files created in POC-2

```
.gitignore
RTI/project.yml                                 (UPDATED)
RTI/Sources/Info.plist                          (UPDATED — mic permission)
RTI/Sources/AppDelegate.swift                   (UPDATED — menu, hotkey, coordinator)
RTI/Sources/GlobalHotkey.swift                  (UPDATED — multi-register support)
RTI/Sources/Secrets.swift                       (NEW, gitignored)
RTI/Sources/Secrets.swift.example               (NEW, committed)
RTI/Sources/Database/RTIDatabase.swift
RTI/Sources/Database/Models/Session.swift
RTI/Sources/Database/Models/TranscriptEntry.swift
RTI/Sources/Audio/AudioCaptureManager.swift
RTI/Sources/Audio/WAVWriter.swift
RTI/Sources/Soniox/SonioxClient.swift
RTI/Sources/Soniox/SonioxProtocol.swift
RTI/Sources/Session/SessionCoordinator.swift
RTI/Sources/UI/DebugConsole/DebugConsoleWindowController.swift
RTI/Sources/UI/DebugConsole/DebugConsoleView.swift
RTI/Sources/UI/DebugConsole/TranscriptRowView.swift
```

POC-1 files (OverlayWindowController.swift, OverlayPanelView.swift, RTIApp.swift) were NOT modified.
