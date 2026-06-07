# RTI — Real-Time Intelligence

A menubar-only macOS assistant that listens to your meetings, transcribes in real time, and streams answers over a translucent overlay that doesn't show up in other apps' screen captures.

Personal build: **real-time first, audio never kept** — the live transcript and chat live in memory during the session; on stop RTI saves a plain-Markdown record and discards the audio. No database, no searchable history, no corpus. macOS 14+. Bring your own [Soniox](https://console.soniox.com) and LLM provider keys ([DeepSeek](https://platform.deepseek.com) by default; the LLM layer is provider-agnostic — see [`Sources/LLM/LLMProvider.swift`](RTI/Sources/LLM/LLMProvider.swift)).

## What it does

- **Live transcription.** `AVAudioEngine` → 16 kHz PCM → Soniox WebSocket, both sides of the call, held in memory with rolling context for the assistant.
- **Streaming assistant.** ⌘↵ asks "what should I say next?" using the last few minutes of transcript. Also: say-next, follow-up questions, recap. OpenAI-compatible streaming chat.
- **Invisible overlay.** Borderless `NSPanel` with `sharingType = .none` — excluded from QuickTime, Zoom local recording, and `screencapture`. Other recorders may still see it; see `RTI/POC1-findings.md` for the verified surface.
- **Meeting awareness.** When Meeting Sentinel is recording a meeting outside RTI, a banner offers **Go live** to overlay the assistant on it (and to open the pre-meeting brief, if one was written). RTI never auto-records — you start a live session yourself with ⌘⇧R.
- **Real-time analysis panels.** Optional floating panels generate live meeting **Notes** (⌘⇧N), extract entity **Dossiers** (⌘⇧D), and track coverage of an imported **Discussion Guide** (⌘⇧G) — all held in memory and refreshed on a timer. Toggle each in Settings → General.
- **Echo cancellation.** Apple Voice-Processing I/O on the mic cancels the other party's voice bleeding from your speakers. On by default; toggle in Settings → General. The mic is fully released when a session stops, so it won't block other apps.
- **Smart Screenshot.** ⌘⇧H captures the display under the mouse, runs Vision OCR on-device, attaches the text to your next prompt. The image is discarded.
- **Translation.** Optional live translation alongside the transcript (one-way or two-way), in the Live Transcript window.
- **Modes.** Built-in system-prompt templates (Meeting / Interview / Coding / Custom) with optional per-mode reference text. Stored as a small JSON file.

The only things written to disk are config (API keys in the Keychain-style store, modes in `~/Library/Application Support/RTI/modes.json`) and a write-only Markdown record of each finished session — transcript, chat, and any generated notes/dossiers/guide — under `~/Library/Application Support/RTI/sessions/`. There's no in-app reader for it; you open it in Finder. The WAV is streamed to a temp file while recording and deleted on stop — audio is never kept.

## Build & run

Requires Xcode 16+ (Swift 6 toolchain) and [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd RTI
cp Sources/Secrets.swift.example Sources/Secrets.swift   # first checkout only — gitignored, keyless stub
xcodegen generate
xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app
```

`Secrets.swift` is gitignored and holds no keys — API keys are entered in Settings and stored in the Keychain-style store at runtime. The source tree just won't compile without the file present.

A locally built `.app` is ad-hoc-signed — Gatekeeper requires a right-click → **Open** the first time, and `SMAppService.mainApp` (Launch at Login) won't work on ad-hoc builds. For a signed/notarized DMG on your own machines, see [RELEASE.md](RELEASE.md).

## First run

1. Launch RTI — it runs in the menubar with no Dock icon.
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
| ⌘ ⇧ B | Toggle the recording-pill widget |
| ⌘ ⇧ N | Toggle the Notes panel |
| ⌘ ⇧ D | Toggle the Dossiers panel |
| ⌘ ⇧ G | Toggle the Discussion Guide panel |

## Capturing both sides of a call

Soniox transcribes whatever audio device you select for the mic; system audio (the other party) is captured automatically via a CoreAudio process tap (ScreenCaptureKit fallback). If you prefer an aggregate-device setup, install [BlackHole](https://existential.audio/blackhole/), build an aggregate of your mic + BlackHole in **Audio MIDI Setup**, and pick it under **Settings → General → Audio Input**.

## Switching LLM providers

The LLM client is provider-agnostic. Provider configs live in [`RTI/Sources/LLM/LLMProvider.swift`](RTI/Sources/LLM/LLMProvider.swift) (`LLMProviders` registry). To point at any other OpenAI-compatible endpoint:

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
    Audio/                         # AVAudioEngine tap, WAV writer, system-audio tap/SCK
    Soniox/                        # WebSocket realtime transcription
    LLM/                           # LLMProvider config + LLMClient + LLMController + tools
    Screenshot/                    # ScreenCaptureKit + Vision OCR
    Session/                       # SessionCoordinator + in-memory transcript pipeline + Meeting Sentinel bridge + session archive
    Modes/                         # ModeStore (JSON-backed prompt presets)
    Analysis/                      # Real-time Notes / Dossiers / Discussion Guide panels (in-memory)
    Widgets/                       # Recording-pill widget
    Settings/                      # Tabbed Settings, KeychainStore, LaunchAtLogin, Logs
    Support/                       # AppLog, CrashLog, NotificationNames, formatters
    UI/                            # WindowCoordinator, MenuCoordinator, HotkeyCoordinator, design system, SwiftUI views
  Tests/                           # XCTest unit tests
  POC*-findings.md                 # historical per-POC validation logs (some describe removed features)
```

## Documents

- [RELEASE.md](RELEASE.md) — signed/notarized DMG recipe (for your own machines).
- [`RTI/VERIFY.md`](RTI/VERIFY.md) — manual verification steps for a build.
- [`docs/adr/`](docs/adr/) — architecture decision records (some predate the personal refocus).
- [`RTI/POC*-findings.md`](RTI/) — per-POC validation logs.
