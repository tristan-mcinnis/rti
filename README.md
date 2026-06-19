# RTI — Real-Time Intelligence

A menubar-only macOS assistant that listens to your meetings, transcribes in real time, and streams answers over a translucent overlay that doesn't show up in other apps' screen captures.

Personal build: **real-time first, audio never kept** — the live transcript and chat live in memory during the session; on stop RTI saves a plain-Markdown record and discards the audio. No database, no searchable history, no corpus. macOS 14+. Bring your own [Soniox](https://console.soniox.com) and LLM provider keys ([DeepSeek](https://platform.deepseek.com) by default; the LLM layer is provider-agnostic — see [`Sources/LLM/LLMProvider.swift`](RTI/Sources/LLM/LLMProvider.swift)).

## What it does

- **Live transcription.** `AVAudioEngine` → 16 kHz PCM → Soniox WebSocket, both sides of the call, held in memory with rolling context for the assistant.
- **Clear recording lifecycle.** The record control names every phase — **Recording → Paused → Saving → Summarizing → Notes ready** — so you always know what RTI is doing. **Pause/resume** (⌘⇧P) suspends transcription while holding the Soniox socket warm, so resume is instant (no re-handshake). On finish you watch the end-of-session summary generate (Granola-style "Summarizing…"), then **start a new recording with one click** — the previous session is saved, not cleared, and the new one can begin even while the last summary is still being written.
- **Streaming assistant, mode-aware.** ⌘↵ runs the primary action over the last few minutes of transcript. The quick-action set follows the active mode + listener state: meeting/participant gets Assist / Say next / Follow-ups; fieldwork observer (Interview + Listener) gets Assist / Follow-ups / Key tensions / What's unsaid / Emerging themes. You can also drop an image into the composer (on-device OCR → text). OpenAI-compatible streaming chat.
- **Invisible overlay.** Borderless `NSPanel` with `sharingType = .none` — excluded from QuickTime, Zoom local recording, and `screencapture`. Other recorders may still see it; see `RTI/POC1-findings.md` for the verified surface.
- **Meeting awareness.** When Meeting Sentinel is recording a meeting outside RTI, a banner offers **Go live** to overlay the assistant on it (and to open the pre-meeting brief, if one was written). RTI never auto-records — you start a live session yourself with ⌘⇧R.
- **Real-time analysis tabs.** Optional overlay tabs generate live meeting **Notes**, track coverage of an imported **Discussion Guide**, and collect tagged **Findings** — all held in memory and refreshed on a timer. Toggle each in the **Setup** tab; jump to them with ⌘⌥3 / ⌘⌥4 / ⌘⌥5.
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

Source of truth is `RTI/Sources/UI/CommandPalette/CommandPaletteFactory.swift` (fed to the palette, menu, and hotkeys), not this table.

| Key | Action |
|-----|--------|
| ⌘ \\ | Toggle the assistant overlay |
| ⌘ ⇧ R | Start a session / finish it / start a new one (phase-aware) |
| ⌘ ⇧ P | Pause / resume the recording (keeps the connection warm) |
| ⌘ ↵ | Primary action — remappable; defaults to "Assist" |
| ⌘ ⌥ S | Say next (one-line draft reply) |
| ⌘ ⌥ F | Follow-up questions |
| ⌘ ⌥ R | Recap so far |
| ⌘ ⌥ M | Session summary (mode-shaped: research debrief in Interview mode, minutes otherwise) |
| ⌘ ⌥ T | Key tensions (listener / fieldwork) |
| ⌘ ⌥ U | What's unsaid / probe (listener / fieldwork) |
| ⌘ ⌥ E | Emerging themes (listener / fieldwork) |
| ⌘ ⌥ N | Toggle Note mode (type inline into the transcript) |
| ⌘ ⇧ H | Capture the display under the cursor; attach OCR to the next prompt |
| ⌘ ⌥ 0–5 | Jump to a tab — 0 Setup · 1 Assist · 2 Transcript · 3 Notes · 4 Guide · 5 Findings |

The ✦ menu shows the **mode-aware** action set: in a meeting you get Assist / Say next / Follow-ups; sitting in on fieldwork (Interview + Listener) you get Assist / Follow-ups / **Key tensions** / **What's unsaid** / **Emerging themes** instead of "what should I say". You can drop an image onto the composer — it's OCR'd on-device and attached as text (no image is sent to the model).

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
