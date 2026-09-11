# RTI house-style migration: Quick AI and AI Chat grammar

Date: 2026-09-12. Status: plan only. No code changed.

Goal: RTI looks and behaves like Quick Launch's Quick AI and AI Chat wherever a person asks and RTI answers. The live meeting cockpit (recording, mic, timer, pause, transcript stream) keeps its own form.

Sources read:

- RTI `main` at `ab18010` (clean tree): `CLAUDE.md`, `RTI/project.yml`, all of `RTI/Sources/UI/**`, `OverlayPanelView.swift`, `OverlayWindowController.swift`, `AppDelegate.swift`, `RTIApp.swift`, the chat path in `LLMController.swift` and `ExternalDocumentAttachment.swift`, the title path in `SessionArchive.swift`, `RenderTests/SlateRenderProofTests.swift`.
- Quick Launch `main` at `8ee19aa`: the nine reference files named in the brief, plus `DesignTokens.swift`, `SlateChrome.swift`, `MarkdownTextView.swift`, `Package.swift`.
- House spec `design-system/docs/chat-surfaces.md` (written in parallel, read at the end). This plan follows it. Where RTI must differ, the row says so and names the spec section.
- Render proofs: `/tmp/rti-render-proof/*` (6 Sep; since then only token syncs landed, so they still show the current UI) and `/tmp/quick-launch-render-proof/` (`quick-ai-*`, `b2-*`, `att-*`, `search-*`, `c-*`, `g3-*`, `slate-settings-*`).
- The live session archive (read only): `~/vault/kb/databases/projects/personal/rti/sessions/`, the meeting notes in `~/vault/kb/databases/meetings/`, and `~/Library/Logs/RTI/`.

I did not build, test, launch, or install anything. RTI's `CLAUDE.md` gives a build command but no test command, so I did not run the render proofs (brief rule).

---

## 0. Findings that shape the plan

