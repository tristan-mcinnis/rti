# RTI Change Log

## 2026-09-23: The live transcript stops re-deduping the whole session

A 1h45m session pinned 86% of the busy main thread in one chain:
`SessionCoordinator.publishState` → `flushPublishState` →
`TranscriptPipeline.liveEntries` → `dedupedAcrossChannels`. The cross-channel
echo dedupe was quadratic in session length, and it re-ran on every final batch
at up to the 8 Hz publish debounce, so the app degraded as the transcript grew.

- Every comparison rebuilt a three-way `CharacterSet` union
  (`whitespacesAndNewlines ∪ punctuation ∪ symbols`) to normalise its two
  strings. `CharacterSet.union` computes full Unicode plane bitmaps, and that
  alone was 55% of the busy thread. The union is now built once.
- Each mic entry scanned the whole entry list for its ±5s echo window. The
  window is now found by bisecting a per-channel list of direct-system entry
  positions.
- Each entry's text is normalised once, by the aggregator that owns the entry
  (`TranscriptAggregator.normalizedEntries`), not once per merge pass. That
  also removed the per-pair normalisation entirely.

One rebuild over 16,000 synthetic entries: 12.7 s before, 0.26 s after, and 4x
the entries now costs 4.02x instead of ~16x. Behaviour is unchanged: 6,000
randomised two-channel scenarios run differentially against the previous
implementation, plus 16 adversarial cases at the ±5s window boundaries,
produced no differences.

`TranscriptPipelineTests.test_mergeCost_tracksTranscriptLength_notItsSquare`
guards the cost and is red on the old code. It runs under Debug only: Release
test compilation fails for an unrelated `RTICore` module-resolution reason.

## 2026-09-21: Add Context filters; only `@` searches the vault

The `+` pane and the `@` chooser share one row builder, and the pane was
passing the vault's own matches into it: typing there narrowed the rows on
screen *and* ran the mention index over the whole vault on every keystroke.

- The `+` pane filters only the rows it already holds: the recent meetings, the
  projects and clients, and its own actions. No vault read as you type.
- The vault-wide search stays where it belongs, on `@` typed in the field. The
  pane's "Vault File" row still hands off to it.
- The pane's short action list, its scope page and its footnote are unchanged.

## 2026-09-17: Add Context gets its own search

The attachment menu now takes the keyboard when it opens and filters as you
type, the way the `⌘K` palette and Quick Launch's Attach pane already do.

- The floating search field moved out of the palette into one house component
  (`ChooserSearchField`), so the palette and Add Context share the same field,
  the same focus handling, and the same key routing.
- Typing narrows the rows by fuzzy match on the title and the row's detail:
  `ss` keeps "Screenshot Screen", `win` keeps "Screenshot Window", `note`
  keeps "Note Mode". ↑↓ and ↩ act on the filtered list, and the highlight
  always indexes what is drawn.
- The Search Scope page keeps its own search; going back clears it and puts
  the keys back in the field.
- `esc` closes the pane, or goes back from the scope page, as before.

## 2026-09-17: Screenshots are visible, kept, and read by the model alone

- The composer shows an attached screenshot as a thumbnail chip: the capture
  is drawn in place of the kind glyph next to "Screenshot", so you can see
  what is attached before sending. The chip is renamed from "Screen".
- Manual captures no longer call the local vision model. The screenshot goes
  to the model directly (deepseek-flash reads it), which is faster and is the
  point of the image. Vision OCR still runs on-device and rides along as text.
- Every screenshot is written into the recording's frame folder
  (`<session>/frames/`) independently of the local vision lane, so the
  Sessions window shows it again later. A textless image (a chart, a map) now
  attaches instead of being rejected as empty.
- A dropped or picked image takes the same path as a capture, including the
  session copy.
- The About panel no longer implies screenshots stay on this Mac.

## 2026-09-17: Screenshots go to the model as images

The screen and window captures now send the screenshot itself, not just its
OCR text, whenever the active model takes image input.

