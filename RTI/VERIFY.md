# RTI — User Verification Guide

This is what you run to verify RTI by hand. Ralph automated what it could; these steps need your hands on the Mac.

## Isolated beta acceptance, 12 November 2026

**Planned checks for the separately identified beta.** Begin once the beta reports its own build, test project and session directory. Use invented content. The baseline, replay harness and comparison criteria are in the [beta review](../docs/beta-review-20261112.md). The Debug launch command in section 1 uses the normal app identity. While running both, use the beta window’s controls or its local shortcuts: add Control to recorder chords (e.g. ⌃⌘⌥N for note mode, ⌃⌘⇧H / ⌃⌘⇧J for screen / window). Cmd+K stays local. The practice project appears under Prepare → Research. Its beta resources and credentials are separate from RTI.

| Minutes | Action | Pass condition |
| --- | --- | --- |
| 0–3 | Start a Research call with a fixture guide. Choose four speakers and enable speaker labels. Have four test voices on the system leg each introduce themselves. Have two repeat the same sentence. Ask a question on the mic. | Both repetitions survive. The mic shows its leg. Remote clusters retain identity provenance. Unverified turns stay anonymous in recap, Notes and Auto. Notes and Guide are both reachable. |
| 3–5 | In Transcript, change one-way target and then switch to a valid two-way pair while speaking. Try choosing the same language on both sides. Toggle labels off. | The control shows the effective setting and any switching state. Following speech changes language as selected. Time stays monotonic across the reconnect. Equal languages are rejected or resolved visibly. Labels-off uses only Me/Them. |
| 5–7 | Use ⌘⌥N for a multiline marker, pause, add an ordinary note, resume, and start a second marker. | The first span closes at the second marker. The regular note stays inside its span. Both markers and the multiline text survive Finish and upgrade in Sessions, the raw export, session metadata and sidecar. Check the completed upgrade after the timed exercise. |
| 7–10 | While speech and chat update, drag the window and release. Switch tabs and open Cmd+K. Use yellow, ⌘M, Dock restore, native zoom and full screen. Open and dismiss Mission Control once. | The frame settles where released. Background updates leave its size, position, Space and minimized state alone. Each native command works once. Restore returns to the expected frame. Recording continues. Compare `NSWindow.frame` and scroll origin separately if motion recurs. |
| 10–12 | Start with Screenshots in Manual only. Set Research to Off for the test project. Try both capture keys and a screen-tool request. Select Automatic during recording, pause, then switch Off during a pending capture. | Disabled keys explain the effective setting. Off produces zero new pixels, staged images, archive frames or outbound screen context in the test transports. The automatic indicator reflects the running sampler. The Research override survives reselecting the project. Deny-listed windows stay excluded. |
| 12–15 | Use the prepared 65-minute replay with saved chats. Scroll up during new speech, wait for another turn, then use Jump to live. Open Cmd+K and type broad and narrow queries while transcript events continue. | Reading position holds until resumed. Measure dispatch through first presented palette frame and input through each updated frame, including cold open, automatic focus and worst observation. Open takes under 100 ms and each filter update under 16 ms. Arrow down past the first screen of results, activate and Escape. |

Also test relaunch, external-display disconnect and restoring from full screen with a fixture archive. Keep a separate trace of frame, display/Space, visibility, focus and content scroll, with no transcript text. Old sessions must still open before and after the mock call.

### Palette latency and memory

Run the opt-in `CommandPaletteFocusProofTests/testLongWorkspaceMemoryAndInteractions` with `TEST_RUNNER_RTI_LONG_WORKSPACE=1`. It uses three 92-minute sessions, 24 saved chats, repeated route and scroll changes, keyboard filtering and resets. The `RTI_WORKSPACE_MEMORY` records contain cycle, stage, resident MiB and physical footprint MiB. Compare warm resets and inspect any growth. The ordinary chooser regression also checks that keyboard selection can reach row 150 while only viewport rows are built.

For the visible beta, attach Instruments Points of Interest to RTI Beta alone, then open Cmd+K and type a broad query followed by two narrowing keys. Read `PaletteOpen` and `PaletteFilter` in subsystem `RTI`, including the input dispatch delay in the begin event. The end is AppKit drawing the new palette. Count cold and worst observations. Ignore intervals marked superseded, and report their count. Tab to Transcript, scroll up, type in Chinese using marked text, then use Escape and verify that the draft and recording are intact. [Offscreen baseline and fixture](../docs/palette-baseline-20261112.md)

