# RTI — Real-Time Intelligence

A menubar-only macOS assistant that listens to the microphone, transcribes in real time, and streams LLM responses over a translucent overlay — without showing up in other apps' screen captures.

> **Status:** Active development. Requires your own Soniox and LLM provider API keys (DeepSeek today; the LLM layer is provider-agnostic — see `Sources/LLM/LLMProvider.swift`). macOS 14+.

## Features

- **Invisible overlay** — borderless `NSPanel` with `sharingType = .none`, so it's excluded from QuickTime / Zoom / `screencapture`.
- **Live transcription** — `AVAudioEngine` tap → 16 kHz PCM → Soniox WebSocket → SQLite + canonical markdown corpus.
- **Streaming assistant** — OpenAI-compatible streaming chat (DeepSeek by default) over SSE, with a rolling 6-minute transcript context.
- **Smart Screenshot** — `⌘H` captures the display under the mouse, runs Vision OCR, and attaches the text to the next assistant turn. The image is discarded.
- **Sessions + chat history** — every turn persisted in GRDB/SQLite; recent-sessions menu; 5-minute resume on relaunch.
- **Modes** — four builtin system-prompt templates (Meeting / Interview / Coding / Custom) with optional per-mode reference text.
- **Sessions Control window** — unified Live Transcript, Sessions, Settings, and Logs tabs.
- **Local credentials** — keys live in `~/Library/Application Support/RTI/credentials.json` (mode 0600), never plaintext in source.
- **Launch at login** — `SMAppService.mainApp`.
- **Markdown Corpus** — every meeting renders to `~/meetings/*.md`. Survives uninstall, queryable via filesystem, exposed to external agents (Claude Desktop, Codex, Gemini CLI, OpenCode) via the bundled `rti-mcp` MCP server.

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
2. Paste your DeepSeek (or other configured LLM provider) API key and Soniox API key. Both are stored locally on this Mac only.
3. Optional: **Settings → Modes** — tailor the system prompt or paste reference text (resume, meeting agenda, code style guide…) into the active mode.
4. Optional: **Settings → General** — toggle *Launch at Login* (requires a properly-signed build; ad-hoc-signed local builds will surface an error).
5. Optional: **Settings → Corpus** — change the `~/meetings/` location, or copy the MCP-server config snippet for Claude Desktop / Codex / Gemini CLI.

## Hotkeys

| Key | Action |
|-----|--------|
| ⌘ \ | Toggle overlay visibility on the active display |
| ⌘ ⇧ R | Start / stop the audio session |
| ⌘ ↵ | "Assist" — ask the LLM what to say next, using recent transcript |
| ⌘ H | Capture the display under the mouse; attach OCR to the next turn |
| ⌘ ⌥ T | Show / hide the Live Transcript window |
| ⌘ K | Toggle the command palette |
| ⌘ ⇧ B | Toggle the top recording-pill widget |

Hotkeys are fixed for this build.

## Switching LLM providers

The LLM client is provider-agnostic. Provider configs live in `RTI/Sources/LLM/LLMProvider.swift` (`LLMProviders` registry). To point at a different OpenAI-compatible endpoint (Moonshot Kimi, OpenAI itself, Together, etc.):

1. Add a new `LLMProviderConfig` entry in `LLMProviders`.
2. Change `LLMProviders.activeId` (a `UserDefaults` key under the hood) to the new provider id.

The wire format is OpenAI-style streaming chat completions (`POST /chat/completions` + SSE). DeepSeek's `thinking` extension is gated on `LLMProviderConfig.supportsThinking`, so non-DeepSeek providers degrade gracefully.

## Data

- **Mic + system audio**: captured locally, streamed to Soniox over WebSocket. WAV is written to `~/Library/Application Support/RTI/audio/` while a session is recording.
- **Screenshots**: captured on demand (`⌘ H`), OCR'd on-device via Vision, sent as text only to the LLM, and **never written to disk**.
- **Transcripts + summaries**: rendered to `~/meetings/<session-id>.md` (configurable). The markdown corpus is canonical; the SQLite index in `~/Library/Application Support/RTI/rti.db` is a derived FTS view that can be rebuilt at any time from Settings → Corpus → Reindex.
- **Chat messages**: stored in `~/Library/Application Support/RTI/rti.db` (GRDB/SQLite).
- **Pruning**: completed sessions older than 30 days are pruned automatically on launch.
- **Crash log**: `~/Library/Application Support/RTI/crash.log`, rotated at 1 MB.

## Project layout

```
RTI/
  project.yml                      # xcodegen source of truth
  Sources/
    RTIApp.swift                   # SwiftUI entry
    AppDelegate.swift              # status item + hotkeys + window state machine
    OverlayWindowController.swift / OverlayPanelView.swift
    GlobalHotkey.swift             # Carbon RegisterEventHotKey
    Secrets.swift                  # Keychain-backed getters, no literals
    Audio/                         # AVAudioEngine tap, WAV writer, system audio (SCStream)
    Soniox/                        # WebSocket realtime + offline file transcribe
    LLM/                           # LLMProvider config + LLMClient + LLMController
    Screenshot/                    # ScreenCaptureKit + Vision OCR
    Database/                      # GRDB pool, migrations, models
    Session/                       # SessionCoordinator + transcript pipeline + Q&A + title + regenerator
    Corpus/                        # Markdown corpus reader/writer + live JSONL + FTS reindexer
    Modes/                         # ModeStore
    Summary/                       # SummaryController
    Calendar/                      # CalendarManager (EventKit)
    Widgets/                       # Top recording pill widget
    Settings/                      # Tabbed Settings, KeychainStore, LaunchAtLogin, Onboarding, Logs
    Support/                       # AppLog, CrashLog, NotificationNames, formatters
    UI/                            # WindowCoordinator, MenuCoordinator, HotkeyCoordinator, design system, all SwiftUI views
  MCP/                             # rti-mcp standalone JSON-RPC server (bundled into Resources)
  Tests/                           # XCTest unit + integration tests
```

## Contributing

Not currently accepting contributions — this is a personal project.

## License

All rights reserved.
