# RTI POC-1 — User Verification Guide

This is what you run to finish verifying POC-1. Ralph automated what it could; these steps need your hands on the Mac.

## 1. Launch

```bash
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/RTI-*/Build/Products/Debug/RTI.app
```

You should see:
- A dark translucent panel at the top-left of your main screen, ~420×560, with "RTI" and "overlay — POC-1" text
- An "RTI" label in the macOS menubar, with a menu containing **Toggle Overlay** and **Quit RTI**
- NO Dock icon (accessory app)

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

- With overlay visible, click a Safari window — does Safari come frontmost while the overlay stays visible on top? (Expected: yes)
- Switch Spaces with Ctrl+→ / Ctrl+← — does the overlay follow to the new Space? (Expected: yes)

## 4. QuickTime screen-recording test (CRITICAL)

1. Launch RTI so the overlay is visible
2. Open **QuickTime Player → File → New Screen Recording**
3. Record your full screen for 10 seconds
4. Stop the recording, play it back
5. **Expected:** the RTI overlay is absent from the recording
6. **If the overlay appears in the recording:** POC-1 has uncovered a showstopper. Do not proceed to POC-2. Note details in findings.

## 5. Zoom share-screen test (CRITICAL)

If you have a second device or Zoom account:

1. Launch RTI (overlay visible)
2. Start a Zoom meeting, use "Share Screen" → share your entire screen
3. Check what the remote viewer sees
4. **Expected:** the remote viewer does NOT see the RTI overlay
5. **If they do:** showstopper. Investigate before building further.

(If you don't have a quick Zoom setup, Google Meet or Teams share-screen works the same way.)

## 6. macOS built-in Screenshot test

```bash
# With RTI running and overlay visible:
screencapture -x ~/Desktop/rti-test.png
open ~/Desktop/rti-test.png
```

Ralph already ran this and confirmed the overlay was absent. You can re-run as a sanity check, then delete the file.

Also try `⌘+Shift+5` → "Capture Entire Screen" — same expected result.

## 7. Clean quit

- Click the RTI menubar item → **Quit RTI**
- `ps aux | grep RTI` → should show no RTI process
- If a zombie process survives, note it.

## 8. Record results

Open `RTI/POC1-findings.md` and check off each row in the user-attestation table. Note any anomalies. Then decide:

- **All critical checks pass** → run `/plan` for POC-2 (audio pipeline)
- **QuickTime or Zoom check fails** → stop, investigate `sharingType` behavior, maybe try the `kSCStreamConfigurationExcludingWindowIDs` path, read NSWindow / ScreenCaptureKit docs for any additional flags

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
- [ ] Start a session, then disconnect/mute the mic. Within ~10s "Microphone audio stopped…" appears and the session stops — **no silent dead-air recording**.
- [ ] During a *normal* silent stretch (no one talking), it does **not** false-fire (the meter is flat but the leg still reads "Live").

## C. Connection-health indicator (Live Transcript header, ⌘⌥T)
- [ ] On start: dot goes yellow "Connecting…" → green "Live".
- [ ] Kill wifi ~10s: → orange "Reconnecting…". Restore: → green "Live".
- [ ] If the other-party (system-audio) leg drops, the amber "other-party audio stopped" notice appears and the session keeps running.

## D. Security (after any session)
- [ ] `ls -le ~/Library/Application\ Support/RTI/sessions/*/` → files `-rw-------`, dir `drwx------`.
- [ ] Settings → Logs contains **no transcript words** (only counts/status).
- [ ] Force-quit mid-session, relaunch → no orphan `*.wav` under `$TMPDIR/RTI/sessions`.

## E. Auto-update
- [ ] After publishing a release whose tag is **newer** than the running build, menubar → **Check for Updates…** offers a Download button to the release page. (Up-to-date shows "You're up to date".)

## F. Upgrade Transcript (archived-session exception)
This verifies the narrow post-hoc exception: a finished RTI archive with retained
audio can be upgraded without creating a corpus, import flow, database, or
cross-session search surface.

1. Build and launch RTI.
2. Ensure Settings → Providers has credentials for the provider you intend to
   test. Soniox is suitable for the public English fixture; Aliyun is intended
   for Chinese-heavy sessions.
3. Create or select an archived session folder that contains:
   - `transcript.md`
   - `audio-mic.m4a` and/or `audio-system.m4a`
   - optional `session.json` with `micAudioFile`, `systemAudioFile`, and
     `systemAudioStartOffsetMs`
4. For a disposable public fixture, download an Open Speech Repository sample
   and convert it:

   ```bash
   curl -L -o /tmp/OSR_us_000_0010_8k.wav \
     https://www.voiptroubleshooter.com/open_speech/american/OSR_us_000_0010_8k.wav
   ffmpeg -y -i /tmp/OSR_us_000_0010_8k.wav -ac 1 -ar 16000 -c:a aac /tmp/audio-mic.m4a
   ```

5. Open **Past Sessions**, select the archived session, click
   **Upgrade Transcript**, then choose **Soniox** or **Aliyun
   (Chinese-heavy)** in the provider prompt.
6. Expected UI behavior:
   - Button disables while the job runs.
   - Status reports provider selection, per-file transcription, note
     preservation, write, summary regeneration, and final success/failure.
   - Missing audio, missing credentials, script failures, timeouts, and empty
     provider transcripts are shown without replacing the original transcript.
7. Expected files after success:
   - `transcript.md` contains the upgraded transcript.
   - `transcript.upgraded.md` contains the same upgraded output.
   - `transcript.backup-<stamp>.md` preserves the prior rough transcript.
   - Existing `summary.md` is backed up as `summary.backup-<stamp>.md`.
   - `summary.md` is regenerated from the upgraded transcript.
   - Inline `📝 Note:` rows from the old transcript are preserved at their
     approximate timestamps/order.

## G. Signing + notarization (needs your Apple Developer ID)
- [ ] `export DEVELOPMENT_TEAM=…`, set up `notarytool` profile `rti-notary` (see RELEASE.md), then `./scripts/release.sh <version>`.
- [ ] `spctl --assess --type open --context context:primary-signature -v RTI-<version>.dmg` → accepted.
- [ ] Install from the DMG on a Mac that's never run RTI → launches without right-click-Open; onboarding works.
- [ ] `gh release create v<version> RTI-<version>.dmg` (the tag is what the updater reads).

## H. Context (client/project/status)
- [ ] Open the **Context panel** (menubar → Toggle Context Panel). Type a note ("Client: Acme, status: behind"). ⌘↵ Assist → the suggestion reflects it.
- [ ] If your Hermes vault has a pre-meeting brief, it auto-loads in the panel (picker if several).

## I. Real meeting (the final gate)
- [ ] Join a real call. Both sides transcribe (Live Transcript shows "self" + "them").
- [ ] ⌘↵ Assist gives a useful, fast suggestion. ⌘⇧H screenshot-OCR attaches.
- [ ] Notes / Dossiers / Discussion-guide panels populate.
- [ ] Overlay is absent from the screen share (QuickTime/Zoom — §4/§5 above).
- [ ] Stop → Markdown archive written under `…/RTI/sessions/`; WAV gone; mic released (orange dot clears, other apps can use the mic).
