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
