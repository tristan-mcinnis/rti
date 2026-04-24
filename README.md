# RTI — Real-Time Intelligence

A menubar-only macOS assistant that listens to the microphone, transcribes in real time, and streams LLM responses over a translucent overlay — without showing up in other apps' screen captures.

> **Status:** POC series complete through Stage 5 (release prep). Requires your own Soniox and Kimi / Moonshot API keys. macOS 14+.

## Features

- **Invisible overlay** — borderless `NSPanel` with `sharingType = .none`, so it's excluded from QuickTime / Zoom / `screencapture`.
- **Live transcription** — `AVAudioEngine` tap → 16 kHz PCM → Soniox WebSocket → SQLite.
- **Kimi-streamed assistant** — `moonshot-v1-128k` over SSE, with a rolling 6-minute transcript context.
- **Smart Screenshot** — `⌘H` captures the display under the mouse, runs Vision OCR, attaches the text to the next Kimi turn. Image is discarded.
- **Sessions + chat history** — every turn persisted in GRDB/SQLite; recent-sessions menu; 5-minute resume on relaunch.
- **Modes** — four builtin system-prompt templates (Meeting / Interview / Coding / Custom) with optional per-mode reference text.
- **Three-window layout** — left-60% overlay, top-center widget, collapse-to-compass mini widget. All honor multi-display (positioned on the screen under the mouse).
- **Keychain-backed secrets** — no plaintext keys on disk.
- **Launch at login** — `SMAppService.mainApp`.

## Install

Requires Xcode 15+ and [`xcodegen`](https://github.com/yonaskolb/XcodeGen).

```bash
# 1) Generate the Xcode project
cd RTI
xcodegen generate

# 2) Build (Debug)
xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Debug build

# 3) Launch the built app
open ~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app
```

On first launch:
1. Menubar → RTI → **Settings…** → **Keys** tab.
2. Paste your Kimi (Moonshot) API key and Soniox API key. Both are stored in your macOS Keychain.
3. Optional: **Settings → Modes** — tailor the system prompt or paste reference text (resume, meeting agenda, code style guide…) into the active mode.
4. Optional: **Settings → General** — toggle *Launch at Login* (requires a properly-signed build; ad-hoc-signed local builds will surface an error).

## Hotkeys

| Key | Action |
|-----|--------|
| ⌘ \ | Toggle overlay visibility on the active display |
| ⌘ ⇧ R | Start / stop the audio session |
| ⌘ ↵ | "Assist" — ask Kimi what to say next, using recent transcript |
| ⌘ H | Capture the display under the mouse; attach OCR to the next turn |

Hotkeys are fixed for this build.

## Data

- **Mic audio**: captured locally, streamed to Soniox over WebSocket (not persisted in the cloud beyond Soniox's retention).
- **Screenshots**: captured on demand (`⌘ H`), OCR'd on-device via Vision, sent as text to Kimi, and **never written to disk**.
- **Transcripts + chat messages**: stored in `~/Library/Application Support/RTI/rti.db` (GRDB/SQLite). Pruned automatically after 30 days.
- **Crash log**: `~/Library/Application Support/RTI/crash.log`, rotated at 1 MB.

See [PRIVACY.md](./PRIVACY.md) for full details.

## Project layout

```
RTI/
  project.yml                   # xcodegen source of truth
  Sources/
    RTIApp.swift                # AppKit entry
    AppDelegate.swift           # status item + hotkeys + window state machine
    OverlayWindowController.swift / OverlayPanelView.swift
    GlobalHotkey.swift          # Carbon RegisterEventHotKey
    Secrets.swift               # Keychain-backed getters, no literals
    Audio/                      # AVAudioEngine tap, WAV writer
    Soniox/                     # WebSocket + word model
    LLM/                        # Kimi SSE client, LLMController
    Screenshot/                 # ScreenCaptureKit + Vision OCR
    Database/                   # GRDB pool, migrations, models
    Session/                    # SessionCoordinator
    Modes/                      # ModeStore
    Widgets/                    # Top + mini widgets
    Settings/                   # Tabbed Settings, KeychainStore, LaunchAtLogin
    Support/                    # CrashLog
    UI/Overlay/                 # Assistant UI components
    UI/DebugConsole/            # Developer console
```

## Contributing

Not currently accepting contributions — this is a personal POC. See `CLAUDE.md` for the stage-by-stage build history and `PLAN.md` for what's shipped / pending.

## License

All rights reserved.
