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