## 1. Launch

```bash
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app
```

You should see:
- A normal titled RTI window on your main screen. It is a regular window, not a floating panel (no float, no translucency).
- An RTI icon in the Dock, and RTI in the ⌘Tab list. The app is a regular Dock app (`LSUIElement=NO` since 2026-09-01).
- An "RTI" item in the macOS menubar. It is kept alongside the Dock icon. Its menu has **Quit RTI** and the panel toggles.

If any of those are missing, note it in `POC1-findings.md` → Anomalies.

## 2. Hotkey toggle

- Click any other app (Safari, Xcode, Finder) to change frontmost focus
- Press **⌘ + \\**
- Overlay should disappear
- Press **⌘ + \\** again
- Overlay should reappear
- Repeat 10× rapidly — no crashes, no focus steal, no lag

Check result in `POC1-findings.md`.

## 3. Focus + Space tests

- With **Window → Keep on Top** off, bring another window forward. RTI should use normal window ordering. Repeat with Keep on Top explicitly enabled.
- With the default macOS desktop assignment, switch Spaces and return. RTI should retain its assigned Space and window frame. Test deliberate show, minimize and restore separately from switching Spaces.

## 4. QuickTime screen recording

1. Open a fixture session with the RTI workspace visible. Open the command palette and inspect **Hide RTI from Screen Capture**. A fresh profile starts with the command unchecked.
2. Record the display using QuickTime. The default recording should include the RTI window.
3. Enable the command, repeat the recording and check the result for this macOS/QuickTime version. Restore the earlier choice when finished.

## 5. Meeting screen share

Share the display to a second device or test account. With **Hide RTI from Screen Capture** unchecked, the remote viewer should see RTI. If you use the opt-in exclusion, repeat with it checked and verify the actual conferencing client.

## 6. macOS Screenshot

1. With **Hide RTI from Screen Capture** unchecked, press ⌘⇧4, then Space, and click the workspace. Verify that the PNG contains the full RTI window. Repeat for the welcome window while it is open.
2. Enable the command and repeat with the same capture tool. Close and reopen RTI. The command should still be checked. Disable it, relaunch, and verify that ordinary window screenshots work again.

## 7. Clean quit

- Click the RTI menubar item → **Quit RTI**
- `ps aux | grep RTI` → should show no RTI process
- If a zombie process survives, note it.

## 8. Record results

Record the macOS version, capture client, command state and observed result for each of the three capture checks.

## Useful commands

```bash
# Rebuild after any source edit
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build

# Force-quit if needed
pkill -x RTI

# Find the built app
find ~/Library/Developer/Xcode/DerivedData -name RTI.app -path "*/Debug/*"

# Clean derived data if things get weird
rm -rf ~/Library/Developer/Xcode/DerivedData/RTI-*
```

---

# Production-readiness checklist (private beta)

Everything below builds + passes CI (103 unit tests); these are the hands-on
checks that need a real Mac, mic, network, and a meeting — the things that
can't be verified headlessly. Walk these before handing a DMG to a tester.

## A. First-run onboarding (fresh machine, or simulate)
To simulate without a fresh machine: quit RTI, `mv ~/Library/Application\ Support/RTI/credentials.json{,.bak}`, launch, then `mv` it back after.
- [ ] Onboarding window appears ("Welcome to RTI") instead of cold Settings.
- [ ] "Get a key" links open the Soniox / DeepSeek consoles.
- [ ] Pasting both keys + **Save keys** shows the green check; relaunch keeps them.
- [ ] **Grant** on Microphone triggers the system prompt; the row flips to "Granted".
- [ ] Footer flips to "You're all set" once keys + mic are in.

## B. Audio I/O — the device-routing check (do this on EVERY call's first 10s)
This is the definitive both-sides-recorded test. Open the **Audio I/O Monitor**
(menubar → Toggle Audio I/O Monitor, or Settings → Audio → Live levels).
- [ ] Start a session. **You** row shows the right input device + "Live".
- [ ] Say "testing one two" → the **You** meter moves and a `self:` transcript line appears.
- [ ] Other party talks → the **Them** meter moves + a `them:` line appears, and the **Them** device is the output you're listening through (e.g. AirPods).
- [ ] **The AirPods trap:** with AirPods in, both rows should read the AirPods device and both meters move. If **Them** is flat while they're talking, system-audio capture is on the wrong output → re-pick / restart. If **You** is flat while you talk, your mic is wrong → Settings → Audio.

