# Cmd+K baseline, 12 November 2026

At revision `67c44ec8`, the default Research palette showed 5 rows. Its eager list evaluated all 55 matched rows three times on each open. A one-letter filter evaluated all 49 surviving rows. Limiting a disposable control to 5 row views reduced median first-letter filter-update time from 24.51 to 5.95 ms with the same ranking and source data.

The full command factory runs once at launch. Repeated matching, including availability checks and fuzzy scoring, cost at most 2.40 ms in this run. Dynamic composer rows cost at most 0.18 ms. The timings localize the excess update cost to presenting the result list. They leave physical Cmd+K-to-monitor timing on the installed build unverified.

## Measurements

Twelve cycles each sent Cmd+K followed by `s`, `e`, `t`. Times below are milliseconds. All samples include the first opening of the palette in a fresh process. With 12 samples per sequence position, nearest-rank p95 equals the maximum.

| Input | Matches | Event to observed view update, median / p95 / max | Event to complete workspace bitmap, median / p95 / max | Ranking only, median / max |
|---|---:|---:|---:|---:|
| Cmd+K | 55 | 47.12 / 74.77 / 74.77 | 279.88 / 364.28 / 364.28 | 0.15 / 0.18 |
| s | 49 | 24.51 / 51.02 / 51.02 | 246.98 / 282.77 / 282.77 | 1.82 / 2.40 |
| se | 30 | 18.38 / 22.64 / 22.64 | 236.99 / 271.02 / 271.02 | 1.63 / 1.70 |
| set | 15 | 13.55 / 18.10 / 18.10 | 234.62 / 566.23 / 566.23 | 1.34 / 1.43 |

The first cycle reached the updated view at 74.77 / 51.02 / 22.64 / 13.49 ms, respectively. Median opening and filter times for the visible-row control were 12.53 / 5.95 / 5.84 / 6.05 ms. Its worst times were 24.89 / 18.71 / 8.08 / 7.68 ms. The control clips the collection, so results below row 5 cannot be selected or scrolled into view. A production fix must support keyboard navigation through the full result set, selected-row scrolling and VoiceOver. The CSV includes a separate 620 × 460 pt stress run below RTI’s minimum size and its matched control. [Machine-readable observations](fixtures/palette-baseline/samples.csv)

**Measurement boundaries.** Xcode 26.2, macOS 26.5.2, arm64, Debug, an 860 × 660 pt nonactivating offscreen panel at RTI’s default workspace size. The host mounted the full Live workspace on Assist. RTI’s registered commands, dynamic Research commands, composer, text field, ranker, SwiftUI layout and AppKit key dispatch all ran. Each signpost started immediately before sending a synthetic NSEvent to the panel. The earlier endpoint returned when the probe observed the expected query in the palette body, after any layout needed to service it. The later endpoint followed layout and a complete AppKit bitmap render of the workspace. The probe asserted that the first-ranked row was evaluated. It neither encoded a PNG nor presented to WindowServer. Rasterizing the whole hidden workspace adds substantial cost even when the palette draws only its visible rows.

The hidden window’s normal focus handoff did not reliably activate its text field. After timing the opening frame, the harness explicitly focused the palette’s own NSTextField. Filter keys then used normal AppKit dispatch. The probe does not verify the production window’s time to accept typing, input queue delay before dispatch, or display refresh. Before accepting the <100 ms / <16 ms targets, repeat on the isolated beta through its presented window and include first paint, automatic focus, broad one-letter queries and the worst sample.

**Fixture.** 1,301 invented alternating-leg EN/ZH final batches spanning 65 minutes, 24 saved two-turn chat threads, 24 current chat messages, 52 registry commands. Each event was preceded by another final batch on the real receive path. The normal 120 ms publisher coalesced changes during the run. Both default-size tests finished with 1,349 published entries and zero failures. Each run used its own invented vault and app-support folder, empty business project roots and an in-memory Research call type. The host never started the recorder, sockets, scheduler, global hotkeys or app delegate. Saved conversations were created before timing. Source tracing found no saved-thread read, provider discovery or note/vault search on the palette filter path. [Instrumented fixture](fixtures/palette-baseline/instrument.patch)

## Other overlay and popover paths

