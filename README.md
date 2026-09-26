# RTI — Real-Time Intelligence

A macOS assistant (a regular Dock app with a menu-bar recording indicator, since 2026-09-01) that listens to your meetings, transcribes in real time, and streams answers in a normal titled window that doesn't show up in other apps' screen captures.

Personal build: **real-time first, vault-backed** — the live transcript stays in memory during recording; submitted chats and sources are saved before inference. On stop RTI saves the session's Markdown and retained audio to the vault. Browse saved sessions in RTI, replay their audio, or ask the assistant using vault search. RTI keeps no separate database or search index. macOS 14+. Bring your own [Soniox](https://console.soniox.com) and LLM provider keys ([DeepSeek](https://platform.deepseek.com) by default; the LLM layer is provider-agnostic — see [`Sources/LLM/LLMProvider.swift`](RTI/Sources/LLM/LLMProvider.swift)).

Transcription is not on-device: by default both live legs stream to hosted Soniox, and the automatic transcript upgrade sends the retained audio to Soniox's file API. OCR runs on this Mac; assistant turns go to the selected LLM provider.

RTI's assistant is for meetings and sessions: it reads the live transcript, saved sessions and the vault. General chat, and the Chief of Staff, live in Quick Launch's AI Chat.

Names: this repo is `rti` (GitHub `tristan-mcinnis/rti-personal`). It builds `RTI.app`, bundle id `com.tristan.rti.personal`; the bundle's display name is still "RTI Personal". Two launchd jobs installed outside this repo touch it: `com.tristan.rti-crash-watchdog` (relaunches RTI after a crash) and `com.tristan.rti-meeting-drain` (a vault tool).

## What it does