### Mic dead-air watchdog
- [ ] Start a session with call audio playing, then unplug or switch the mic. Within ~10s the Transcript tab shows "Your microphone stopped sending audio…", the session keeps running and the other side keeps recording; reconnect the mic and the notice clears — **no silent dead-air recording, no lost other-party audio**.
- [ ] Close the lid for a minute mid-session, then reopen. The session is still recording, and after the call `audio-mic.wav` and `audio-system.wav` are as long as the session (the sleep is silence).
- [ ] During a *normal* silent stretch (no one talking), it does **not** false-fire (the meter is flat but the leg still reads "Live").

## C. Connection-health indicator (Live Transcript header, ⌘⌥T)
- [ ] On start: dot goes yellow "Connecting…" → green "Live".
- [ ] Kill wifi ~10s: → orange "Reconnecting…". Restore: → green "Live".
- [ ] If the other-party (system-audio) leg drops, the amber "other-party audio stopped" notice appears and the session keeps running.
- [ ] Kill wifi until the mic leg shows "Live transcription stopped after repeated connection failures" (about 25 s). Restore wifi and do not click Retry: within about 45 s the dot goes back to green "Live" and new lines appear. A rejected key (401) never retries on its own. The other side's leg heals the same way: during a call with remote audio playing, its notice says their audio is still being recorded, and their lines return without Retry.
- [ ] Minimize the window while recording, then restore it by clicking its thumbnail in the Dock (not the app icon). The transcript keeps advancing; it does not freeze on the last line before the minimize.

## D. Security (after any session)
- [ ] `ls -le ~/Library/Application\ Support/RTI/sessions/*/` → files `-rw-------`, dir `drwx------`.
- [ ] Settings → Logs contains **no transcript words** (only counts/status).
- [ ] Force-quit mid-session, relaunch → no orphan `*.wav` under `$TMPDIR/RTI/sessions`.

## E. Auto-update
- [ ] After publishing a release whose tag is **newer** than the running build, menubar → **Check for Updates…** offers a Download button to the release page. (Up-to-date shows "You're up to date".)

## F. Automatic transcript improvement
This verifies the normal RTI finish path: live transcription first, then an
automatic Soniox pass over the retained mic/system recordings before
meeting processing and Neon indexing.

1. Build and launch RTI.
2. Ensure Settings → Providers has a Soniox key. Soniox is the one upgrade
   provider (the Aliyun option was removed on 2026-09-26).
3. Create or select an archived session folder that contains:
   - `transcript.md`
   - `audio-mic.wav` and/or `audio-system.wav`
   - optional `session.json` with `micAudioFile`, `systemAudioFile`, and
     `systemAudioStartOffsetMs`
4. For a disposable public fixture, download an Open Speech Repository sample
   and convert it:

   ```bash
   curl -L -o /tmp/OSR_us_000_0010_8k.wav \
     https://www.voiptroubleshooter.com/open_speech/american/OSR_us_000_0010_8k.wav
   ffmpeg -y -i /tmp/OSR_us_000_0010_8k.wav -ac 1 -ar 16000 -c:a aac /tmp/audio-mic.m4a
   ```

5. Start a normal RTI recording with ⌘⇧R. Confirm the bottom-centre HUD appears,
   both audio meters move independently, and Sentinel does not start.
6. Click the HUD checkmark to Finish.
7. Expected UI behavior:
   - Button disables while the job runs.
   - Status reports provider selection, per-file transcription, note
     preservation, write, and final success/failure.
   - Missing audio, missing credentials, script failures, timeouts, and empty
     provider transcripts are shown without replacing the original transcript.
8. Expected files after success:
   - `transcript.md` contains the upgraded transcript.
   - `transcript.upgraded.md` contains the same upgraded output.
   - `transcript.backup-<stamp>.md` preserves the prior rough transcript.
   - Inline `📝 Note:` rows from the old transcript are preserved at their
     approximate timestamps/order.
9. With **Hide RTI from Screen Capture** unchecked, verify that QuickTime or a meeting screen share shows the workspace.