- `deepseek-flash` accepts inline images, so a capture attaches as an OpenAI
  `image_url` content block on the user turn (inline base64 JPEG). The OCR
  text and the local vision description still ride along.
- One provider capability flag gates it: a provider with no image input gets
  the text-only turn it always got.
- Images are accepted in user messages only, so the image rides the latest
  user turn and the system context stays text.
- A textless screenshot (a chart, a map) now attaches instead of being
  rejected as empty.
- Add Context copy no longer claims the image stays on the Mac: it goes to
  the model. RTI's own windows and the Screen Privacy list are still excluded
  at capture, so their pixels are never in the image.

## 2026-09-17: Screenshots as context, and Quick recap as the default

Attach what you are looking at, and make the mid-meeting turn a catch-up.

- **Screenshot Window** (⌘⇧J) reads the frontmost window that is not RTI's own
  and not on the Screen Privacy list, then attaches its OCR text (plus a local
  vision description when the `local_vision` lane is on) to the next turn. The
  window server's front-to-back order picks the window. The image is sent to
  the model too, per the entry above.
- **Screenshot Screen** is the existing whole-screen read, renamed from "Read
  Screen Once" so the two live together in Add Context (⌘⇧H, unchanged).
- **Quick recap** is the shipped ⌘⏎ primary action: the last 5 minutes of
  transcript, one or two bullets. It replaces Assist / Answer-latest as the
  default in Meeting and Interview modes and in the fieldwork preset. An
  existing Assist or Answer-latest default is moved once; an explicit choice of
  any other action is left alone. Full Recap (⌘⌥R) still uses the sticky depth
  and the 15-minute window.

## 2026-09-17: Attach on ⇧⌘S, and the `@` list opens at once

The composer now pairs with Quick Launch on the attach key, and the vault
list no longer waits for its first search to appear.

- `⇧⌘S` opens Add Context (files, search scope, note mode), the same key Quick
  Launch binds to its attach chooser. `⇧⌘A` still works, and the key shows in
  Settings → General → Hotkeys.
- Typing `@` opens the vault chooser immediately and filters as you keep
  typing, instead of waiting for the lookup to answer. A fresh lookup says
  "Searching the vault…", and a query with no match says so rather than
  drawing an empty list.
- The `@` list's first lookup runs without the keystroke debounce, so the
  recent-files list lands as soon as the vault index is warm.

## 2026-09-12: Session titles no longer depend on the summary

A session's title used to be written only when the end-of-session summary
succeeded. When that call came back empty, the session stayed "Untitled
session" — 33 of 88 archived sessions had no title.

- A session with no summary now still gets a real title: the calendar event
  picked in Prepare, the vault meeting note, a generated title from the note
  headings, or the first substantive line of the transcript. Only a session
  with none of those shows the date and length, and none says "Untitled".
- Fix: the summary call could return no text at all and be treated as a
  success. The smart model reasons before it writes, and that reasoning spends
  the same token budget as the answer, so a long deliberation ended the stream
  with nothing written: HTTP 200, about 70 seconds, empty text. RTI now says
  why in the log (finish reason and how much reasoning arrived) and asks again
  with thinking off, which answers directly.
- A session whose summary never landed says "Summary unavailable" in its row
  instead of showing nothing.

## 2026-09-12: House composer

The Assist composer now looks and works like Quick AI (`docs/house-style-migration-20260912.md`, package B).

- One row: a plus circle, a pill field with the next action inside it, and a `⌘K` circle. The field says what `↩` does: the primary action ("Assist ⌘↩") when empty, "Ask ↩" with text, "Stop esc" while an answer streams, "Add Note ↩" in note mode.
- The ✦ menu moved to `⌘K`: quick actions, note mode, attach, read screen, recap depth, and every RTI command, in one palette.
- The paperclip, context pills, and Note toggle moved to the plus circle (Add Context): attach a file, a vault file, read the screen once, search scope, note mode.
- Files, vault files, and screen reads show as chips above the field, with page count, size, and "cut" when the text was cut. A file that fails says why on its chip.
- `↩` during an answer queues the follow-up; it sends when the answer ends.
- `esc` in the composer closes a list, stops an answer, then clears the text. It no longer hides the window from there.
- Fix: `↩` while typing Chinese (pinyin) commits the text and no longer sends the draft.
- Fix: the stop button is no longer red. Red is for recording only.
## 2026-09-12: House style for Settings, the welcome window, and Meeting Brief

