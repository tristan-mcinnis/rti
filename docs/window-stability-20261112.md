# RTI window stability

**Phase 0 audit · 12 November 2026 · source `67c44ec8`**

RTI needs to keep the window where the user places it while transcript, chat and Guide content update. Verify native window behavior on the isolated beta before changing the header. The reported Exposé-like motion remains unidentified.

## What the hidden-window tests reproduced

Two tests used the actual workspace controller, temporary fixture storage, an empty project-root list and a unique native frame autosave name. Every test window stayed unordered. Rectangles below are macOS logical points, measured as (x, y, width, height) with an exact-equality comparator.

| Probe | Observed |
| --- | --- |
| 40 final/interim fixture updates across Live, Sessions, Chats, Settings and Live again | Frame stayed (55, 40, 805, 550) at each sample. Native close, minimize and zoom buttons were present. Minimize and zoom were enabled. Window style was resizable, managed and full-screen-primary. |
| Double click delivered to the real custom header drag view | A window spy intercepted its drag call to keep the desktop still. Single click and double click each invoked drag once. Neither invoked zoom or minimize. Native traffic-light clicks and the actual displayed title-bar hit region require a separate visible test. |
| Save on primary display, attach fresh controller | (55, 40, 805, 550) restored exactly in two consecutive hidden restores in the instrumented run. In an earlier run the same target restored at (−3235, −115, 805, 550). The earlier run did not log the native display selection. |
| Save inside a connected 1× left display, attach fresh controller | The saved rect was (−3385, −161, 805, 550), inside a visible frame of (−3440, −201, 3440, 1410). The new controller restored (15, 19, 805, 550) on the primary. An independent plain, unordered NSWindow with identical style, toolbar and minimum size restored the same saved record to exactly (15, 19, 805, 550). Native frame restoration accounts for the (+3400, +180) change in this fixture, before autosave name attachment. This measures never-shown windows on this host. Repeat with a displayed beta across both displays. |
| Inject lost or narrow display geometry into the existing placement logic | Legacy restore accepted a rect with just one point of width visible. The fallback on an 800 × 600 desktop requested a right edge at x=876. On a synthetic negative-origin desktop the top-left inset was the intended 16 points. Actual bounds imposed by AppKit can differ from requested bounds. |

**Reproduce.** In a disposable checkout of the baseline, apply the linked patch, copy `Secrets.swift.example` to `Secrets.swift` as the keyless stub, then run `scripts/scrub.sh`. Run the two selectors below with the existing RTI Debug scheme, a dedicated temporary derived-data path and parallel testing disabled. The fixture creates its own records, reports coordinates, and intercepts drag. The second-display comparison runs when two displays are attached. [Test fixture](fixtures/window-stability/hidden-window.patch)

```text
-only-testing:RTIRenderTests/WorkspaceRenderProofTests/testHiddenWindowGeometryBaseline
-only-testing:RTIRenderTests/WorkspaceRenderProofTests/testHeaderDoubleClickDispatchInHiddenWindow
```

## What can move

- **Window frame.** `OverlayWindowController.restoreFrame` runs at construction. It tries the native record, then legacy geometry, then the screen under the pointer. An undersized restore also changes position. The hosting view leaves window sizing to AppKit. Normal transcript updates and page navigation have no explicit frame setter.
- **Content.** The Guide recenters its scroll view when the current question changes. Growing quote blocks can also move rows. The transcript follows its last turn, or corrects the clip origin to preserve a reading anchor. A moving scroll origin can look like the window jumping even with an unchanged window frame.
- **Activation, minimize and Spaces.** Explicit Show deminiaturizes and makes the workspace key. Activation may request that LaunchServices reopen the same bundle; Dock reopen may select Live when there are no visible windows. Delayed focus notifications can reach the composer after Show. Toggle tests visibility, miniaturization and app hiding, without checking whether the workspace is on the active Space. The workspace opts into a managed Space. A separate screen-highlight rectangle can join all Spaces during an explicit highlight. No RTI command that enters macOS Mission Control was found. The old baseline verification spec expected the workspace to follow across Spaces.
- **Full screen.** The controller updates the header inset at the start of the native enter/exit animation. It has no corresponding transition-failure handler. Pinning raises the window level. Test normal and pinned behavior separately.

## Visible beta acceptance

During an invented recording, record time, window frame, screen/scale, Space-active flag, key/minimized/zoom/full-screen state and scroll origin. Keep transcript text out of the trace. At each settled step, allow one physical pixel of geometry rounding. Repeat at default and minimum sizes.

1. Drag once and release. While transcript and chat update, open Cmd+K, switch routes, scroll away from the latest turn, then return. The frame must settle at release, and a reader who scrolls back must keep their place.
2. Test yellow, ⌘M and Dock restore. Double-click empty title-bar space using the Mac's configured zoom/minimize/no-action preference. Test native zoom/restore and green-button full screen through entry and exit. Each deliberate action must run once. Background updates must leave a minimized window minimized.
3. Switch Spaces and invoke Mission Control manually. Observe RTI before, during and after. The OS animates the overview; the settled frame, minimize state and assigned Space must survive. Compare a deliberate Show from another Space with a delayed callback after a user has minimized.
4. Save a custom frame on each of two displays, including a left or lower display and differing backing scales. Close/reopen and relaunch on each. Disconnect the saved display and reconnect it. On an available saved display restore its frame; after removal keep the title bar, all traffic lights and resize corners reachable on a remaining display. Recording continues throughout.

The next fix belongs to the owner shown by the trace: header hit testing for a swallowed double click, frame restoration for a changed window rectangle, activation for an unsolicited restore, or the reader for an unstable clip origin.
