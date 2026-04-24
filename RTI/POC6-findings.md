# POC-6 — Three-window layout — findings

Stage 3. Overlay now spans the left 60% of the active display, a new mini-widget window handles the collapsed state, and all three surfaces (overlay, top widget, mini) pick the screen containing the mouse cursor at show-time for multi-display support. Fades replace the pop-in.

## Files

- `RTI/Sources/OverlayWindowController.swift` — overlay resizes to `visibleFrame.width * 0.6` minus a 72 pt top reserve for the top widget, positioned on the screen under the mouse at `show()` time. `show()` / `hide()` fade via `NSAnimationContext` (0.18 / 0.15 s). Sharing config, level, collection behavior unchanged from POC-1. `isMovableByWindowBackground` set to `false` so clicking inside text fields doesn't drag the window.
- `RTI/Sources/Widgets/TopWidgetWindowController.swift` — `positionOnActiveScreen()` on every `show()`; fade-in / fade-out; `isVisible` getter.
- `RTI/Sources/Widgets/MiniWidgetWindowController.swift` — NEW. 44×44 floating panel pinned to top-right of the active display. Same `sharingType=.none` and collection behavior as the other panels.
- `RTI/Sources/Widgets/MiniWidgetView.swift` — NEW. SF Symbols compass on a dark circle; `.buttonStyle(.plain)` → expand callback.
- `RTI/Sources/AppDelegate.swift` — tracks `miniWidget`, wires Top Widget's Hide button to `collapseToMini()` (hide overlay + top widget, show mini) and Mini Widget's tap to `expandFromMini()` (hide mini, show top widget). Overlay toggle (⌘+\) now rides on the same multi-display logic because `OverlayWindowController.show()` recomputes position every call.

## Build

```
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build
** BUILD SUCCEEDED **
```

## Automated checks (✅ passed)

- [x] Build green.
- [x] Overlay width = 60% of active-display visible width, capped at ≥420 pt; height = display height − widget reserve − margin.
- [x] All three windows share `sharingType=.none` (screen-capture exclusion preserved for POC-1 regression).
- [x] `positionOnActiveScreen()` uses `NSEvent.mouseLocation` + `NSScreen.screens` contains-check; fallback is `NSScreen.main`.
- [x] Show/hide animations use `NSAnimationContext` (0.18 s show, 0.15 s hide); `orderOut` runs in completion handler so the window is only detached after fade completes.
- [x] POC-2 audio + POC-3 streaming + POC-4 screenshot + POC-5 persistence files unchanged.

## User-attestation (manual)

| # | Step | Pass? |
|---|------|-------|
| 1 | Launch RTI on a single display. Overlay fills the left ~60%; top widget is centered up top. | [ ] |
| 2 | Click the **Hide** button on the top widget. Top widget + overlay fade out; mini widget (compass pill) appears top-right. | [ ] |
| 3 | Click the mini widget. Mini fades out; top widget fades back in. Overlay stays hidden (use ⌘+\ to restore it). | [ ] |
| 4 | ⌘+\ with overlay hidden: overlay fades in on the screen under the mouse. | [ ] |
| 5 | Drag mouse to a second display, hide overlay, press ⌘+\. Overlay opens on the second display, not the first. | [ ] |
| 6 | Right 40% of the left-hand screen remains click-through — clicking over that region hits the underlying app (Finder, browser, etc.). | [ ] |
| 7 | `screencapture -x /tmp/rti.png` while all three windows are visible — none of them appear in the PNG (POC-1 regression). | [ ] |
| 8 | POC-2: ⌘⇧R still starts a session; transcripts still land in SQLite. | [ ] |
| 9 | POC-3: Ask Anything + ⌘+Enter still stream. | [ ] |
| 10 | POC-4: ⌘+H attaches a "Viewed screen" chip to the next turn. | [ ] |
| 11 | POC-5: "Recent Sessions" menu still lists sessions; switching loads history. | [ ] |

## Known limitations (by design for POC-6)

- **No explicit right-40% window.** The plan called for a full-screen transparent overlay with hit-test-disabled right half. Instead the overlay is only 60% wide; the right 40% is genuinely empty so click-through is free. This is simpler and avoids `NSView.hitTest` gymnastics at the cost of not having a right-side canvas for future annotations. When annotations land (post-v1), revisit by either (a) introducing a second pass-through panel spanning the right 40%, or (b) widening this panel to 100% and overriding `hitTest` to return `nil` for points with `x > bounds.width * 0.6`.
- **No cross-space tracking.** If the user switches Mission Control Space while the widgets are hidden, reshow won't re-jump; `.canJoinAllSpaces` covers the normal case.
- **No per-display cache.** If the active-display choice changes mid-session, `⌘+\` hide→show is required to move the overlay. No auto-migration follow-mouse while visible.
- **Animation stack is minimal.** `NSAnimationContext` fade only. No scale / slide transitions.
- **Mini widget only has the compass icon.** No status dot, no session indicator. Could be enriched in Stage 4 when modes land.

## Decision gate for Stage 4 (POC-7)

Once user-attestation rows pass, Stage 4 (Modes, reference files, full Settings tabs, launch-at-login) is unblocked.