- Settings has its own window (860 × 620): a rail with "Search settings…" and ⌘1 to ⌘8, cards with 40 pt rows, and "Next ⌘n" in the footer. Voices, Logs, and a new About pane join the others. `esc` (with an empty search) and ⌘W close it; the Close button is gone.
- General drops the accent, contrast, and window size controls. Appearance and Reduce Motion use ink segmented controls. Hotkeys show real key caps.
- The welcome window follows Quick Launch's: the RTI mark, one line, five key hints, the two setup cards, and one Get Started that turns on once both keys are saved and the microphone is allowed.
- Meeting Brief opens in the AI Chat window shape: the brief in one reading column, and the brief list as a rail, hidden until ⌃⌘S. `esc` clears the search, then hides the list; it never closes the window.
## 2026-09-12: Assist thread in the house look

The Assist answers now read like Quick Launch's Quick AI (`docs/house-style-migration-20260912.md`, package A).

- Questions sit on the right as pills; a canned action shows its name and glyph ("Recap · brief"), not its prompt. Long questions fold behind Show more (⇧⌘M).
- Answers are plain prose with no card. Above each answer, quiet lines say what it read or did ("Used the last 6 min of the transcript", "Searched vault · 6 results"). Its sources sit under it; a row opens the file.
- Attached files, `@` vault files, and a screen read show as chips over the question.
- While an answer runs, a status line with thinking dots replaces the spinner chip. A failed answer shows its error under the question with Retry (⌘R).
- Scrolled up while an answer streams, the view stays still and a Latest chip (⌘↓) brings you back.
- Find in Chat (⌘F): hits are marked in questions and answers; ↩ and ⇧↩ step through them, esc closes.
- Code blocks get a strip with the language, Wrap, and Copy.
- Errors with no turn (missing keys, a capture fault) sit above the composer with a fix. The sources popover is gone.
- Copies from RTI carry the transient markers, so clipboard managers skip them.
- Fixed: a question with several attachments showed "(prepared.references.count) attached sources" instead of the number.
## 2026-09-12: Overlay shell, menus, and keys

The overlay takes the house window shape (`docs/house-style-migration-20260912.md`, package C).

- The header shares the traffic-light row: meeting title over a state line ("Recording · Meeting · DeepSeek"), then the capture controls and the record chip. Mode and model open small choosers in the window.
- The footer bar is gone. Tabs sit in a row under the header; ⌘1 to ⌘7 pick a tab.
- `esc` no longer hides RTI. It closes a chooser, then stops an answer, then clears typed text. ⌘W, the close button, and ⌘\ still hide it.
- New menus: Session (record, pause, note, mute, read screen, project), View (tabs, Show Session List ⌃⌘S in Sessions), Edit › Find (⌘F), Window › Keep on Top (off at every launch), RTI, Sessions.
- ⌘\ stays RTI's global show and hide. The window frame now saves itself; the old size sliders only set the first size.
- Empty tabs show short hint lines with their keys. Prepare uses the settings card style.
## 2026-09-12: Sessions window and titles

Past sessions have their own window in the house chat shape (`docs/house-style-migration-20260912.md`, package D).

- Sessions opens in its own window: the session title and date line on top, the files as chips, one reading column.
- The session list is a rail, hidden until ⌃⌘S or the header button. Search filters titles; with the vault search up, it also finds words in transcripts and shows where.
- No more "Untitled session". A title comes from your rename, the summary, the vault meeting note, the calendar event, a short title made from the notes, or the date and length.
- ⌘K shows the session's actions (rename, name speakers, upgrade, regenerate, export, reveal). ⌘J asks about it in RTI. ⌘F finds in the open file.
- A past Assist chat reads like it did live: your questions on the right, answers on the left.
- Preferences keep their own window until the new settings window lands.

