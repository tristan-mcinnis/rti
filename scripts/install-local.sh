#!/bin/bash
# install-local.sh — build, stably sign, and install RTI.app locally.
#
# Why this exists: macOS TCC ties permission grants (microphone, System Audio
# Recording, Screen Recording) to the app's signing identity. Ad-hoc builds
# carry a unique cdhash per build, so every reinstall used to reset all
# permissions (bitten 2026-08-14). Signing each build with the same Apple
# Development certificate keeps the designated requirement stable, so grants
# survive updates. Xcode's Automatic signing can't find the account headlessly,
# hence: build ad-hoc, then re-sign the product with the keychain identity.
set -euo pipefail

cd "$(dirname "$0")/.."

# Personal Apple Development identity (team TEAMID0000). Update if the cert
# is ever renewed: `security find-identity -v -p codesigning`.
IDENTITY="${RTI_SIGN_IDENTITY:-Apple Development: dev@example.com (TEAMID0001)}"
DERIVED=".deriveddata"
APP="$DERIVED/Build/Products/Release/RTI.app"

echo "== xcodegen + build (Release)"
(cd RTI && xcodegen generate >/dev/null && \
  xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Release \
    -derivedDataPath "../$DERIVED" build | grep -E "BUILD (SUCCEEDED|FAILED)")

echo "== stamp build number with install time"
# The sidebar footer shows CFBundleVersion; stamping it here makes "which
# build am I actually running?" answerable at a glance (bitten 2026-08-30:
# a June-frozen build number made a current build look four months stale).
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"

echo "== re-sign with stable identity"
codesign --force --deep -s "$IDENTITY" --options runtime \
  --entitlements RTI/Sources/RTI.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier"

echo "== install"
# Quit by bundle id (the app's AppleScript name has drifted before) and WAIT
# for the process to exit — replacing the bundle under a live process leaves
# the old binary running and `open` then no-ops against the running instance.
osascript -e 'tell application id "com.tristan.rti.personal" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -x RTI >/dev/null || break; sleep 0.5; done
pgrep -x RTI >/dev/null && { echo "RTI did not quit; terminating"; pkill -x RTI; sleep 1; }
# Clean replace, not ditto-overlay: overlaying leaves files from older bundle
# layouts inside the installed app.
rm -rf /Applications/RTI.app
ditto "$APP" /Applications/RTI.app
open -a /Applications/RTI.app
sleep 1
pgrep -x RTI >/dev/null && echo "RTI running (new build installed: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/RTI.app/Contents/Info.plist))"
