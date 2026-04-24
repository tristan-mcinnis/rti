# RTI — POC-3 Findings

**Date:** 2026-04-24
**Scope:** Kimi LLM integration + overlay becomes the assistant UI (per `.omc/plans/2026-04-24-rti-poc3-kimi-overlay.md`)

## ⚠️ Paste your Kimi API key before live LLM tests

Open `RTI/Sources/Secrets.swift` and replace the `kimiAPIKey` placeholder with your real key:

```swift
// RTI/Sources/Secrets.swift
enum Secrets {
    static let sonioxAPIKey = "..."           // your existing Soniox key
    static let kimiAPIKey = "sk-..."          // <-- paste your Kimi / Moonshot key here
    static let kimiBaseURL = URL(string: "https://api.moonshot.cn/v1")!
}
```

`Secrets.swift` is gitignored. Do NOT edit `Secrets.swift.example` (committed template).

## Automated results (ralph-verified)

| Check | Result | Notes |
|-------|--------|-------|
| `xcodebuild clean build` | **PASS** | Zero errors. One pre-existing warning in `SessionCoordinator.swift` (POC-2) about an `await` on a non-async main-actor hop — not touched under POC-2 contract, will be cleaned up in a POC-2 hygiene pass. |
| POC-1 regression — overlay still `sharingType=.none` | **PASS** | `OverlayWindowController.swift` flags unchanged. Only size constant modified (420×560 → 658×555) per plan. `screencapture -x` with overlay visible produces a file that does not include it (verified by construction + by capture). |
| POC-1 regression — top widget also excluded | **PASS** | `TopWidgetWindowController.swift` also sets `sharingType = .none`. |
| POC-2 contract — protected files byte-identical | **PASS** | `SessionCoordinator.swift`, `SonioxClient.swift`, `SonioxProtocol.swift`, `AudioCaptureManager.swift`, `WAVWriter.swift`, `RTIDatabase.swift`, `Session.swift`, `TranscriptEntry.swift`, all `UI/DebugConsole/*.swift` — untouched. |
| Launch smoke — two windows + menubar | **PASS** | Process launches, stays alive, menubar RTI item present, overlay at top-left, top widget pill at top-center. |
| Deferred buttons — no network | **PASS** | "What should I say?", "Follow-up questions", "Recap" render as clickable buttons; clicking shows inline hint `— POC-3 only wires Assist + Ask Anything.`. No Kimi request triggered. (Verify via Console.app / `/tmp/rti.log` — no KimiClient lines.) |

## User-attestation (requires your Kimi API key)

Run after pasting the key and rebuilding. Commands below assume launch via the command-line path used in earlier POCs; `open RTI.app` works too.

```bash
pkill -x RTI 2>/dev/null
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app
```

| Check | Result | Notes |
|-------|--------|-------|
| Overlay shows 658×555 panel with 4 prompt buttons row, response area, input field, Smart pill, send button | ☐ | |
| Top widget pill visible top-center with compass / Hide / Stop | ☐ | Stop is dimmed when no session running |
| Clicking the input, typing "hello, who are you?", Enter → Kimi response streams in (first token within ~3s) | ☐ | |
| Response renders as plain text (no markdown artifacts like **bold** or # headings) | ☐ | System prompt asks for plain text |
| Pressing `⌘+↩` (Enter) from ANY frontmost app fires Assist | ☐ | |
| Start a session (⌘+Shift+R), speak, then press ⌘+Enter → response references what you said (last 6 min injected as context) | ☐ | |
| Clicking "What should I say?" / "Follow-up questions" / "Recap" shows inline hint and makes NO network call | ☐ | |
| Hide button on top widget hides overlay; click again or ⌘+\\ restores | ☐ | |
| Stop button on top widget stops the current session; dimmed when no session | ☐ | |
| ⌘+\\ still toggles overlay (POC-1) | ☐ | |
| Session start/stop + transcript still lands in SQLite (POC-2) | ☐ | |

## Anomalies / surprises

_(Fill in during manual testing.)_

- …

## Known limitations (by design for POC-3)

- Only Ask Anything + Assist are functional. The other three prompt shapes require distinct system prompts and transcript-context formatting — deferred to a later POC.
- Smart toggle is visual-only (POC-3 uses a single hardcoded system prompt).
- `…` (more) icon is visual-only.
- Compass icon on the top widget is visual-only.
- Response is plain text. Markdown rendering (lists, bold, code blocks) is deferred.
- No conversation history / multi-turn threading. Each submission is one-shot.
- Transcript-context window hardcoded at 6 minutes in `LLMController.contextWindowSeconds`.
- No "thinking…" indicator beyond the ▍ caret shown while streaming.
- Kimi request does not yet pass screenshots or OCR — that's POC-4.
- `⌘+Enter` captures Enter from any frontmost app; no fallback to regular Enter behavior in other contexts during the hotkey press. Expected Carbon behavior.

## Files created in POC-3

```
RTI/Sources/Secrets.swift                             (UPDATED — kimiAPIKey + kimiBaseURL)
RTI/Sources/Secrets.swift.example                     (UPDATED — mirror)
RTI/Sources/OverlayWindowController.swift             (UPDATED — size 658×555 only)
RTI/Sources/OverlayPanelView.swift                    (REWRITTEN — assistant UI)
RTI/Sources/AppDelegate.swift                         (UPDATED — top widget, ⌘+Enter, toggle menu item)
RTI/Sources/LLM/KimiProtocol.swift                    (NEW)
RTI/Sources/LLM/KimiClient.swift                      (NEW)
RTI/Sources/LLM/LLMController.swift                   (NEW)
RTI/Sources/Widgets/TopWidgetWindowController.swift   (NEW)
RTI/Sources/Widgets/TopWidgetView.swift               (NEW)
RTI/Sources/UI/Overlay/PromptActionRow.swift          (NEW)
RTI/Sources/UI/Overlay/ResponseView.swift             (NEW)
RTI/Sources/UI/Overlay/AssistantInputView.swift       (NEW)
RTI/POC3-findings.md                                  (NEW)
```

POC-2 files (Session/, Soniox/, Audio/, Database/, UI/DebugConsole/) NOT modified.
POC-1 `RTIApp.swift` NOT modified. `GlobalHotkey.swift` NOT modified (already multi-register capable).

## Decision gate for POC-4

POC-4 (Smart Screenshot via `⌘+H` → `SCScreenshotManager` capture → Vision OCR → attach to next Kimi call) can start once the user-attestation rows above pass green. If the Kimi request schema needs tweaks (moonshot vs openai field differences surface), iterate in `KimiClient.swift` — the structure is already aligned with the OpenAI Chat Completions streaming spec which Kimi claims compatibility with.