- **Live transcription.** `AVAudioEngine` → 16 kHz PCM → realtime STT provider, both sides of the call, held in memory with rolling context for the assistant. RTI models realtime STT separately from post-hoc transcript-upgrade providers.
- **Clear recording lifecycle.** The record control names every phase — **Recording → Paused → Saving → Summarizing → Notes ready** — so you always know what RTI is doing. **Pause/resume** (⌘⇧P) suspends transcription while holding the Soniox socket warm, so resume is instant (no re-handshake). On finish you watch the end-of-session summary generate (Granola-style "Summarizing…"), then **start a new recording with one click** — the previous session is saved, not cleared, and the new one can begin even while the last summary is still being written.
- **Streaming assistant, mode-aware.** ⌘↵ runs the primary action over the last few minutes of transcript — **Quick recap** (the last 5 minutes, one or two bullets) out of the box. The quick-action set follows the active mode + listener state: meeting/participant gets Quick recap / Assist / Say next / Follow-ups; fieldwork observer (Interview + Listener) gets Quick recap / Assist / Follow-ups / Key tensions / What's unsaid / Emerging themes. You can also drop an image into the composer. OCR runs on-device; the image goes to the destination shown before Send, which may be a cloud model. OpenAI-compatible streaming chat.
- **Invisible window.** A normal titled `NSWindow` with `sharingType = .none` (toggle in Settings) — excluded from QuickTime, Zoom local recording, and `screencapture`. The old always-on-top translucent panel was dropped on 2026-09-01. Other recorders may still see it; see `RTI/POC1-findings.md` for the verified surface.
- **Sole meeting recorder.** RTI is the only meeting-capture tool on this machine (Meeting Sentinel was deleted 2026-08-28). ⌘⇧R starts and finishes every recording; RTI never auto-records.
- **Real-time analysis tabs.** Optional overlay tabs generate live meeting **Notes**, track coverage of an imported **Discussion Guide**, and collect tagged **Findings** — all held in memory and refreshed on a timer. Toggle each in the **Setup** tab; jump to them with ⌘⌥3 / ⌘⌥4 / ⌘⌥5.
- **Echo cancellation.** Apple Voice-Processing I/O on the mic cancels the other party's voice bleeding from your speakers. **Off by default** (VPIO delivers silent buffers on some Macs, verified 2026-06-09 — silent mic kills transcription); toggle in Settings → General if your setup needs it. The mic is fully released when a session stops, so it won't block other apps.
- **Smart Screenshot.** ⌘⇧H reads the whole screen; ⌘⇧J reads the frontmost window (never RTI's own, never an app on the Screen Privacy list). The capture shows as a thumbnail chip in the composer, is sent to your model as an image, and is kept in the session's `frames/` folder so you can look at it again in the Sessions window. Vision OCR still runs on-device and rides along as text; the local vision model is not used for these captures.
- **Translation.** Optional live translation alongside the transcript (one-way or two-way), in the Live Transcript window.
- **Modes.** Built-in system-prompt templates (Meeting / Interview / Coding / Custom) with optional per-mode reference text. Stored as a small JSON file.

- **Saved sessions.** Rounded document selectors and a readable content column use the shared House design. Play, pause, and seek retained microphone and system audio together. Copy the current document, open the macOS share picker, or move an RTI archive to Trash after confirmation. Deleting an archive leaves canonical meeting notes intact; legacy meeting files cannot be deleted here.
- **House chat controls.** Open attachments with ⌘⇧A and fuzzy-search commands with ⌘K. The attachment menu carries its own search too: it takes the keyboard on open and filters the rows as you type. Pin becomes Unpin when appropriate. Attachments show Reading or an error before sending; a failed read preserves the draft. Images are read on-device and sent to the model when it takes image input, and removed attachments cannot reappear when a late read finishes.

- **Source-first chat.** The Add Context pane's Broader Search row controls the material and retrieval allowed for the turn. A fresh-source question does not silently add earlier attachments; explicit comparisons can use them. Follow-ups reuse retained sources without rereading the original file. The selected image-capable model is preferred, with any fallback labelled before Send. Each answer keeps its own effective route and request record.
- **Keep-all chat library.** Sessions → Chats supports search, pin, rename, resume, export, storage inspection and confirmed deletion. Submitted originals, normalized images and extracted passages stay until explicit deletion; unsent drafts are not archived. Legacy dated logs remain read-only and can seed a new draft without sending it. `/new` and `/clear` reset chat context, not saved history or recording. Unknown slash commands need an explicit Send as Text action.

Configuration lives in Application Support and the credential store. Structured chat threads live under the vault's RTI `chats/threads/` directory; their source and request blobs live in `~/Library/Application Support/RTI/chat-assets/`. Daily and session Markdown are projections, not separate conversation owners. Deleting a thread removes only its identified projection blocks and unshared asset copies, never original files or recording audio. An unreadable owner blocks asset cleanup.

Quick Launch and RTI share extraction and chat schema code, not histories, settings or credentials. Chat retention has no automatic age or count pruning, and adds no cloud sync or automatic source ingestion. Local storage does not imply local inference. Retained recording audio supports playback and **Upgrade Transcript**. See **Where everything goes** below for session paths.

## Where everything goes (data flow)

One config file anchors every path: **`~/.config/rti/config.json`** (`VaultPaths.swift` reads it; `recordings_dir` anchors the vault tree). Change the vault location by editing that one file.

**1. The session archive** — everything a session produced, in one folder:

```
~/vault/kb/databases/projects/personal/rti/sessions/<yyyy-MM-dd HHmmss>/
  transcript.md         # live transcript, Markdown, YAML frontmatter, inline 📝 notes
  chat.md               # assistant chat log (only if you chatted)
  notes.md              # generated live notes (only if enabled + produced)
  discussion-guide.md   # guide coverage (only if a guide was loaded)
  live-intelligence.md  # tagged findings ledger (only if any)
  screen-context.md     # screen trail: OCR + vision summaries + frame refs (only if any)
  frames/               # compressed JPEG frames per capture (local_vision lane; gitignored)
  summary.md            # end-of-session summary (+ title.txt for the browser)
  session.json          # metadata: mode, workstream, duration, audio file names
  speaker-names.json    # your live speaker renames (only if you renamed)
  audio-mic.wav         # THE AUDIO. Mic leg, kept for transcript upgrade
  audio-system.wav      # system-audio leg (the other side of the call)
```

Every `.md` file carries YAML frontmatter (`title`, `type: reference`, `date`, `source: rti`, `workstream:` when a project was picked in Setup, `projects: [rti]`, `tags: [rti]`) so the vault's Neon ingester titles and links it.

**2. The canonical meeting lane** — on finish (and again after the automatic transcript upgrade), RTI exports plain text into the vault's raw-transcript lane:

```
~/vault/kb/databases/meetings/transcripts-raw/
  rti-session-<yyyyMMdd-HHmmss>-transcript.txt    # canonical raw transcript (plain text, no frontmatter)
  rti-session-<yyyyMMdd-HHmmss>-rti.md            # sidecar: summary + notes + findings + chat (frontmatter: source: rti-live)
```

**3. Vault ingestion** — all vault-side, never in the app:

- On session stop RTI fire-and-forgets `~/vault/.claude/tools/triage/route-rti-session.py` (workstream declared → field-notes companion in that project; otherwise the session stays in `rti/sessions/`, searchable and promotable later).
- The `com.tristan.rti-meeting-drain` LaunchAgent (every 30 min) picks up unprocessed `-transcript.txt` files and runs `/meeting` headless: it writes the canonical meeting note at `kb/databases/meetings/YYYYMMDD-<type>-<topic>.md`, folds the `-rti.md` sidecar in as priority signal, and writes a speaker-resolved `-transcript.named.txt` sibling. The raw transcript is never edited.
- The Neon/Hermes ingest watcher indexes the archive's frontmattered Markdown for search.

Legacy files you may still see: `meetings/recordings/rti-<UUID>-mic.m4a` (old RTI builds kept audio there; current builds keep WAV legs in the session folder) and `*.meeting.json` sidecars (Meeting Sentinel era — the Sessions browser still lists them as recorded meetings).

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

1. Launch RTI — it opens as a Dock app with a menu-bar recording indicator.
2. Grant **Microphone**, **System Audio Recording** (the audio-only CoreAudio-tap
   permission; this is the primary system-audio path), and **Screen Recording**
   (SCK fallback + Smart Screenshot) permissions.
3. Paste your **Soniox** and **LLM provider** keys.
4. Start a session: ⌘⇧R. Toggle the overlay: ⌘\\. Ask the assistant: ⌘↵.

## Hotkeys

Source of truth is `RTI/Sources/UI/CommandPalette/CommandPaletteFactory.swift` (fed to the palette, menu, and hotkeys), not this table.

| Key | Action |
|-----|--------|
| ⌘ \\ | Toggle the assistant overlay |
| ⌘ ⇧ R | Start a session / finish it / start a new one (phase-aware) |
| ⌘ ⇧ P | Pause / resume the recording (keeps the connection warm) |
| ⌘ ↵ | Primary action — remappable; defaults to "Quick recap" |
| ⌘ ⌥ S | Say next (one-line draft reply) |
| ⌘ ⌥ F | Follow-up questions |
| ⌘ ⌥ R | Recap so far |
| ⌘ ⌥ M | Session summary (mode-shaped: research debrief in Interview mode, minutes otherwise) |
| ⌘ ⌥ T | Key tensions (listener / fieldwork) |
| ⌘ ⌥ U | What's unsaid / probe (listener / fieldwork) |
| ⌘ ⌥ E | Emerging themes (listener / fieldwork) |
| ⌘ ⌥ N | Toggle Note mode (type inline into the transcript) |
| ⌘ ⇧ H | Read the whole screen; attach OCR to the next prompt |
| ⌘ ⇧ J | Read the frontmost window; attach OCR to the next prompt |
| ⌘ ⇧ A | Open the chat attachment menu |
| ⌘ K | Open the command palette; type to fuzzy-search commands |
| ⌘ ⌥ 0–5 | Jump to a tab — 0 Setup · 1 Assist · 2 Transcript · 3 Notes · 4 Guide · 5 Findings |

The ✦ menu shows the **mode-aware** action set: in a meeting you get Quick recap / Assist / Say next / Follow-ups; sitting in on fieldwork (Interview + Listener) you get Quick recap / Assist / Follow-ups / **Key tensions** / **What's unsaid** / **Emerging themes** instead of "what should I say". You can drop an image onto the composer. OCR runs on-device; the image is sent to the destination shown before Send and retained locally after submission.

## Capturing both sides of a call

Soniox transcribes whatever audio device you select for the mic; system audio (the other party) is captured automatically via a CoreAudio process tap (ScreenCaptureKit fallback). If you prefer an aggregate-device setup, install [BlackHole](https://existential.audio/blackhole/), build an aggregate of your mic + BlackHole in **Audio MIDI Setup**, and pick it under **Settings → General → Audio Input**.

## Real-time vs transcript-upgrade providers

RTI now treats these as separate lanes:

- `Real-time transcription` is the low-latency overlay transcript used during a meeting.
- `Transcript upgrade (async)` is the post-hoc lane that re-transcribes the session-local retained audio legs and then regenerates the summary from the upgraded text. Soniox is the default choice; choose Aliyun from the Upgrade Transcript prompt for Chinese-heavy sessions.

Recommended defaults follow the local `transcribe` skill:

- `Realtime`: Soniox
- `Chinese-heavy async file upgrade`: Aliyun
- `English or mixed-language async file upgrade`: Soniox

For Aliyun async upgrades, RTI tracks the full credential set the file
transcription script actually needs:

- `Aliyun Access Key ID`
- `Aliyun Access Key Secret`
- `Aliyun NLS App Key`

See [docs/transcript-upgrade-providers.md](docs/transcript-upgrade-providers.md).

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
    Session/                       # SessionCoordinator + in-memory transcript pipeline + session archive + VaultPaths
    Modes/                         # ModeStore (JSON-backed prompt presets)
    Analysis/                      # Real-time Notes / Dossiers / Discussion Guide panels (in-memory)
    Widgets/                       # Recording-pill widget
    Settings/                      # Tabbed Settings, CredentialStore, LaunchAtLogin, Logs
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
