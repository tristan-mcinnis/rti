# POC-4 — Smart Screenshot + Vision OCR — findings

Stage 1 of the post-POC-3 plan. Adds ⌘+H global hotkey → ScreenCaptureKit display capture → Vision OCR → text attached as a system message to the next Kimi turn. Image bytes are discarded after OCR.

## Files

- `RTI/Sources/Screenshot/ScreenshotManager.swift` — NEW. Captures the display under the mouse via `SCScreenshotManager.captureImage`, picks the right `SCDisplay` by mouse location, hands the `CGImage` to OCR, sets `LLMController.pendingScreenContext`. Image is dropped at the end of the function scope (not stored).
- `RTI/Sources/Screenshot/OCRService.swift` — NEW. `VNRecognizeTextRequest` (accurate, language-corrected), reading-order sort (top→bottom, left→right).
- `RTI/Sources/LLM/LLMController.swift` — `pendingScreenContext: String?`, `attachScreenContext(_:)`, `setScreenAttachError(_:)`. `performSend` consumes the context, prepends a dedicated system message, and stamps `screenContextUsed=true` on the user `ChatEntry`.
- `RTI/Sources/UI/Overlay/ResponseView.swift` — extra "Viewed screen" chip on user bubbles when OCR context was attached.
- `RTI/Sources/AppDelegate.swift` — third Carbon hotkey: `kVK_ANSI_H` + `cmdKey` → `ScreenshotManager.shared.captureAndAttach()`.

No new SPM deps. No edits to POC-2 files.

## Build

```
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build
** BUILD SUCCEEDED **
```

## Automated checks (✅ passed)

- [x] Build succeeds (Debug).
- [x] `ScreenshotManager` is `@MainActor`; OCR runs off-main on `userInitiated` queue, returns via `withCheckedThrowingContinuation`.
- [x] No new SPM deps (Vision and ScreenCaptureKit are system frameworks).
- [x] OCR text truncated to 12k chars before reaching the LLM.
- [x] Image data is not persisted: the `CGImage` only lives inside `captureActiveDisplay` and is consumed by `OCRService.recognizeText` then dropped.
- [x] POC-1 overlay sharing config is unchanged (no `OverlayWindowController` edits in this stage).
- [x] POC-2 files unchanged.
- [x] POC-3 single-source-of-truth `KimiClient` / `LLMController.performSend` shape preserved; new system message inserts before the user message in the same request.

## User-attestation (manual)

| # | Step | Pass? |
|---|------|-------|
| 1 | Launch RTI; first ⌘+H from any app prompts macOS for **Screen Recording permission** (System Settings → Privacy & Security → Screen Recording). | [ ] |
| 2 | After granting + relaunch, ⌘+H captures within ~1 s; no app hang. | [ ] |
| 3 | After ⌘+H, the *next* submission (Ask Anything text or ⌘+Enter Assist) shows a "Viewed screen" chip on the user bubble. | [ ] |
| 4 | The assistant's reply references something visible on screen (e.g. open URL, headline, code line). | [ ] |
| 5 | A second ⌘+Enter without another ⌘+H does **not** show the chip — context is one-shot and consumed. | [ ] |
| 6 | `screencapture -x /tmp/rti.png` while the overlay is visible: overlay is **excluded** from the resulting PNG (POC-1 regression). | [ ] |
| 7 | POC-2 transcription still streams when ⌘⇧R starts a session and you speak. | [ ] |
| 8 | POC-3 Ask Anything still streams normally when no screen context is attached. | [ ] |

## Known limitations (by design for POC-4)

- The captured screen is the one **under the mouse cursor**, not the focused window. This matches the cluely behavior and avoids picking up a stale display.
- OCR is text-only — no layout boxes, no images-of-images understanding. Vision-language LLM is deferred (would need Kimi/multimodal endpoint).
- "Viewed screen" chip is the only UI signal; there's no preview of the OCR text. Add a peek in POC-7 Settings if useful.
- 12k-char truncation is silent except for an inline `…[truncated]` marker.
- Error toast surfaces in the overlay's `lastError` slot; same surface as Kimi 401, so consecutive errors overwrite each other. Acceptable for POC.

## Decision gate for Stage 2 (POC-5)

Once user-attestation rows pass, Stage 2 (persistence layer — `sessions`, `chat_messages`, `modes`) is unblocked.
