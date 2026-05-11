# RTI — Real-Time Intelligence

A menubar-only macOS assistant that listens to your meetings, transcribes in real time, and streams answers over a translucent overlay that doesn't show up in other apps' screen captures.

> **Status:** Active development. macOS 14+. Bring your own [Soniox](https://console.soniox.com) and LLM provider keys ([DeepSeek](https://platform.deepseek.com) by default; the LLM layer is provider-agnostic — see [`Sources/LLM/LLMProvider.swift`](RTI/Sources/LLM/LLMProvider.swift)).

## What it does

- **Live transcription.** `AVAudioEngine` → 16 kHz PCM → Soniox WebSocket → markdown + SQLite, with rolling context for the assistant.
- **Streaming assistant.** ⌘↵ asks "what should I say next?" using the last few minutes of transcript. OpenAI-compatible streaming chat.
- **Invisible overlay.** Borderless `NSPanel` with `sharingType = .none` — excluded from QuickTime, Zoom local recording, and `screencapture`. Other recorders may still see it; see `RTI/POC1-findings.md` for the verified surface.
- **Smart Screenshot.** ⌘⇧H captures the display under the mouse, runs Vision OCR on-device, attaches the text to your next prompt. The image is discarded.
- **Sessions + history.** Every session persists as a markdown file in `~/meetings/` (canonical) plus an FTS-indexed SQLite database (rebuildable from corpus at any time).
- **Ask Your Corpus.** A first-class cross-session Q&A surface inside the Sessions Control window. Retrieval-augmented (SQLite FTS5 top-6 + the 4 most-recent sessions, capped at 8) → single streaming LLM call with `[Session Title]` citations that jump to the source session. Multi-turn memory, copy / export to markdown, persistent chat history.
- **Drag-to-import.** Drop one or many audio / video files — or a folder — onto the Session History view and RTI transcribes each via Soniox file-mode and creates a session.
- **Live panels (chat-spawned).** Ask the overlay LLM to *"count every time someone says 'Maserati'"* or *"every 2 minutes, summarize the decisions"* and a floating counter or periodic-card window appears (see `RTI/Sources/Panels/`).
- **Modes.** Four built-in system-prompt templates (Meeting / Interview / Coding / Custom) with optional per-mode reference text — paste a resume, agenda, or code-style guide.
- **MCP server.** A bundled `rti-mcp` JSON-RPC binary exposes the markdown corpus to Claude Desktop / Codex / Gemini CLI / OpenCode.

## Privacy

Audio goes to Soniox; transcripts and prompts go to your LLM provider. Everything else stays on this Mac. See [PRIVACY.md](PRIVACY.md) for the full breakdown.

## Install

### Option A — pre-built `.dmg` (signed, notarized)

Grab the latest release at <https://github.com/tristan-mcinnis/rti/releases>, double-click the `.dmg`, drag `RTI.app` to `/Applications`. macOS Gatekeeper will accept it without warnings.

### Option B — build from source

Requires Xcode 15+ and [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/tristan-mcinnis/rti.git
cd rti/RTI
xcodegen generate
xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app
```

A locally built `.app` is ad-hoc-signed — Gatekeeper will require a right-click → **Open** the first time. `SMAppService.mainApp` (Launch at Login) will not work on ad-hoc builds; either skip that toggle or use a signed release build (see [DISTRIBUTING.md](DISTRIBUTING.md)).

## First run

1. Menubar → RTI → **Welcome…** (or just launch the app — onboarding shows automatically).
2. Grant **Microphone** and **Screen Recording** permissions.
3. Paste your **Soniox** and **LLM provider** keys.
4. Start a session: ⌘⇧R. Toggle the overlay: ⌘\\. Ask the assistant: ⌘↵.

## Hotkeys

| Key | Action |
|-----|--------|
| ⌘ \\ | Toggle the assistant overlay |
| ⌘ ⇧ R | Start / stop a recording session |
| ⌘ ↵ | "Assist" — ask the LLM what to say next |
| ⌘ ⇧ H | Capture the display under the mouse; attach OCR to the next prompt |
| ⌘ ⌥ T | Toggle the Live Transcript window |
| ⌘ K | Toggle the command palette |
| ⌘ ⇧ B | Toggle the recording-pill widget |

Hotkeys are fixed for this build.

## Capturing both sides of a call

Soniox transcribes whatever audio device you select. To record both your mic and the audio coming *out* of your Mac, install [BlackHole](https://existential.audio/blackhole/), use **Audio MIDI Setup** to build an aggregate device combining your microphone + BlackHole, then pick that aggregate under **Settings → General → Audio Input**.

The onboarding tour walks you through this.

## Switching LLM providers

The LLM client is provider-agnostic. Provider configs live in [`RTI/Sources/LLM/LLMProvider.swift`](RTI/Sources/LLM/LLMProvider.swift) (`LLMProviders` registry). To point at any other OpenAI-compatible endpoint (Moonshot Kimi, OpenAI, Anthropic via a proxy, Together, a local Ollama, …):

1. Add a new `LLMProviderConfig` entry in `LLMProviders`.
2. Change `LLMProviders.activeId` to the new provider id.

## Project layout

```
RTI/
  project.yml                      # xcodegen source of truth
  Sources/
    RTIApp.swift                   # SwiftUI entry
    AppDelegate.swift              # status item + hotkey + window state machine
    OverlayWindowController.swift  # the invisible panel
    GlobalHotkey.swift             # Carbon RegisterEventHotKey wrapper
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
    Widgets/                       # Recording-pill widget
    Settings/                      # Tabbed Settings, KeychainStore, LaunchAtLogin, Onboarding, Logs
    Support/                       # AppLog, CrashLog, NotificationNames, formatters
    UI/                            # WindowCoordinator, MenuCoordinator, HotkeyCoordinator, design system, all SwiftUI views
  MCP/                             # rti-mcp standalone JSON-RPC server (bundled into Resources)
  Tests/                           # XCTest unit + integration tests
  POC*-findings.md                 # historical per-POC validation logs (1–7) — the closest thing to a spec
```

## Documents

- [PRIVACY.md](PRIVACY.md) — what leaves your Mac, what stays.
- [DISTRIBUTING.md](DISTRIBUTING.md) — how to cut a signed, notarized `.dmg` (with what *you* personally need to do, in plain English).
- [RELEASE.md](RELEASE.md) — the technical release recipe.
- [`RTI/VERIFY.md`](RTI/VERIFY.md) — manual verification steps for a build.
- [`docs/adr/`](docs/adr/) — architecture decision records.
- [`RTI/POC*-findings.md`](RTI/) — per-POC validation logs.

## Contributing

Issues and PRs welcome. Please open an issue first for non-trivial changes — this is a hobby project and design decisions move slowly. There is no spec; the closest thing is the `POC*-findings.md` files plus the current code.

## License

MIT — see [LICENSE](LICENSE).
