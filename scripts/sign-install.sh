#!/usr/bin/env bash
# sign-install.sh — build RTI Release, sign it with the stable self-signed
# "RTI Self-Signed" identity, and install to /Applications.
#
# Why a stable cert: macOS TCC (microphone permission) keys on the app's
# Designated Requirement. An ad-hoc signature's DR is its cdhash, which changes
# on every rebuild — so each rebuild loses the mic grant and macOS re-prompts in
# a loop (this bit us 2026-06-24). Signing every build with the SAME self-signed
# cert keeps the DR constant (identifier + cert leaf), so the mic grant you give
# once survives all future rebuilds. No re-grant, no loop.
#
# First-time setup (the cert + keychain) was done on 2026-06-24; if the identity
# is missing this script tells you. After a normal rebuild just run this — do
# NOT tccutil-reset (that would force a re-grant); only reset if the grant is
# actually broken.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/build/Build/Products/Release/RTI.app"
ENT="$REPO/RTI/Sources/RTI.entitlements"
IDENTITY="RTI Self-Signed"
KC="$HOME/Library/Keychains/rti-signing.keychain-db"

if ! security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "ERROR: '$IDENTITY' not found in $KC." >&2
  echo "The signing identity is missing — recreate it (see git history for the" >&2
  echo "openssl + security import recipe), or sign ad-hoc and re-grant mic." >&2
  exit 1
fi

echo "Building Release…"
xcodebuild build -project "$REPO/RTI/RTI.xcodeproj" -scheme RTI \
  -configuration Release -derivedDataPath "$REPO/build" \
  CODE_SIGNING_ALLOWED=NO >/dev/null

echo "Signing with '$IDENTITY'…"
security unlock-keychain -p rti-local-signing "$KC" 2>/dev/null || true
codesign --force --deep --sign "$IDENTITY" --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP"

echo "Installing to /Applications…"
touch "$HOME/.local/state/rti/clean-exit" 2>/dev/null || true   # block watchdog relaunch mid-swap
osascript -e 'tell application "RTI" to quit' 2>/dev/null || true
pkill -9 -x RTI 2>/dev/null || true
sleep 1
rm -rf /Applications/RTI.app
ditto "$APP" /Applications/RTI.app
xattr -dr com.apple.quarantine /Applications/RTI.app 2>/dev/null || true

echo "Installed. Authority: $(codesign -dvvv /Applications/RTI.app 2>&1 | grep -i '^Authority=' | head -1)"
echo "Launch RTI normally. The mic grant persists across rebuilds (stable cert)."