| Surface | Finding from the current source |
|---|---|
| Guide action palette | Shares `CommandPaletteView`, registry ranking and the eager list. Adds Guide commands at view evaluation. The Guide reader also constructs each question and its quotes from section data. [Guide view](../RTI/Sources/UI/Overlay/GuideTabView.swift) |
| Add Context, scope, @, slash and shared chooser panes | Share the eager `ChooserList`. Add Context and @ load workstreams and recent meetings synchronously when opening on a cache miss. Scope selection reloads items. Text ranks cached rows. The separate @ filename lookup is cancellable, debounced and detached. Slash filters a fixed catalog. [Chooser list](../RTI/Sources/UI/HouseChat/HouseFloatingChooser.swift), [context sources](../RTI/Sources/UI/Overlay/AssistantInputView+AddContext.swift), [lookup](../RTI/Sources/UI/Overlay/MentionSuggestionStore.swift) |
| Header project menu and Prepare scope picker | The header calls `VaultWorkstreamStore.projects()` from its body. It can enumerate the vault and configured work folders when evaluated. Prepare loads the source lists on appearance and repeatedly filters in-memory data to derive counts and visible subsets while typing. [Project menu](../RTI/Sources/UI/Overlay/OverlayRecordControls.swift), [Prepare](../RTI/Sources/UI/Overlay/SetupTabView.swift) |
| Header options, model and call type | Small fixed collections. The model chooser uses the three compiled-in providers. Mic/device menu refreshes device and app inventories on appearance and refresh notifications. Translation lists known modes and languages. Speaker menus derive choices from attendees, names or the loaded roster. [Header](../RTI/Sources/OverlayPanelView.swift), [audio menu](../RTI/Sources/UI/Overlay/OverlayMicControl.swift), [transcript controls](../RTI/Sources/UI/Overlay/TranscriptTabView.swift) |
| Assist and saved-chat Find, chat library | Opening Find or changing its query builds text match ranges over the current conversation. Library search filters loaded content. Library reload separately awaits the store once per saved thread. The library loader has no call site in Cmd+K filtering. [Find](../RTI/Sources/UI/HouseChat/HouseFindBar.swift), [Assist](../RTI/Sources/UI/Overlay/ResponseView.swift), [library](../RTI/Sources/UI/SessionsControl/ChatLibraryModel.swift) |
| Session actions, rail and chat context menus | Session actions rebuild a small enum of permitted commands for the selected item and use the same fuzzy scorer. Rail and chat menus act on one selected item. [Session actions](../RTI/Sources/UI/SessionsControl/SessionsWindowModel+Commands.swift), [chat menus](../RTI/Sources/UI/SessionsControl/ChatLibraryView.swift) |
| Brief sheet, archived speaker editor, frame preview | Cold brief opening reads the brief list synchronously. The speaker editor synchronously reads the selected transcript once when opening. The gallery enumerates frame files on appearance and the preview constructs an image from disk in its body. These are separate potential open stalls. [Brief](../RTI/Sources/UI/MeetingBrief/MeetingBriefView.swift), [speaker editor](../RTI/Sources/UI/SessionsControl/SessionsWindowModel+Reader.swift), [frame gallery](../RTI/Sources/UI/SessionsControl/SessionFramesGallery.swift) |
| Guide import/preview, system file panels, native status menu, notices | Guide preview traverses its questions. File panels, save/export/share and alerts run on explicit actions. The status menu builds command items at launch and refreshes enabled state, titles and checkmarks on open. New-speech, mute and transient notices, onboarding and screen-highlight windows have no query-driven command list. [Guide controls](../RTI/Sources/UI/Overlay/GuidePrepareControls.swift), [status menu](../RTI/Sources/UI/MenuCoordinator.swift), [highlight](../RTI/Sources/Screenshot/ScreenHighlightOverlay.swift) |

These other surfaces received a source audit. Timing data above applies to Cmd+K in Assist.

## Repeat on a disposable checkout

Run from the RTI repository. The harness patches only the disposable source tree. It expects Xcode 26.2 and the pinned Swift packages already available in the repository’s DerivedData. The extra control patch exists only to measure capped rendering. Record baseline and control separately.

```sh
repo="$(pwd -P)"
run="$(mktemp -d)"
mkdir -p "$run/src" "$run/dd"
git archive 67c44ec8 | tar -x -C "$run/src"
cp -cR .deriveddata/SourcePackages "$run/dd/"
cd "$run/src"
cp RTI/Sources/Secrets.swift.example RTI/Sources/Secrets.swift
patch -p1 < "$repo/docs/fixtures/palette-baseline/instrument.patch"
measure() {
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" TMPDIR="$run/" \
    xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug \
    -derivedDataPath "$run/dd" -disableAutomaticPackageResolution -skipPackageUpdates \
    -parallel-testing-enabled NO \
    -only-testing:RTIRenderTests/CommandPaletteFocusProofTests/testSyntheticLongSessionLatency test > "$1" 2>&1
}
measure "$run/baseline.log"
patch -p1 < "$repo/docs/fixtures/palette-baseline/visible-rows-control.patch"
measure "$run/control.log"
rg '^PALETTE_(SETUP|PUBLISH)|TEST SUCCEEDED' "$run/baseline.log" "$run/control.log"
```

The points-of-interest signposts are `EventToBitmap` and `Match` under `rti.fixture.palette`. Sample lines contain cycle, query, event-to-bitmap ms, event-to-observed-query ms, aggregate ranking ms, host command-construction ms, matched rows, row evaluations and distinct rows evaluated. A post-fix run should restore the complete result collection and repeat the baseline and a presented-window test on the same system.