## G. Signing + notarization (needs your Apple Developer ID)
- [ ] `export DEVELOPMENT_TEAM=…`, set up `notarytool` profile `rti-notary` (see RELEASE.md), then `./scripts/release.sh <version>`.
- [ ] `spctl --assess --type open --context context:primary-signature -v RTI-<version>.dmg` → accepted.
- [ ] Install from the DMG on a Mac that's never run RTI → launches without right-click-Open; onboarding works.
- [ ] `gh release create v<version> RTI-<version>.dmg` (the tag is what the updater reads).

## H. Context (client/project/status)
- [ ] Open the **Context panel** (menubar → Toggle Context Panel). Type a note ("Client: Acme, status: behind"). ⌘↵ Assist → the suggestion reflects it.
- [ ] If your Hermes vault has a pre-meeting brief, it auto-loads in the panel (picker if several).

## I. Real meeting (the final gate)
- [ ] Join a real call. Both sides transcribe (the Transcript tab shows your runs on the right as "Me" and the call's voices on the left as "Them"; live labels are off by default).
- [ ] ⌘↵ Assist gives a useful, fast suggestion. ⌘⇧H screenshot-OCR attaches.
- [ ] The Notes tab fills in every few minutes (on by default), and Auto cards appear in the rail beside the Transcript (on by default for client and research calls); ⌘3 opens Transcript. A guided Research start lands on Transcript beside the rail, not on the Guide tab. On an internal or personal call (or with Auto off and no guide) ⌘3 and the palette's "Go to Live Help" rest.
- [ ] The workspace appears with normal window sharing enabled. The opt-in exclusion has been checked in the chosen screen-sharing client (§4–§5).
- [ ] Stop → the session folder appears under `sessions_dir` (default `~/Documents/Work/Inner-Chapter/meetings/sessions/<stamp>/`) with `transcript.md`, `audio-mic.wav` and `audio-system.wav` (the audio is kept for the transcript upgrade); mic released (orange dot clears, other apps can use the mic).

## Live rail and mic

Use a client call and a research call, each at least 5 minutes long.

- [ ] Client call: the rail shows at most 1 new card per minute. Count the cards with a clock for 5 minutes.
- [ ] Research call with a guide: skip a guide question and move to the next one. Within one guide pass (2 minutes by default), the rail shows the skipped question under the gaps.
- [ ] Make the window narrower. Below 752 pt of panel width (720 pt chat minimum plus 32 pt), the rail becomes a one-line strip over the transcript. Make it wider again and the rail comes back.
- [ ] Mute during a call, then Stop, then Record again. The new call starts with the mic open and no mute banner.
- [ ] During a call, minimize the window and restore it from the Dock thumbnail. The transcript is still live and new rows keep coming.
- [ ] With speakers and no headphones, the other party's voice can show as extra "Me" rows. RTI keeps both legs verbatim. Use headphones, Listening only, or the opt-in echo cancellation toggle.

## Guide mode in a 15-minute mock group

1. In Prepare, pick Research. Choose [the cup guide](Tests/GuideFixtures/dg-questions.json) and [its three-seat roster](Tests/GuideFixtures/roster.csv), then enter G1.
2. Start recording with three test respondents on the system-audio leg. Open Guide and check that S1Q1 is current and its must-ask box is empty.
3. Ask which cup each person chooses. Have two vote A and one vote B. Ask one person to explain in Chinese.
4. In Transcript, click each remote speaker label and assign P1, P2 or P3. Return to Guide and select “Write guide notes now.”
5. Check S1Q1 for the original Chinese, the speaker, timestamp and vote base of three. Your mic question should appear only in the transcript.
6. With Guide focused, press → then ←. Open ⌘K, jump back to S1Q1, and check that an earlier answer does not pull the highlight away.
7. Ask S1Q2 about carrying the cup and collect two fresh replies. Check the next Notes pass moves the highlight and the Cups section shows elapsed time against six minutes.
8. Finish immediately after a last reply. Leave cleaning untouched. In the session folder, open `guide-cells-G1.json` and check S2Q1 is “Not covered” with no quotes.
9. After the upgrade, inspect quote locators. Exact unique matches show “verified”; a changed or ambiguous quote keeps its live words and is marked “unverified.” In Sessions, change a seat and check the saved participant updates.
10. Run `python3 ~/skills/ic-synthesis-workbook/scripts/extract-cells.py import-rti "<session folder>" -o "<new workdir>"`, then `python3 ~/skills/ic-synthesis-workbook/scripts/extract-cells.py check "<new workdir>"`. A successful check is silent.
