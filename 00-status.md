Intent: Consolidate RTI into one main window with clear routes between sessions, chat, recording, and settings.
Criteria:
- Sessions remain reachable after opening chat. check: WorkspaceRenderProofTests navigation regression and UI walkthrough
- Main features share one window and consistent navigation. check: WorkspaceRenderProofTests rendered pages in both appearances
- Recording and saved sessions still work. check: RTITests and workspace lifecycle regression
- The app follows the House design and Swift rules. check: design-lint on touched files and xcodebuild
Must not: Lose session data or change saved credentials.

2026-10-30: Use one persistent recording header and labelled Live, Sessions, Chats, Settings navigation. Preserve the existing live composer and selected archive across routes. House registry records the pattern; app-specific content stays in RTI. Reference study dated 2026-10-15 is static recording analysis and does not prove reference UI navigation. Current code wins over its retired feature claims.

Verification, 2026-10-30:
- 755 RTICore unit tests passed.
- 37 archive, chat-library and workspace checks passed during integration; 44 workspace and chat lifecycle/runtime checks passed after the final routing changes.
- The final five workspace tests passed, including a populated saved chat with its sidebar hidden and the round trip back to Sessions.
- Standard and minimum-width light/dark renders are in /tmp/rti-render-proof/workspace-*.png. The views keep the route bar visible, and inactive pages are disabled and hidden from accessibility.
- Design lint reports zero hits on touched files; the registry check and source scrub pass.
- The prior reference report describes features retired on 2026-10-17 and records no runtime navigation test. Current code governs this change.

Release uses scripts/install-local.sh, its idle-recording guard and stable signature. The installed app records RTIBuiltFromCommit for the final identity check.

Sizing and depth follow-up, 2026-10-30:
- One starting size, 860 x 660, and one minimum, 720 x 520, apply to every page. Navigation no longer changes the window frame. Saved frames above the minimum are retained.
- Existing House tokens now distinguish sunken chrome and rails, the workspace ground, and raised reading panels, cards and composer. Card shadows and top highlights provide depth in both appearances.
- Six workspace tests pass. Renders cover all four pages at minimum, standard and larger sizes in light and dark. Supporting text clears 4.5:1 on each surface; metadata clears 3:1 on the raised ground.
- Strict design lint and the source scrub pass. No shared colour values or font sizes changed.
- The compact layout also exposed an answer Copy control over the text. A fixed action gutter now keeps the control and its Copied label clear of prose.

Workflow completion, 2026-10-30:
Intent: Make RTI's main workflows predictable and verify the installed revision.
Criteria:
- New-chat hand-offs clear old pending context. check: composer boundary regressions
- Settings retain unsaved edits across navigation. check: settings draft regressions and installed UI
- Chats refresh their list and selected detail. check: store-backed freshness regressions
- Hidden pages retire presentation work without stopping capture. check: workspace visibility regressions
- The installed app matches the committed build. check: lint, publish checks, signature and commit stamp
Must not: Lose saved chats, change real credentials during tests or interrupt recording.

The working brief and transition rules are in docs/workflow-contracts-20261030.md. Separate agents own composer, Settings and Chats fixes; an independent reviewer checks the integrated result before installation.

Workflow verification:
- 82 integrated checks passed, including 22 new composer, Settings, chat freshness and visibility regressions.
- Independent review findings on stale resume/storage results and false mode-save success were repaired and cleared on re-review.
- A queued-send test uses a valid fixture attachment so a blocked send cannot create a false pass. Failed-send coverage injects an actual storage error.
- Strict changed-file House lint and source scrub pass. Workflow contracts name the state preserved or reset at each boundary.

Session/chat and compact-chrome follow-up:
- Related saved chats use exact rti-session links and session.json identities. Return to session preserves the selected file, search, rail and mounted reader. Failed or pending resumes cannot show a false origin; new archives refresh on Chats entry.
- Header retains capture state, with mode/model options in the protected in-window chooser. Chat footer is Continue chat plus More; secondary actions and totals remain available.
- Twenty focused navigation/chrome/composer checks passed, including eight navigation cases and both appearances at compact size. Earlier integrated workflow checks remain green.
- Signing was isolated from the app using a disposable executable. The same identity failed headlessly and signed successfully through a PTY. docs/personal-setup.md records the repeatable interactive install path without keychain permission changes.

Recording integrity and recovery, 2026-10-30:
Intent: Prove retained audio integrity and truthful recovery states with invented audio, then install the verified repair.
Criteria:
- Both PCM legs retain the expected bytes and pause silence. check: writer and pipeline two-hour SHA/frame receipts
- Provider, device, close and archive failures have truthful outcomes. check: recording/recovery regression suites
- Long-session resource costs are measured. check: endurance result.json CPU, RSS and latency histograms
- The installed app matches the reviewed commit. check: publish checks, binary hashes, signature and control socket
Must not: Use client audio, change permissions or credentials, interrupt a real recording, or exhaust the main disk.

- Baseline probes reproduced overwriting existing audio and inconsistent WAV length after bounded write failure. Fixed writer rejects collisions/unsupported formats, rolls back partial writes and reports close failures.
- Transcription transport failure now preserves audio capture and offers Retry transcription. Device failure and archive failure remain separate, explicit outcomes.
- Close/write errors cannot claim Session saved or enter automatic upgrade. A persistent archive warning survives relaunch; a failed archive cannot leave known bad recordings queued.
- Final focused suites passed 33 checks including the added visual proof; independent review cleared the repairs. Details and reproducible commands: docs/recording-acceptance-20261030.md.
- Two-hour writer and pipeline runs remain in progress. Physical-device capture, recognition accuracy, power loss and installed-app long-session rendering remain unverified.
