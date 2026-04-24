# RTI — POC-1 Findings

**Date:** 2026-04-24
**Scope:** Minimum Viable Invisible Overlay (per `.omc/plans/2026-04-24-rti-poc1-overlay.md`)

## Automated results (ralph-verified)

| Check | Result | Notes |
|-------|--------|-------|
| `xcodebuild build` (Debug, macOS 14+, arm64) | **PASS** | Zero warnings in RTI sources. Built artifact at `~/Library/Developer/Xcode/DerivedData/RTI-.../Build/Products/Debug/RTI.app`. |
| Bundle metadata | **PASS** | `LSUIElement=true`, `CFBundleIdentifier=com.tristan.rti`, `LSMinimumSystemVersion=14.0`, Mach-O arm64. |
| Launch smoke test | **PASS** | Process starts, runs steadily at ~80MB RSS, terminates cleanly on AppleScript quit. |
| `screencapture -x` CLI exclusion | **PASS** | Captured image with overlay on-screen; overlay was absent from the capture. `NSWindow.sharingType = .none` works against the CLI capture path. |

## User-attestation results (fill in)

These require interactive testing on your Mac — ralph cannot automate them. See `RTI/VERIFY.md` for exact steps.

| Check | Result | Notes |
|-------|--------|-------|
| Visual launch — overlay appears at top-left, ~420×560, dark translucent | ☐ PASS / ☐ FAIL | |
| Menubar status item present with Toggle + Quit | ☐ PASS / ☐ FAIL | |
| `⌘+\` global hotkey toggles overlay from ANY frontmost app | ☐ PASS / ☐ FAIL | |
| Overlay stays on top when other apps are clicked (no focus steal) | ☐ PASS / ☐ FAIL | |
| Overlay follows Space switch (Ctrl+→ / Ctrl+←) | ☐ PASS / ☐ FAIL | |
| QuickTime screen recording playback — overlay NOT in recording | ☐ PASS / ☐ FAIL | **Critical — load-bearing test** |
| Zoom "Share Screen" to another device — overlay NOT visible to viewer | ☐ PASS / ☐ FAIL | **Critical — load-bearing test** |
| macOS built-in Screenshot (⌘+Shift+5) — overlay NOT captured | ☐ PASS / ☐ FAIL | |
| `⌘+Q` via menubar menu quits cleanly (no zombie process) | ☐ PASS / ☐ FAIL | |

## Anomalies / surprises

_(Fill in during manual testing — known quirks, unexpected behaviors, things to revisit.)_

- ...

## Known non-issues (by design for POC-1)

- No full-screen split-panel overlay yet. Current panel is a fixed 420×560 rectangle at top-left. Full 60/40 click-through layout is deferred to a later POC.
- No top widget, no mini widget. Only one NSPanel exists.
- Overlay is movable by drag (`isMovableByWindowBackground = true`) for convenience during POC testing. Real product may want a dedicated drag handle.
- No persistence of window position across launches. Deferred.
- `backdrop filter` and `ultraThinMaterial` rendering depends on what is behind the window — looks best over busy content, less dramatic over solid backgrounds. Acceptable for POC.
- No dark/light mode switching — panel is styled for dark content only.

## Decision gate

If all "critical" user-attestation checks pass (QuickTime, Zoom), POC-1 is **approved** and the next POC (audio pipeline → Soniox → SQLite) can start.

If either critical check fails, **do not proceed to POC-2**. The undetectability premise is the product; investigate before building anything on top.

## Next POC (proposed)

**POC-2: Audio → Soniox → SQLite transcript pipeline**
- AVAudioEngine mic tap at 16kHz mono
- Starscream WebSocket to Soniox (keys to be moved into Keychain — not in POC code)
- Interim/final word handling, speaker diarization
- GRDB write to a `transcript_entries` table
- Debug console window (separate NSWindow) showing the live transcript
- No UI integration with the overlay yet — that's POC-3 when we hook the LLM up

Each POC gets its own `/plan` session.