## 2026-09-12: House chat seams

No visible change. Groundwork for the house chat look (`docs/house-style-migration-20260912.md`, package 0).

- Chat turns can carry attachments, tool lines, and sources as data.
- Shared house chat pieces copied from Quick Launch (key hints, thinking dots, title block, row highlight, glass, cards).
- `RTIActivation.bringToFront` and a `SettingsWindowController` stub for later windows.
- Render proofs share one harness and an invented fixture vault, so no proof reads real meetings.

## 2026-09-02 — Consistency pass: one resolver per path and binary

No feature change. See `docs/consistency-audit-20260902.md` for the audit.

- **`AppSupportPaths`** replaces six independent `~/Library/Application
  Support/RTI` resolvers (credentials, modes, crash log, sessions fallback,
  Settings › General reveal actions).
- **`VaultPaths.gitRootDirectory` / `vaultToolURL`** replace three copies of
  the `databases → up two → .claude/tools/…` derivation (session router,
  speaker enrollment, hermes search CLI).
- **`ExternalTools`** owns the `claude`, `bun`, and python candidate lists
  and the fire-and-forget child launcher. `SpeakerEnrollment` and
  `SessionArchive` no longer carry their own.
- **Transcript-upgrade scripts** are no longer hardcoded to `/Users/user`:
  `soniox_file_script` / `aliyun_file_script` in `~/.config/rti/config.json`,
  defaulting to the same checkout paths under the current home.
- README and CLAUDE.md now describe the titled `NSWindow` Dock-app shape
  shipped 2026-09-01 instead of the retired borderless translucent panel.

## 2026-08-30 → 09-01 — Window shape, audio resilience, screen privacy

Backfilled from `git log` (no entry was written at the time).

- Regular Dock app (`LSUIElement=NO`) with a normal titled main window; the
  always-on-top float and translucency are gone. Capture-app picker refreshes
  live.
- Upgraded transcripts move notes to a trailing section; short empty sessions
  self-clear; summary + title fall back to the live transcript when the
  upgrade fails.
- Mic never binds to a Bluetooth input; alarm on a never-delivering mic.
  System-audio leg: lazy STT connect, SCK fallback for a dead tap, honest
  retry budget, idle park/resume instead of silence keepalive.
- Screen privacy deny-list at the `SCContentFilter` choke point; chat
  hotkeys scoped to active sessions; blank settings tabs fixed; honest
  versioning. Engineering audit in `docs/engineering-audit-20260901.md`.

## 2026-08-29 — Local vision lane: frames with a home + model descriptions

Screen captures are no longer OCR-only. A new `local_vision` block in
`~/.config/rti/config.json` (absent/off = the old OCR-only behaviour) wires
captures to the local-models daemon on `127.0.0.1:8078` (`POST /v1/vision`,
Qwen3-VL via mlx-vlm) — the image never leaves the Mac.

- **Vision descriptions.** ⌘⇧H, `/screen`, the `capture_screen` tool, and
  dropped images gain a "What the screen looks like" section from the local
  vision model: layout, charts, imagery — what OCR cannot carry. Failures
  degrade silently to OCR-only; a capture never blocks on the model.
- **Frames have a home.** During a live session, the cursor display's frame is
  kept as a compressed JPEG (1,600px long edge, q0.7) and archived to
  `sessions/<stamp>/frames/` beside `screen-context.md`, which now references
  each frame and carries the vision summary per event. Frames are owner-only
  and gitignored (vault media policy); the text lanes stay text.
- **Ambient trail.** Trail events can carry frames too (`save_frames`) and,
  when `ambient_describe` is on (default off), a background vision description
  per accepted frame.
- New in `RTICore`: `LocalVisionService` (+ configuration parsing),
  `ScreenFrameEncoder`, `VisualFrameStore`; `VisualContextEvent` gains
  optional `visionSummary` / `frameFilename` (legacy JSON still decodes).
  Tests: `LocalVisionServiceTests`, `ScreenFrameEncoderTests`,
  `VisualFrameStoreTests`, extended `VisualContextEventTests`.

