# RTI Change Log

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