1. **"Untitled session" has a root cause, and it is not the browser.** The title is a side effect of the end-of-session summary call (`SessionArchive.writeAutoSummary` asks for a `TITLE:` first line). When the summary fails, no `title.txt` is written. The logs show `auto-summary: empty response` or `failed/timed out` at least 12 times between 1 and 7 Sep. In the archive, 33 of 88 session folders have no `title.txt`. Seven of those are real meetings (21 KB to 152 KB transcripts, 31 Aug to 7 Sep). All seven already have a good title in the vault: the meeting processor wrote a note whose frontmatter says `source: rti-session-<stamp>` (for example `20260904-briefing-project-zeta-scope.md`, "Acme Project Zeta, proposal scoping call with Emma Yu"). RTI never reads it. Fix: a title resolver that does not depend on the summary (section 3). The empty-summary bug itself (probably the smart model returning reasoning only on long transcripts; not verified) is a separate LLM-pipeline fix. Do not bundle it into the UI work.
2. **Two settings shells, and the render proof checks the one users never see.** `⌘,` goes to `WindowCoordinator.openSettings()`, which opens the "Library & Preferences" window (`SessionsControlView`, 1120 × 760, sessions, preferences, and logs in one sidebar). The house-style `SettingsView` (the one in `settings-general-*.png`) is reachable only through the SwiftUI `Settings` scene, whose menu command is replaced. So the settings proof proves a surface that is not in use.
3. **The command palette and the Meeting Brief window are not reachable.** `CommandPaletteView` is not mounted anywhere (only the render proof hosts it). `view.brief` is a registry command with no menu item, no hotkey, and no palette. Quick AI's `⌘K` circle is the natural home for RTI's existing command registry.
4. **Global hotkey collision with Quick Launch.** RTI registers `⌘\` (toggle overlay) as an always-on Carbon hotkey. A Carbon hotkey takes the chord system-wide. The house uses `⌘\` for "Show Chat List" in AI Chat (spec section 5). Expected result today: `⌘\` in Quick Launch's AI Chat toggles RTI instead. Not tested (I did not launch either app).
5. **Platform floor.** Quick Launch is macOS 26 (Swift tools 6.2). RTI is macOS 14 (Swift 6.0). `SWIFT.md` rule 6: do not raise a floor to use an API. The reference thread and window use macOS 15/26 APIs (`ScrollPosition`, `onScrollGeometryChange`, `onScrollPhaseChange`, `WindowDragGesture`, `onModifierKeysChanged`, `Observations`). Port with the macOS 14 fallbacks listed in chat-surfaces.md ("Floor" table). The look does not need the newer APIs.
6. **No shared component package exists.** Each house app copies views from Quick Launch. That is the spec's method ("copy those views; keep the view names"). It drifts over time. For now: copy, keep names, and put a header line `// Copied from quick-launch@8ee19aa Sources/Views/<file>` in each copied file, so a later extraction into a shared Swift package can find every copy. A shared package is the durable fix. It is out of scope here.
7. **Bugs found on the way** (fix inside the owning package):
   - `LLMController.sendAskAnything`: `"(prepared.references.count) attached sources"` has no `\`. The trace shows the literal text. (Package A.)
   - `ComposerTextView.ReturnHandlingTextView.keyDown` sends on Return without checking `hasMarkedText()`. With pinyin input, Return that should commit the composition probably sends the draft. Likely, not tested. (Package B.)
   - The stop button is a `danger` red tile. Red is reserved for recording ("the only chroma"). (Package B.)
   - Source traces open in an `NSPopover`. A popover is its own window and does not inherit `sharingType = .none`, so it can probably show in a screen share. Menus (the `✦` menu, project picker) likely have the same issue. The in-window floating layers of the house grammar fix this. Expected, not verified. (Packages A and B.)
   - `NSPasteboard.copyString` writes generated text with no transient markers (spec "Do not" list). (Package A.)
   - `testSessionsBrowser` renders the real vault (real names and meeting content go into `/tmp`, and the image changes every day). (Package D gives it a fixture archive.)

---

## 1. Surface map

Grammar references are to `chat-surfaces.md` sections (H = header §1, T = thread §2, C = composer §3, A = attachments §4, R = rail §5, F = find §6, W = window chrome §7, L = live surfaces §8).

| # | RTI surface today (file) | House component to use | What changes (look and behaviour) | What must stay (live cockpit) |
| --- | --- | --- | --- | --- |
| 1 | Overlay window (`OverlayWindowController.swift`): titled window with a visible "RTI" title bar, clear background, glass (`SlateGlassBackground`), 700 × 440 default, size sliders in Settings | AI Chat window chrome (W; `AIChatWindowController.prepareWindow`) | `.fullSizeContentView`, hidden title, transparent title bar, empty unified toolbar so the header shares the traffic-light row. Opaque `surface` ground, not glass (cheaper to composite during a call). Frame autosaved by name, as AI Chat. `esc` no longer hides the window (see section 2). Width and height sliders go. | `sharingType = .none` (undetectable). Close button hides, never quits, never stops the recording. `isReleasedWhenClosed = false`. Min width 600 (the render proof asserts it); do not adopt AI Chat's 720 min. Opens top-left of the screen under the pointer on first launch. |
| 2 | Top bar (`OverlayPanelView` HStack: Prepare button, tab bar, mic, eye, project, record chip, pause) with a divider | Chat header (H) in its live form (L): title block left, one live action right | Row height `Control.composer` (52), no divider. Title block: session name in subheading over a state line in `meta` with a 6 px `StatusDot` and a word ("Recording · 12:41 · DeepSeek V4 Flash · Meeting mode"). The model part is a button (change provider). The mode name is a button like Quick AI's assistant name (change mode). Right slot: the capture cluster, then the record chip as the one live action ("Finish ⌘⇧R" while live). | Record chip: `danger` dot plus clock, the only chroma. Pause/resume chip. Mic mute with its level bar and device menu. Screen-context eye with its states and words. Project picker. All keep their controls, words, help text, and accessibility values. |
| 3 | Tab bar (`OverlayTabBar.swift`, `OverlaySetupButton`) | No Quick Launch equivalent. Keep, restyled with house chips | Moves to a second row under the header, `Control.railRow` (36) high, icon plus name on the selected tab (as now). Tab titles and icons unchanged. | Tabs: Prepare, Assist, Auto, Transcript, Notes, Guide, Intel. Opt-in visibility from Prepare. The Auto unread dot. Prepare → Assist hand-off when recording starts. |
| 4 | Footer well (`OverlayFooterBar`, `SlateFooter`): status dot, "Recording · DeepSeek · Meeting mode", key hints | None (L: "Footer: none") | Deleted. Status moves to the header's second line. Key hints move to the `⌘K` palette rows and to help text. | The status word next to its dot (never colour alone). |
| 5 | Assist answer area (`ResponseView.swift`) | Thread (T; `QuickAIThread`) | One centred column; question pills right; prose left with no card; tool and status lines; inline sources; error line with Retry; empty hints; "Latest" chip. Detail in section 4. | Chat stays in memory per session and is cleared on a new session. No chat store in RTI (`CLAUDE.md`). Follow-bottom while streaming. |
| 6 | Canned-action chip (Assist, Recap, Say next) drawn left | User pill (T) | A canned action becomes a right-aligned pill that shows the action name with its glyph ("Assist", "Recap · brief"), never the internal prompt. RTI divergence: the pill carries a glyph. Register it. | The action name stays visible, so the answer's origin is clear. |
| 7 | "Viewed screen / Viewed conversation" captions over the question | Tool lines (T) | Become tool lines above the answer: `waveform` "Used the last 6 min of the transcript", `camera.viewfinder` "Read the screen". | Same facts, same honesty about context. |
| 8 | Sources chip plus `SourceTracePopover` | Sources list (T) | Quiet list under the prose: up to 5 rows (`doc.text`, title, day), then "N more in ⌘K › Open Source". A row opens the file. No popover. | Vault paths remain visible (tooltip) and copyable (`⌘K` › Copy Sources). |
| 9 | `WorkingStatusView` (spinner in a chip), " ▍" caret, `isProgressText` string sniffing | Status line with `ThinkingIndicator` (T) | Dots plus status text in `bodySmall` `textTertiary`. Progress comes from structured tool records, so the string sniffing goes. | "Searching the vault…" and the other progress words. |
| 10 | Error text plus a bordered prominent "Open Settings…" button | Error line (T) and composer error (C) | Error under its question with Retry `⌘R`. Errors with no turn (missing key) sit above the composer with an `InkButtonStyle` fix-it button. | `SessionCoordinator.lastError` still shows (it is a capture error, not a chat error): above the composer, `meta` `danger`. |
| 11 | Empty state: "Ready when you are" plus three example chips; missing-keys card | Empty hints (T) | Three centred hint lines with real keys: "⌘↩ runs Assist", "@ adds a vault file", "⌘K for actions". Missing keys: two hint lines and the fix-it above the composer. | Example prompts may live on in `⌘K` as rows. |
| 12 | Composer (`AssistantInputView.swift`): raised 52 px card, `✦` menu, text view, paperclip, Note toggle, square ink send tile or red stop tile | Composer row (C; `QuickAIComposer`, multi-line variant) | Plus circle, stroked pill field with the primary action and its key cap inside, `⌘K` circle. Detail in section 4. | Multi-line draft. Enter sends, Shift-Enter adds a line. Draft cleared when a session stops. `rtiSeedChatMention` hand-off from Sessions. Focus on window key. |
| 13 | `✦` Assist actions menu (quick actions, "⌘⏎ runs", recap depth, listener, fieldwork preset, smart mode) | `⌘K` circle and action palette (C; `QuickActionPalette` placement) | The circle opens RTI's own registry (`CommandRegistry`, already built for menu and hotkeys) as a floating palette bottom-right, in-window. The `✦` menu goes. `CommandPaletteView` gets a job. | Every item keeps its behaviour and its hotkey. Mode-aware quick actions (`llm.availableQuickActions()`). |
| 14 | Paperclip, context dashboard pill ("Context · 3 sources" menu), "Screen · once" pill, Smart pill | Plus circle, Add Context layer, attachment strip (C, A) | Plus (or typed `@`) opens Add Context: Attach file (PDF, Markdown, text), Vault file (@), Read screen once (`⌘⇧H`), Search scope (whole vault, project, client). Chosen items become chips in the strip. Smart mode shows in the title block's model line ("DeepSeek V4 Pro · Smart"), not as a pill. | Vault scope choice. Screen OCR once. The on-device OCR rule (no image leaves the Mac). |
| 15 | @mention list and slash-command chip row, inline above the field | Floating chooser (C; `QuickAIFloatingChooser`) | Both float above the composer at full inner width on panel glass, `↑↓` and `↩`. | All 15 slash commands and their aliases. Mention search (`MentionSuggestionStore`, cached, off the main thread). |
| 16 | Note toggle (yellow tint and yellow stroke on the whole composer) | Composer states (C) | No colour. Note mode changes the placeholder ("Note to the transcript…" or "Prep note for this meeting…") and the action label ("Add Note ↩"). `⌘⌥N` and `/note` toggle it. The toggle itself moves to `⌘K` and the plus layer. | Note mode semantics: during a session a note goes into the transcript; before it, into the prep note; then back to chat. |
| 17 | Send tile (ink square) and stop tile (red square) | Action inside the field (C) | Empty field: "Assist ⌘↩" (RTI divergence: the primary action, not "Ask"; register it). Typed text: "Ask ↩". Streaming: "Stop esc". Note mode: "Add Note ↩". | Primary-action binding (`llm.primaryActionID`). |
| 18 | Transcript tab (`TranscriptTabView` in `OverlayTabs.swift`) | Stays its own body (L). Reuse only the "Latest" chip | Header strip aligned to the 52/36 rows; empty state as hint lines. Rows unchanged. | Speaker chips with the six speaker colours, click-to-rename, timestamps, interim line, translation line, health dot and word, copy. |
| 19 | Notes, Guide, Intel, Auto tabs | Empty hints; `OverlayToolbarButton` restyled to `QuickAIGlyphButton` | Empty states become hint lines; toolbar glyphs 28 square. Content unchanged. | All analysis content and cadence. |
| 20 | Prepare tab (`SetupTabView`, settings-card grammar) | Settings cards | Align card padding and row heights with the settings shell. | Calendar pick, project picker, live-aid toggles, discussion-guide import. |
| 21 | Sessions browser (`SessionsBrowserView.swift`, `HSplitView`, "Untitled session" rows) | AI Chat window with rail (W, R) plus a reader | Own window; hidden rail with search and snippets; real titles. Section 3. | Read-only reading of the archive. Edit title, name speakers, upgrade transcript, regenerate summary, export, reveal. Deep link from "Notes ready". |
| 22 | Library & Preferences window (`SessionsControlView`, `SessionsControlWindowController`) | Split: Sessions window (W) plus the settings shell | This window goes away. Sessions gets the AI Chat shape; preferences go to `SettingsView`. | Every pane (Providers, Modes, Prompts, Glossary, Voices, General, Logs). |
| 23 | `SettingsView` (house shell, not reachable today) | Quick Launch settings shell (`slate-settings-*`) | Becomes the one settings window, 860 × 620, 220 rail. Section 5. | All settings keys and their effects. |
| 24 | Onboarding (`OnboardingView`, 520 × 640) | Quick Launch welcome (`g3-welcome-*`) | Icon tile, title, one line, key hints, then the two setup cards, one full-width "Get Started". Section 5. | Keys step, mic permission, optional screen permission. |
| 25 | Command palette (`CommandPaletteView`, not mounted) | `⌘K` palette (C) | Mounted in the overlay composer (row 13), also on `⌘K` in the Sessions window (session actions). | Registry order, recents, hotkey caps. |
| 26 | Meeting Brief window (`MeetingBriefView`, `NavigationSplitView`, not reachable) | AI Chat reader shape (W, R) | Rail of briefs hidden by default, reader in the column; reachable from `⌘K` and the Prepare tab. | Read-only; RTI never writes briefs. |
| 27 | Main menu (SwiftUI default from the `Settings` scene) | `AIChatMenu` structure (W), built with SwiftUI `.commands` | Section 2. | Quit guard during recording. |
| 28 | Status item (`MenuCoordinator`) | Status item component (already compliant) | No change, except items and titles follow the renamed commands. | Timer in the menu bar is the one recording indicator. No floating HUD. |
| 29 | "Summary ready" notification | `AnswerNotice` style | Already one line and no sound. Title becomes the resolved session title. | Tap opens that session. |
| 30 | `AudioMonitorView` | None | Not mounted anywhere. Leave it; mention it to the owner. | n/a |

---

## 2. Window and menu-bar behaviour

RTI is a regular Dock app (`LSUIElement = NO`, decided 1 Sep) and the sole meeting recorder. Quick Launch is a menu-bar app that becomes a regular app only while AI Chat or Settings is open. So copy the window rules, not the accessory dance.

| Concern | Quick Launch today | RTI today | Proposal for RTI |
| --- | --- | --- | --- |
| Activation policy | `.accessory`, switches to `.regular` while a titled window is open (`AppActivation.becomeRegularApp`), back on last close (`settleAfterClosing`) | Always `.regular` | Stay `.regular`. Do not port `becomeRegularApp`/`settleAfterClosing` or `WindowPresence`. |
| Bring to front | `bringToFront`: `makeKeyAndOrderFront`, `NSApp.activate()`, then `NSWorkspace.openApplication(activates: true)` if still not active | `NSApp.activate(ignoringOtherApps: true)` in 7 places (deprecated on 14; banned by the spec) | Port `bringToFront` alone as `RTIActivation.bringToFront(_:)`. Replace all 7 calls; each package replaces the calls in the files it owns. This fixes the case where `⌘\` from another app shows the overlay but typing still goes to the app behind. |
| Menu bar | `AIChatMenu` installed while the chat window is open | SwiftUI default menus (App, Edit, View, Window, Help) plus a replaced "Settings…" | Keep the SwiftUI App lifecycle and add `.commands` groups; do not assign `NSApp.mainMenu` (SwiftUI rebuilds it). Menus: **RTI** (About, Settings… `⌘,`, Check for Updates, Hide, Quit RTI `⌘Q`); **Edit** (standard, plus Find in Chat `⌘F` in the overlay, Find in Session `⌘F` in Sessions); **Session** (Start/Finish `⌘⇧R`, Pause `⌘⇧P`, Add Note `⌘⌥N`, Mute Microphone, Read Screen `⌘⇧H`, Pick Project); **View** (Assist, Transcript, Notes… as `⌘1`…`⌘7` local, Show Session List in Sessions); **Window** (Minimize, Zoom, Keep on Top, Close `⌘W`, RTI, Sessions). Items validate against the key window, as `AIChatMenu.validateMenuItem` does. |
| `⌘Q` | Closes AI Chat; `⌥⌘Q` quits (protects the launcher) | Quits, with a "Recording in progress / Wait / Quit Anyway" alert while a session runs or finishes | Keep `⌘Q` = quit, with the existing guard. The Quick Launch rule protects a hotkey-only app; RTI is a Dock app and its guard already protects the recording. |
| `⌘W` | Closes the chat window; the stream goes on | Default close (hides the overlay) | Same as now: hides, recording and streaming continue. |
| `esc` | Pops one layer (chooser, stream, typed text); never closes the window | `cancelOperation` hides the overlay | Change to the house rule: chooser or palette, then find bar, then stream, then typed text, then nothing. A stray `esc` mid-meeting must not hide the cockpit. Hide stays on `⌘W`, the close button, and the global toggle. |
| Keys in the window | `AIChatWindow.sendEvent` takes `↩`, `⇧↩`, `esc`, skips marked text | `OverlayWindow` only overrides `becomeKey` and `cancelOperation`; the text view handles Return | Subclass as `AIChatWindow` does, marked-text aware. Keeps Return safe for Chinese input. |
| Focus | `FocusRequest.apply` on open and on request | `rtiOverlayDidBecomeKey` notification, deferred one tick | Keep the notification (it avoids a known layout recursion), route it into a `FocusRequest`-style counter on the composer. |
| Keep on Top | Window menu toggle, default off | Removed on 1 Sep ("no float") | Optional: offer it as a Window menu item, default off. Useful over Zoom. Skip it if the 1 Sep decision was about predictability. |
| Global hotkeys | `⌥Space`, `⇧⌘T`, `⌃⌥C` | Always on: `⌘\`, `⌘⇧R`. Session only: `⌘⏎`, `⌘⇧P`, `⌘⌥N`, `⌘⇧H`, quick actions | `⌘\` clashes with the house rail toggle (finding 4). Recommendation: move RTI's global show/hide to `⌥⌘\` and use plain `⌘\` locally for rails, as the house does. This needs Tristan's yes (muscle memory). |
| Undetectability | n/a | `sharingType = .none` on the overlay only | Keep. All new layers (choosers, palette, find bar) are in-window SwiftUI overlays, so they inherit it. Remove popovers from the overlay. |

---

## 3. Sessions browser

### Today

`HSplitView`: a 228 to 320 px list on the left (heading "Sessions", "97 saved meetings", date groups, rows "Untitled session / 15:00 •"), a reader on the right (title, file pills, Copy, Ask, a `⋯` menu, the document, a footer well). It lives inside the Library & Preferences window. The spec says: no split pane by default.

### Proposal: a Sessions window in the AI Chat shape

- **Window.** Its own `SessionsWindowController`, W chrome: 860 × 620, min 720 × 480, opaque `surface`, header in the traffic-light row, frame autosaved. Opened from the menu bar, the status item ("Sessions"), `⌘K`, the record chip after "Notes ready", and notification taps.
- **Header** (H, window form). Left: `sidebar.left` rail toggle. Title block: the resolved session title over "Sep 4 · 15:00 · 16 min · Acme Project Zeta · Transcript upgraded". Right: a labelled chip "Ask in RTI ⌘J" (seeds the session as an @mention in the overlay composer, the current `askAboutSession`), then a glyph for the session's `⌘K` actions.
- **Rail** (R). 220 wide on `surfaceSunken`, hidden until `⌘\` (local) or the toggle. First open with no session selected shows it; a deep link (notification, "Notes ready") opens with it hidden, on that session. The choice is remembered.
  - Search field "Search sessions…".
  - Sections: **LIVE** (one row while a recording runs; it opens the overlay), **TODAY**, **THIS WEEK**, **EARLIER** (house date groups instead of Pinned/Recent; RTI has no pinning, do not add it).
  - Row: title in `label`, second line in `meta` `textTertiary`: "15:00 · 16 min · Project". Open-session ink marker. `⌘1`…`⌘9`.
  - `⌘K` on a row: Rename, Name Speakers, Upgrade Transcript, Regenerate Summary, Save as Markdown, Save as PDF, Reveal in Finder, Ask in RTI. Same actions in the context menu and VoiceOver actions. No Delete (the archive belongs to the vault).
- **Reader.** The file pills (Notes, Transcript, Chat, Screen, Screenshots, Log) stay as chips under the header, not a second toolbar. The reading column uses the thread width (710 max, centred). `chat.md` renders in the thread grammar, read only (question pills and prose), so a past Assist chat looks like it did live. Footer well goes; "Transcript ready" moves to the header's second line.
- **Find** (F). `⌘F` finds in the open document.

### Search with snippets, inside RTI's rules

`CLAUDE.md` forbids RTI-side indexing: no embedded DB, no in-app full-text index. Quick Launch searches its own chat store; RTI must not build one. Two tiers:

1. **Titles and metadata, local, no index.** Filter the loaded rows in memory by title, project, date words, and speaker names. Instant. This is filtering, not an index.
2. **Content, through the vault.** For a query of 3 or more characters, after a 250 ms pause, call the existing `VaultSearchCLI` scoped to RTI sessions and the meetings folder. Show the returned passage as the row's snippet ("Transcript: …thin **zero** scope…", match in `meta` medium `textPrimary`), per spec R "Snippet". Rows found only by content go under RESULTS. The Neon warm-up at launch already exists. If the CLI is down, tier 1 still works and the rail says "Content search unavailable" in `meta` `textTertiary`.

Do not grep 88 transcripts (up to 152 KB each) on every keystroke. It would work, but it is the in-app full-text search the rules exclude.

### Generated titles (fixes "Untitled session")

A pure `SessionTitleResolver` in `RTICore` (testable without the app). First hit wins:

1. `title.txt` with `title-manual.txt` present (user edit).
2. `title.txt` from the summary call (today's only source).
3. The vault meeting note whose frontmatter has `source: rti-session-<yyyyMMdd-HHmmss>`: its `title:`. Checked on disk today: 49 of 1,088 meeting notes carry an RTI source, and all 7 untitled real meetings resolve. Build the map once per list load, off the main thread, frontmatter only (first 40 lines), kept in memory only.
4. The calendar event title picked in Prepare. Today it is not saved. Package D adds `calendarTitle` to `session.json` through `SessionArchiveMetadata` (the session writer calls it; see risks).
5. A short generated title: one cheap call (the flash model, not the smart one) over the `notes.md` slice headings (small input, a few hundred characters). Run lazily by the Sessions window, one session at a time, only for sessions with notes and no title; write `title.txt`. This keeps the call out of the recording and finishing path.
6. A descriptive fallback, never "Untitled session": "Meeting · Sep 4, 15:00 · 16 min", or "Short test · 12 s" when the transcript is under 1 KB.

In the live overlay, the header title uses 4, then the project name, then "Live session".

---

## 4. Assist thread and composer

### Thread (replaces `ResponseView`)

Copy `QuickAIThread` structure; keep its name inside RTI as `QuickAIThread` or `AssistThread` with a copy header. Adapter reads from `LLMController` only: `entries`, `streaming`, `toolStatus`, per-turn tool and source records, `lastError`.

| Element | RTI content | Spec |
| --- | --- | --- |
| Question pill | Typed question; canned action shown as its name plus glyph | T "User pill", `Radius.pill`, `chipFill`, `bodySmall` `textSecondary`, max 690. Long questions collapse (`CollapsibleMessageText`). |
| Sent chips | @vault files, attached PDFs and text files, "Screen" | A "Sent attachments": read-only chips over the pill (`AttachmentPillChips`). Needs `ChatEntry` to carry attachment refs; today it only has `referencedPaths`. |
| Tool lines | Parsed from today's trace lines into records: `archivebox` "Searched vault · 6 results", `doc.text` "Read Q3 report.pdf", `calendar` "Checked recent meetings", `folder` "Listed files", `magnifyingglass` "Searched vault text", `waveform` "Used the last 6 min of the transcript", `camera.viewfinder` "Read the screen" | T "Tool or status line". Records live on the turn, so a finished answer draws the same lines. |
| Status while streaming | "Thinking…", "Searching the vault…", "Reasoning…" with `ThinkingIndicator` | T "Streaming". |
| Answer prose | Markdown | Keep MarkdownUI (an existing dependency). Restyle it to the spec: `body` 14, line height 1.55, max width `Layout.answerMaxWidth` (620; the RTI token, since the overlay can be 600 wide), code blocks on `well` with a header strip. Porting `MarkdownTextView` would add `swift-markdown`, a new dependency (`CLAUDE.md`: keep deps minimal). The user font-size setting (12 to 18) still scales the prose; default 14 = the token. |
| Sources | The trace's `.md` paths | T "Sources list"; rows open in the Sessions window (RTI sessions) or reveal in Finder (other vault files). |
| Actions on an answer | Copy, Regenerate (hover bar); the Summary answer shows them always | Move to `⌘K` (Copy Response, Regenerate `⌘R`, Copy Sources). Keep a hover Copy like Quick Launch's `w2-copy-message`. Drop the "always show" special case. |
| Error | `lastError`, auth errors | T "Error line", Retry `⌘R`; auth error above the composer with "Open Settings". |
| Latest chip | none today | T "Latest chip", `⌘↓`. Build with `ScrollViewReader` and a bottom sentinel (macOS 14 fallback). |

### Composer (replaces `AssistantInputView` chrome, keeps its logic)

Row (C): plus circle, pill field, `⌘K` circle, `Spacing.xs` inset, 52 total.

- **Field.** Keep the `NSTextView` field (it already grows, handles Return and Shift-Return, and suits Chinese input) but fix marked text, then wrap it in the pill: `RoundedRectangle(cornerRadius: Radius.pill, style: .circular)` stroke, no fill, `bodySmall`, grows to 8 lines, circles on the last line.
- **Placeholder** (overlay, not the prompt): idle "Ask the vault, @ a file, or / for commands…"; recording "Ask about this meeting…"; note mode "Note to the transcript…" or "Prep note for this meeting…"; streaming "Type a follow-up; it sends when this answer ends".
- **Action in the field:** "Assist ⌘↩" when empty, "Ask ↩" with text, "Stop esc" while streaming, "Add Note ↩" in note mode, "Queued ↩" when Return is pressed during a stream (spec C "Queued"; new for RTI, cheap: hold one draft).
- **Plus / `@`:** Add Context layer (row 14 of the table).
- **Strip** (A): chips for @vault files (`doc.text`, the file name, the vault path in the tooltip), documents (`doc.richtext` for PDF: "12 pp · 84 KB"; `text.alignleft` for text: "18 KB"; "· cut" when the 24,000-character cap cut it, which today happens silently), and Screen ("Screen · once"). Remove buttons, `⇧Tab` into the strip, Backspace removes. The strip replaces the context dashboard pills.
- **Drop:** the composer and the thread accept a drop (A "Drop target"): images go to OCR as today, files load as documents.
- **`⌘K`:** registry palette (row 13).
- **Slash and mention:** floating choosers.
- **Must keep:** draft cleared on `rtiSessionDidStop`; seeding from Sessions; mention cache and prewarm; the 512 KB and 24,000-character limits; no document copied into the vault.

---

## 5. Settings and onboarding

**Settings.**

- One window: `SettingsView` in its own `SettingsWindowController`, 860 × 620 (`Layout.settingsWidth` × `settingsHeight`), 220 rail. `⌘,` opens it. Remove the settings half of Library & Preferences.
- Panes: Providers, Modes, Prompts, Glossary, Voices, General, Logs (rename "Diagnostics" if it reads better), About. `⌘1`…`⌘8` with key caps in the rail. "Search settings…" field on top of the rail (as Quick Launch).
- Footer: "Applies immediately" left, "Next ⌘n" right. Remove the "Close" button in the header and the "Close esc" hint (Quick Launch has neither; `esc` and `⌘W` close the window).
- General: delete the accent colour and contrast controls (accent no longer paints chrome, per the code's own comment; Quick Launch has Appearance only). Delete the overlay width and height sliders (the frame is autosaved). Keep: Appearance (System, Light, Dark), text size (RTI-specific, meeting legibility), speaker palette, Reduce Motion, screen privacy list, capture access, audio input, real-time analysis, hotkeys, data and support.
- Section cards, 40 px rows, ink toggles: already the house grammar (`SettingsCard`). No change.

**Onboarding** (`g3-welcome-*` shape).

- A card with the RTI icon tile (record ring glyph), "Welcome to RTI", one line: "Records, transcribes, and answers during your meetings, out of screen shares."
- Five key hints with icon tiles: "⌘⇧R starts and finishes a recording", "⌥⌘\ shows RTI" (or `⌘\` if the remap is refused), "⌘↩ runs Assist", "@ adds a vault file", "Notes and transcripts save to the vault".
- Then the two setup cards as today (API keys; Microphone and Screen Recording). One full-width ink "Get Started" at the bottom, enabled when both keys and the microphone are in place; before that, the footnote says what is missing.
- Remove the em dashes in the current copy.

**Meeting Brief.** Rail plus reader (row 26), reachable from `⌘K` and a "Brief" link in the Prepare tab when a brief matches the meeting.

---

## 6. Risks

RTI is load-bearing: it is the only meeting recorder. A broken build on meeting day means a lost meeting.

| Risk | Guard |
| --- | --- |
| Breaking recording, transcription, or archiving | No package edits `SessionCoordinator`, `TranscriptPipeline`, `AudioPipeline`, `AudioCaptureManager`, `CoreAudioTapCapture`, `SystemAudioCapture`, `WAVWriter`, `MeetingRecorder`, `SonioxClient`, `TranscriptUpgradeService`, `VaultLogStore`, or the write functions of `SessionArchive`. Package D's edits to `SessionArchive.swift` are limited to the read side (`titleFile`, `recentSessions`); a reviewer checks the diff touches nothing else. The `calendarTitle` write goes through `SessionArchiveMetadata` (a value type) with a default of nil. |
| Swift 6 teardown crash | RTI crashed at session end from `.onHover` closures (fixed with the nonisolated `hoverHighlight`). Copied Quick Launch code uses bare `.onHover` (for example `AttachmentChip.swift:336`). Rule for every package: no bare `.onHover` in RTI; use `hoverHighlight`. Keep `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE`. |
| CPU during a call | The record chip's 1 s `TimelineView` and the mic level's 0.15 s tick must stay in small leaf views. The thread must not read `SessionCoordinator`. MarkdownUI re-parses the whole answer per token: keep the live answer as one view and settled answers as `Equatable` rows. Gate: RTI CPU during a 5-minute recording with one streamed answer, measured with the house method (`design-system/PERFORMANCE.md`, cumulative CPU-time deltas), is not above the pre-change build in the same run. Baseline in that doc: 0.342 % of one core at rest, 110 MB footprint. |
| Screen-share leaks | Keep `sharingType = .none`; no new child windows, popovers, or sheets in the overlay. The integration proof lists every layer and confirms it is in-window. |
| Muscle memory | `esc` no longer hides; `⌥⌘\` (if accepted) replaces `⌘\`; the `✦` menu moves to `⌘K`. Mention all three in `CHANGES.md` and the onboarding hints. |
| Chinese input | Marked-text handling in the field and in `sendEvent`. Unit test on the key router; manual check with pinyin before install. |
| Floor | macOS 14 fallbacks (chat-surfaces.md "Floor"). A package that wants a 15/26 API stops and asks; it does not raise the floor. |
| Parallel merge conflicts | `RTI/RTI.xcodeproj/project.pbxproj` is committed. Packages never commit it; the integrator regenerates it after each merge. New logic goes in `RTI/Core` (globbed into `RTICore`, reached by `RTITests` through `import RTICore`), so no package edits `project.yml`. |
| Render proofs overwrite each other | Unique file prefixes per package (below). |
| Install during a meeting | Only the integrator installs, with `scripts/install-local.sh`, and only after confirming RTI is not recording (menu-bar timer absent; `applicationShouldTerminate` would also ask). Never restart an active recorder. |
| Content search depends on Neon | Tier 1 title filtering works offline; tier 2 degrades with a line of text. |
| Registry drift | `components.json` registers "Composer (RTI)" as the 52 px raised card with an ink send tile. After package B, the design-system owner must update that entry and the render-proof paths. RTI does not edit the design-system repo. |

---

## 7. Build plan

Order: package 0 first (integrator, serial, small). Then A to E in parallel worktrees. Then integration.

### Commands (every package, from the worktree root)

RTI's `CLAUDE.md` gives the build and the regenerate step. It gives no test command; the test line below is from `PRODUCTION-GOAL.md` ("`xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Debug test`"), narrowed with `-only-testing`. Package 0 adds it to `CLAUDE.md`.

```sh
(cd RTI && xcodegen generate)
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug -derivedDataPath .deriveddata build
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug -derivedDataPath .deriveddata test -only-testing:RTITests
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug -derivedDataPath .deriveddata test -only-testing:RTIRenderTests/<ThisPackagesProofClass>
~/Documents/code/house/design-system/bin/design-lint --strict <touched files>
```

`-derivedDataPath .deriveddata` keeps parallel worktrees from sharing DerivedData (the path is gitignored). Proofs land in `/tmp/rti-render-proof/`, dark and light, and the package reads every PNG it produced. No package launches or installs the app.

### Package 0: seams (integrator, before the fan-out)

Owns: `RTI/RenderTests/RenderProofHarness.swift` (new: the harness moved out of `SlateRenderProofTests`, plus fixture builders and a fixture archive directory under `RTI/RenderTests/Fixtures/`), `RTI/Core/LLM/ChatEntry.swift` (add `attachments: [ChatAttachmentRef]`, `tools: [ChatToolLine]`, `sources: [ChatSource]`, all defaulted), `RTI/Core/LLM/ChatTurnRecords.swift` (new: those three types), `RTI/Sources/UI/HouseChat/HouseChatPrimitives.swift` (new: copied `KeyCapGroup`, `KeyHint`, `ThinkingIndicator`, `RowHighlight`, `QuickAIGlyphButton`, `QuickAITitleBlock`-shaped `HouseTitleBlock`, the three derived fonts, `panelGlass`, `raisedCard`, `InkButtonStyle`, with `hoverHighlight` instead of `.onHover`), `RTI/Sources/Settings/SettingsWindowController.swift` (new stub with `show(pane:)` that forwards to today's behaviour), `RTI/Sources/Support/RTIActivation.swift` (new: `bringToFront`), `CLAUDE.md` (test command line only), `RTI/RenderTests/SlateRenderProofTests.swift` (switch to the shared harness; no new proofs).
Tests: existing suites green; one unit test for `ChatEntry` defaults.

### Package A: Assist thread

Owns: `RTI/Sources/UI/Overlay/ResponseView.swift` (rewritten), `RTI/Sources/UI/HouseChat/HouseThread.swift` (new), `RTI/Sources/UI/HouseChat/HouseFindBar.swift` (new), `RTI/Sources/UI/RTIMarkdown.swift` (overlay style only), `RTI/Sources/LLM/LLMController.swift` (turn records: tools, sources, attachment refs from the existing `sendAskAnything(_:attachments:)` arguments; the missing `\` fix; no change to the send path), `RTI/Sources/Support/PasteboardHelpers.swift` (transient markers), `RTI/Core/LLM/ToolTraceParser.swift` (new), `RTI/Tests/ToolTraceParserTests.swift`, `RTI/Tests/ChatTurnRecordTests.swift`, `RTI/RenderTests/AssistThreadRenderProofTests.swift`.
Proofs (prefix `thread-`): empty, missing-keys, searching, streaming, answered-tools-sources, canned-action-pill, attachments-on-pill, error-retry, latest-chip, find, at 700 and 600 wide.

### Package B: composer

Owns: `RTI/Sources/UI/Overlay/AssistantInputView.swift`, `RTI/Sources/UI/Overlay/OverlayInputState.swift`, `RTI/Sources/UI/HouseChat/HouseComposer.swift` (new), `RTI/Sources/UI/HouseChat/HouseAttachmentChip.swift` (new, from `AttachmentChip.swift`), `RTI/Sources/UI/HouseChat/HouseFloatingChooser.swift` (new), `RTI/Sources/UI/CommandPalette/CommandPaletteView.swift` (mounted as the `⌘K` layer), `RTI/Sources/LLM/ExternalDocumentAttachment.swift` (page count, byte size, cut flag), `RTI/Core/LLM/ComposerState.swift` (new: action label and placeholder rules, pure), `RTI/Core/LLM/ComposerKeyRouter.swift` (new: Return, Shift-Return, esc, marked text), `RTI/Tests/ComposerStateTests.swift`, `RTI/Tests/ComposerKeyRouterTests.swift`, `RTI/RenderTests/ComposerRenderProofTests.swift`.
Reads, never edits: `CommandRegistry.swift`, `LLMController.swift`.
Proofs (prefix `composer-`): empty-idle, empty-recording, typed, multiline, streaming-stop, queued, note-mode-live, note-mode-prep, strip-states (reading, ready, failed, cut), add-context, mention-chooser, slash-chooser, palette, drop.

### Package C: overlay shell, menus, hotkeys

Owns: `RTI/Sources/OverlayWindowController.swift`, `RTI/Sources/OverlayPanelView.swift`, `RTI/Sources/RTIApp.swift` (`.commands`), `RTI/Sources/AppDelegate.swift` (activation calls only), `RTI/Sources/UI/Overlay/OverlayTabBar.swift`, `OverlayTabs.swift`, `OverlaySharedChrome.swift`, `OverlayRecordControls.swift`, `OverlayMicControl.swift`, `OverlayTheme.swift`, `RTI/Sources/UI/CommandPalette/CommandPaletteFactory.swift` (menu sections, local `⌘1`…`⌘7`, the `⌘\` change if approved), `RTI/Sources/UI/HotkeyCoordinator.swift`, `RTI/Sources/UI/MenuCoordinator.swift`, `RTI/Sources/Support/SettingsKeys.swift` (drop the size keys' UI use only; keep the keys readable), `RTI/Core/UI/OverlayEscapeOrder.swift` (new, pure), `RTI/Tests/OverlayEscapeOrderTests.swift`, `RTI/Tests/MenuValidationTests.swift`, `RTI/RenderTests/OverlayShellRenderProofTests.swift`.
Proofs (prefix `shell-`): header idle, recording, paused, finishing, done ("Notes ready"); tabs row; transcript tab; notes/guide/intel empty; prepare tab; at 700 and 600 wide. `CommandRegistryTests` must stay green.

### Package D: Sessions window and titles

Owns: `RTI/Sources/UI/SessionsControl/SessionsBrowserView.swift` (becomes the Sessions window view), `SessionsControlView.swift` (deleted or reduced to a shim during the merge), `SessionsControlWindowController.swift` (becomes `SessionsWindowController`), `SessionFramesGallery.swift`, `RTI/Sources/UI/WindowCoordinator.swift` (routing: sessions → new window, `openSettings` → `SettingsWindowController.show`), `RTI/Sources/Session/SessionArchive.swift` (read side only, see risks), `RTI/Sources/Session/SessionArchiveMetadata.swift` (`calendarTitle`), `RTI/Core/Session/SessionTitleResolver.swift` (new), `RTI/Core/Session/VaultMeetingTitleMap.swift` (new, in-memory), `RTI/Sources/Session/SessionTitleGenerator.swift` (new: the lazy flash-model title call), `RTI/Tests/SessionTitleResolverTests.swift`, `RTI/Tests/VaultMeetingTitleMapTests.swift`, `RTI/RenderTests/SessionsWindowRenderProofTests.swift`.
Reads, never edits: `VaultSearchCLI.swift`, `MeetingContextStore.swift`.
Proofs (prefix `sessions-`, fixture archive only, never the real vault): rail hidden, rail shown, live row, search titles, search snippets, search unavailable, row actions, chat.md in thread grammar, find, fallback titles.
Note for the integrator: the session writer must pass `calendarTitle` into `SessionArchiveMetadata`. That call site is in the recording path. Make it a separate, one-line, reviewed commit after D merges, or skip rule 4 of the resolver.

### Package E: settings, onboarding, Meeting Brief

Owns: `RTI/Sources/Settings/SettingsView.swift`, `GeneralTab.swift`, `LogsView.swift`, `VoicesTab.swift` (layout only), `RTI/Sources/Settings/SettingsWindowController.swift` (takes over the stub from package 0), `RTI/Sources/UI/Onboarding/OnboardingView.swift`, `OnboardingWindowController.swift`, `RTI/Sources/UI/MeetingBrief/MeetingBriefView.swift`, `MeetingBriefWindowController.swift`, `RTI/RenderTests/SettingsOnboardingRenderProofTests.swift`.
Reads, never edits: `ProvidersTab`/`KeysTab.swift`, `ModesTab.swift`, `PromptsTab.swift`, `GlossaryTab.swift` beyond the shell they sit in.
Proofs (prefix `settings-`, `onboarding-`, `brief-`): each pane, search in rail, footer; onboarding empty, keys saved, all set; brief rail hidden and shown.

### Shared files nobody edits in A to E

`HouseDesign.swift` (generated; recopy only through `make gen`), `RTIDesign.swift` (new code uses `House.*` directly; note that `RTIDesign.Spacing.lg` is House `xl` 24, a trap when copying), `project.yml`, `project.pbxproj`, everything listed under "Breaking recording" in section 6.

### Integration (integrator)

1. Merge 0, then A to E in any order; after each: `xcodegen generate`, full build, `RTITests`, `RTIRenderTests`.
2. Compose the full overlay proof (`overlay-assist-*`, `overlay-minimum-width-*`) and compare it side by side with `b2-ai-chat-*` and `c-quick-ai-tools-thread-*`.
3. CPU gate from section 6, then a manual run through `RTI/VERIFY.md` with a real 5-minute recording: start, pause, note, Assist, attach a PDF, finish, "Notes ready", open in Sessions, check the title.
4. Commit to `main`, push, `scripts/install-local.sh` when not recording, relaunch.

### Decision needed

One: moving RTI's global show/hide from `⌘\` to `⌥⌘\`, so `⌘\` means "show the list" in every house window. I recommend yes. If no, package C leaves the hotkey and the Sessions rail uses its header toggle only.