## 2026-06-25 — Editable prompts (Settings → Prompts) + single-source registry

Every prompt RTI sends is now editable in the app, with reset-to-defaults, and
lives in one registry instead of scattered `static let` literals.

### Architecture

- **New prompt registry (`RTICore`).** `PromptID` + `PromptDefaults` are the
  single source of every prompt's default text (the 16 on-demand/system prompts
  plus the 5 background controller prompts: findings, auto-assist cards,
  DG parse, DG match, live notes). `PromptComposer` holds the parameterized
  composition (recap depth + language rule, listener/speaker, summary-by-mode)
  behind an injected resolver, so the same logic serves both pure defaults and
  app overrides.
- **New `PromptStore` (app).** `@Observable @MainActor`, UserDefaults-backed
  override layer mirroring `GlossaryStore`. Resolves override-or-default, records
  the default's hash at edit time to detect when a shipped default later drifts
  from a saved override, and validates edits against required tokens.
- `PromptCatalogue` kept as the pure default-resolved facade (its API and tests
  unchanged); the four analysis controllers and `LLMController` now resolve their
  prompts through `PromptStore`, and the dead `static let` prompt bodies were
  removed.

### Features

- **Settings → Prompts tab.** Sidebar of all prompts grouped by area, a
  monospace editor per prompt, per-prompt Reset / Revert / Save, a global
  "Reset all", an "edited" / "default changed" badge, a JSON-contract warning
  when an edit drops a load-bearing token, and an assembled-prompt preview for
  the composed recap leaves.
- **Export defaults → offline lab.** "Export defaults…" writes the shipped
  prompts as JSON; `scripts/prompt-lab` now reads that file instead of its
  hand-maintained Python copy, ending the Swift↔Python drift.

### Verification

- `xcodegen generate && xcodebuild … test` — **174 tests passed, 0 failures**
  (8 new `PromptRegistryTests`). Release/Debug build succeeds. `swiftformat` run
  on all touched files; prompt-lab loader round-trip verified.

## 2026-06-23 — UI layer refactor, accessibility, and overlay type-checker fix

Addressed the issues surfaced by a multi-angle static review of the SwiftUI overlay layer.

### Architecture

- **Split the monolithic `OverlayTabs.swift`**
  - Extracted `OverlayTabBar.swift` (tab enum + tab bar + setup button).
  - Extracted `OverlayRecordControls.swift` (record button, aux button, pulsing dot).
  - Extracted `OverlaySharedChrome.swift` (`OverlayToolbarButton`, `overlayEmptyState`, `hoverHighlight`).
  - `OverlayTabs.swift` now contains only the six tab views. This also resolves the Swift type-checker timeout that the added accessibility modifiers triggered in the original 1,535-line file.

### Accessibility

- Added `accessibilityLabel` / `accessibilityHint` to icon-only controls: Setup button, tab buttons, mic mute/device menu, record/aux buttons, composer send/stop/actions/more buttons, toolbar buttons, and chat copy/regenerate buttons.
- Tab selection is now exposed to VoiceOver via `accessibilityValue("Selected")`.

### Bugs

- **Fixed stale transcript paragraphs in `TranscriptTabView`.**
  - The cached `paragraphs` array previously rebuilt only on `liveEntries.count` changes. If Soniox replaced the last entry's text in place, the cache stayed stale. It now also rebuilds when `liveEntries.last?.id` changes.

### Performance / behavior

- **`ResponseView` no longer scrolls on every streaming token.**
  - Previously the chat scrolled on `entries.last?.text` changes, which yanked the user back to the bottom while they were trying to read earlier turns. It now scrolls only when `entries.count` or `entries.last?.id` changes (new turn added / stream started).
- **`LiveTranscriptView` uses `TimelineView` for elapsed time.**
  - Replaced the manual `Timer` + `MainActor.assumeIsolated` updates with the same `TimelineView(.periodic)` pattern already used by the overlay record button.

