# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions below.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

This file also provides project-specific guidance to Claude Code (claude.ai/code) when working with this repository.

## Project identity

**Project name:** RTI (Real Time Intelligence). The repo directory is still `cluely-clone/` for historical reasons but the product is **RTI**, not a clone — do not use the "Cluely" name in new code, UI copy, bundle identifiers, or docs. Original Cluely research is reference only.

## Repository status

The repo is in **POC-by-POC rebuild mode**. The previous monolithic implementation attempt was archived; the current active build is a minimum viable overlay proof-of-concept. Each product element (overlay, audio, LLM, screenshot, persistence, widgets, modes) is being built and validated in isolation before the next one starts.

Layout:

- `RTI/` — **active Xcode project.** Generated via `xcodegen` from `RTI/project.yml`. Build with `xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build`. Runtime artifact at `~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app`. Bundle id `com.tristan.rti`, macOS 14+, menubar-accessory app (`LSUIElement=YES`).
- `RTI/POC1-findings.md` — verification log for the overlay POC. Automated results are filled; user-attestation rows (QuickTime, Zoom) need to be checked off manually.
- `RTI/VERIFY.md` — the user-facing guide for running manual verification steps.
- `_archive/CluelyClone/` — **read-only reference** of the prior attempt. Useful for snippet lookup (`SonioxClient.swift`, `KimiClient.swift`, `HotkeyManager.swift` patterns are decent) but do not inherit assumptions. Do not modify files in `_archive/`.
- `spec.md` — the original engineering spec. **Treat as advisory, not authoritative.** The spec was written before implementation; many specifics will change as POCs land. Re-read the spec for architectural direction, not line-by-line fidelity. A consolidated spec rewrite will happen after the POC series completes.
- `competitor-breakdown/` — research artifacts from the live Cluely app (screenshots, HTML dumps, `APP_PRODUCT_BREAKDOWN.md`, capture scripts). Read-only reference.
- `.omc/` — oh-my-claudecode state. `plans/` contains saved plans; `prd.json` tracks the current POC's user stories. Do not hand-edit.

## POC progress

| POC | Element | Status |
|-----|---------|--------|
| POC-1 | Minimum viable invisible overlay (borderless translucent `NSPanel`, `sharingType=.none`, ⌘+\\ Carbon hotkey, menubar status item) | **Implemented, ralph-verified automated checks pass. User-attestation pending (see `RTI/VERIFY.md`).** |
| POC-2 | Audio → Soniox WebSocket → GRDB/SQLite transcript | **Validated live. User-tested: transcripts land in SQLite as readable text (spacing fix applied).** |
| POC-3 | Kimi LLM SSE streaming + overlay assistant UI | **Implemented, ralph-verified automated checks pass. Live LLM verification pending (paste Kimi key into `RTI/Sources/Secrets.swift` then see `RTI/POC3-findings.md` user-attestation table).** |
| POC-4 | Smart Screenshot (⌘+H, `SCScreenshotManager`, Vision OCR) | Not started |
| POC-5 | Persistence layer (sessions, transcripts, messages, modes) | Not started |
| POC-6 | Three-window layout (split-panel overlay, top widget, mini widget) | Not started |
| POC-7 | Modes, reference files, settings, Keychain | Not started |

When asked to "build the next POC" or "start POC-N", run `/plan` first to scope and save a plan under `.omc/plans/`, then `/oh-my-claudecode:ralph` to execute. Do not skip the plan step.

## Architecture direction (from spec.md — advisory)

Single-process macOS app. `AppState` (`@MainActor ObservableObject`) as the app-wide singleton is the spec's intent — POC-1 does not use it yet (too small); it comes in around POC-3 when multiple services need to share state.

Three pipelines feed into `AppState`:

1. **Audio pipeline** — `AVAudioEngine` tap → 16 kHz mono PCM → Soniox WebSocket (`wss://api.soniox.com/transcribe-websocket`) → interim + final transcript entries written to SQLite. System-audio loopback via `ScreenCaptureKit` is V2; MVP is mic-only.
2. **Screen pipeline** — on-demand `SCScreenshotManager` capture + Vision OCR. Screenshots are passed to the LLM then discarded (never persisted).
3. **LLM pipeline** — Kimi (OpenAI-compatible, `https://api.moonshot.cn/v1`, model `moonshot-v1-128k`) streamed via SSE. Four prompt shapes: Assist, "What should I say?", Follow-up questions, Recap.

Persistence: GRDB/SQLite. Schema sketch in `spec.md` §11 — will be re-derived in POC-5 rather than copied verbatim.

Windowing direction: the full-product Live Overlay is a borderless transparent `NSWindow` spanning the full screen with a dark translucent left 60% panel and a hit-test-disabled right 40%. POC-1 ships a simpler fixed 420×560 panel at top-left — the split-panel layout is POC-6.

"Undetectability" = `NSWindow.sharingType = .none`. POC-1's `screencapture -x` CLI test confirms exclusion works against that capture path. QuickTime and Zoom tests are user-attested (see `RTI/POC1-findings.md`).

Global hotkeys use Carbon `RegisterEventHotKey` (not SwiftUI shortcuts) so they fire from any frontmost app. POC-1 registers only ⌘+\\ (overlay toggle). Additional hotkeys per POC.

## Conventions

- **Secrets**: `spec.md` §3 hardcodes Soniox and Kimi API keys for dev convenience. **Do not carry that into RTI code.** When POC-2/POC-3 land, read from Keychain (`SecItemAdd`), never `UserDefaults` or committed plaintext. No `.env` files.
- **Transcript semantics** (for POC-2): Soniox emits words with `is_final: false` (interim, update in place) and `is_final: true` (commit, persist to `transcript_entries`). Map `speaker: 0` → `"self"`, `1+` → `"them_1"`, `"them_2"`, etc.
- **Streaming responses** (for POC-3): Kimi SSE parser must handle `data: [DONE]` sentinel and incremental `choices[].delta.content` concatenation.
- **Reconnect policy** (for POC-2 Soniox): exponential backoff 1s → 2s → 4s → 8s, max 5 retries, then surface error.
- **Swift/SwiftUI scope** (POC-1 rule, may loosen later): the overlay is hand-rolled `NSPanel`, not a SwiftUI `WindowGroup`. SwiftUI is used inside the panel via `NSHostingView`. Keep it that way unless a concrete need forces a change.
- **Dependencies**: POC-1 has zero SPM deps on purpose. Add deps only when the POC requires them (GRDB in POC-5, Starscream in POC-2, swift-markdown if/when needed).

## Competitor research

The `competitor-breakdown/*.sh` scripts use `npx playwright-cli` to capture the live Cluely site into `competitor-breakdown/screenshots/` and `pages/`. Re-run only if the user asks to refresh research; they are not part of any build.

## Where to look for what

- **Current POC status** → `.omc/prd.json` (story-level pass/fail) and the POC-N-findings.md for the active POC.
- **How to verify the current POC manually** → `RTI/VERIFY.md`.
- **How to regenerate the Xcode project after editing `project.yml`** → `cd RTI && xcodegen generate`.
- **Overlay implementation** → `RTI/Sources/OverlayWindowController.swift` + `RTI/Sources/OverlayPanelView.swift`.
- **Hotkey implementation** → `RTI/Sources/GlobalHotkey.swift`.
- **App entry / status item** → `RTI/Sources/RTIApp.swift` + `RTI/Sources/AppDelegate.swift`.
- **UI pixel details (full-product target)** → `spec.md` §7 first, then `competitor-breakdown/APP_PRODUCT_BREAKDOWN.md` and screenshots. Treat as reference target, not binding.
- **API request/response shapes (Soniox, Kimi)** → `spec.md` §6, to be validated against live endpoints during POC-2/POC-3.
- **Historical snippets** → `_archive/CluelyClone/Sources/` — read-only.
