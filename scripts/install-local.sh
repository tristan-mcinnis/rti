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

# The build below compiles the WORKING TREE, not HEAD. Installing from a dirty
# checkout therefore produces a binary that traces to no commit at all (bitten
# 2026-09-12: an installed app ran for an hour answering in a socket reply
# format that existed only in uncommitted edits, which is the only reason the
# mismatch was ever noticed). Refuse by default; override deliberately with
# RTI_ALLOW_DIRTY=1, in which case the stamp below records that it was dirty.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  if [ "${RTI_ALLOW_DIRTY:-0}" = "1" ]; then
    COMMIT="$COMMIT-dirty"
    echo "== WARNING: dirty tree; this build traces to nothing, stamping $COMMIT"
  else
    echo "refusing to install from a dirty working tree." >&2
    git status --short >&2
    echo "commit or stash first, or re-run with RTI_ALLOW_DIRTY=1 to override." >&2
    exit 1
  fi
fi
echo "== building from $COMMIT"

# A clean RTI checkout is not enough: this build also consumes the sibling
# HouseChatCore package. Its owner commit and exact source hash are stamped
# into the signed bundle below.
CHAT_CORE_PROVENANCE="../quick-launch/scripts/chat-core-provenance.py"
python3 "$CHAT_CORE_PROVENANCE" --require-clean

echo "== xcodegen + build (Release)"
(cd RTI && xcodegen generate >/dev/null && \
  xcodebuild -project RTI.xcodeproj -scheme RTI -configuration Release \
    -derivedDataPath "../$DERIVED" build | grep -E "BUILD (SUCCEEDED|FAILED)")

echo "== stamp build number with install time"
# The sidebar footer shows CFBundleVersion; stamping it here makes "which
# build am I actually running?" answerable at a glance (bitten 2026-08-30:
# a June-frozen build number made a current build look four months stale).
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
# ...and record WHICH COMMIT went in, so a binary is always traceable even
# when the build number alone cannot say.
/usr/libexec/PlistBuddy -c "Add :RTIBuiltFromCommit string $COMMIT" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :RTIBuiltFromCommit $COMMIT" "$APP/Contents/Info.plist"

python3 "$CHAT_CORE_PROVENANCE" --require-clean --plist "$APP/Contents/Info.plist"

echo "== re-sign with stable identity"
codesign --force --deep -s "$IDENTITY" --options runtime \
  --entitlements RTI/Sources/RTI.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier"

echo "== install"
# Recheck immediately before quitting, not only before the potentially long
# build. Never stop an active/paused recording or an unverified live process.
if pgrep -x RTI >/dev/null; then
  python3 - <<'PY'
import json, os, socket, sys
path = os.path.expanduser(os.environ.get("RTI_CONTROL_SOCK") or "~/.config/rti/control.sock")
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        client.connect(path)
        client.sendall(b"status\n")
        data = b""
        while b"\n" not in data and len(data) < 8192:
            chunk = client.recv(8192 - len(data))
            if not chunk:
                break
            data += chunk
    status = json.loads(data)
    if status.get("ok") is not True or status.get("app") != "rti" or not all(
        status.get(key) is False for key in ("recording", "paused", "busy")
    ):
        raise ValueError("RTI is not confirmed idle")
except (OSError, ValueError, TypeError, AttributeError) as error:
    sys.exit(f"Refusing installation: {error}. Leave RTI running and retry when idle.")
PY
fi
# Quit by bundle id (the app's AppleScript name has drifted before) and WAIT
# for the process to exit — replacing the bundle under a live process leaves
# the old binary running and `open` then no-ops against the running instance.
osascript -e 'tell application id "com.tristan.rti.personal" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -x RTI >/dev/null || break; sleep 0.5; done
if pgrep -x RTI >/dev/null; then
  echo "RTI did not quit; refusing to replace or force-terminate it." >&2
  exit 1
fi
# Clean replace, not ditto-overlay: overlaying leaves files from older bundle
# layouts inside the installed app.
rm -rf /Applications/RTI.app
ditto "$APP" /Applications/RTI.app
open -a /Applications/RTI.app
sleep 1
pgrep -x RTI >/dev/null && echo "RTI running (new build installed: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/RTI.app/Contents/Info.plist))"