### Bugs

- **Centralized live translation config.**
  - Added `TranslationStore.currentConfig()` as the single source of truth and made `SessionCoordinator` observe `UserDefaults.didChangeNotification` to update `translationConfig`.
  - Removed the three-way write race between `TranscriptTabView`, `LiveTranscriptView`, and `TranslationPanelView`, where each pushed its own copy of `TranslationConfig` from `.onAppear`/`.onChange`. Views still bind their controls to the same `UserDefaults` keys; `SessionCoordinator` is now the only writer to the audio pipeline's translation config.

### Build

- Ran `swiftformat` on all touched files.

### Verification

- `xcodegen generate && xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Debug -destination 'platform=macOS' test`
  - **165 tests passed, 0 failures.**
- `xcodegen generate && xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Release -destination 'platform=macOS' build`
  - Release smoke build completed successfully.

## 2026-06-23 — Bug fixes, UI perf cleanups, and installed build refresh

Fixed the critical issues found in a static review of the codebase, plus the larger UI/perf items that were safe to cache or debounce.

### Fixed bugs

- **Timestamped transcript ignored `sinceMs`** (`RTI/Sources/Analysis/TranscriptAnalysis.swift`, `RTI/Sources/Session/TranscriptContext.swift`)
  - `TranscriptAnalysis.fetchTranscript` now passes `sinceMs` to `TranscriptContext.textWithTimestamps`. This stops `DiscussionGuideController` and `FindingsController` from re-analyzing the entire transcript on every scheduler tick.
  - Added a `sinceMs` parameter to `TranscriptContext.textWithTimestamps`; speaker numbering is still derived from the full session so labels stay stable across windows.

- **AutoAssist advanced its watermark on LLM failure** (`RTI/Sources/Analysis/AutoAssistController.swift`)
  - The watermark is now advanced only after a non-empty LLM response is accepted. Failed or empty responses no longer permanently skip the current transcript window.

- **Manual "Check for Updates…" never checked** (`RTI/Sources/Update/UpdateChecker.swift`)
  - `checkAndReport()` now actually calls `checkForUpdate()` and presents the download dialog when a newer release exists, or an "Up to date" alert otherwise.

- **YAML frontmatter values not escaped** (`RTI/Sources/Session/SessionArchive.swift`)
  - `workstreamSlug` and `linkedMeeting` are now written through a `yamlQuoted` helper that escapes backslashes, double quotes, and whitespace. This prevents meeting names or slugs containing colons, quotes, or newlines from corrupting the frontmatter.

- **LLM send had no re-entrancy guard** (`RTI/Sources/LLM/LLMController.swift`)
  - `performSend` now returns early if a stream is already in flight, preventing rapid hotkey/menu clicks from churning or corrupting the chat stream.

### Performance / latency improvements

- **Transcript paragraph caching**
  - `LiveTranscriptView` and `OverlayTabs.TranscriptTabView` now cache their coalesced speaker paragraphs in `@State` and rebuild only when `liveEntries.count` changes (or, for the overlay tab, when translation is toggled). Previously both views re-coalesced the full transcript on every SwiftUI render.
- **Response view scroll debouncing**
  - `ResponseView` now debounces token-driven scroll-to-bottom requests. A fast SSE stream queues at most one scroll every 50 ms instead of one per token.
- **Transcript context double work removed**
  - `TranscriptContext.text` no longer calls `entries(sinceMs:)` twice per analysis turn.

### Build / install

- Ran `swiftformat` on all touched files.
- Rebuilt and copied the Release `RTI.app` to `/Applications/RTI.app` so the running copy matches the fixed source.

### Verification

- `xcodegen generate && xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Debug -destination 'platform=macOS' test`
  - **165 tests passed, 0 failures.**
- `xcodegen generate && xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Release -destination 'platform=macOS' build`
  - Release smoke build completed successfully.
- `codesign --verify --deep --strict /Applications/RTI.app` passes.
