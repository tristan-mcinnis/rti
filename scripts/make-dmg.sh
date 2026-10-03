#!/bin/bash
# make-dmg.sh: package RTI as a free GitHub release download.
#
# Builds with ad hoc signing (no Apple Developer ID needed), wraps the app and
# an /Applications symlink in a compressed DMG, checks the image read-only, then
# writes SHA256SUMS and RELEASE_NOTES.md beside it. It pushes nothing and
# creates no GitHub release.
#
# Usage:   ./scripts/make-dmg.sh
# Output:  $RELEASE_OUT, default dist/release
# Options: RTI_SKIP_BUILD=1 packages the app the last run built.
#          RTI_ALLOW_DIRTY=1 builds from a dirty tree (the stamp says so, and
#          the image check then fails on purpose; use it for a trial only).
#
# The notarized path (release.sh) is separate and needs a Developer ID. This
# script never uses it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="RTI"
REPO="tristan-mcinnis/rti"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' RTI/Sources/Info.plist)"
DERIVED="$ROOT_DIR/build/dmg"
APP="$DERIVED/Build/Products/Release/${APP_NAME}.app"
OUT_DIR="${RELEASE_OUT:-$ROOT_DIR/dist/release}"
PKG_DIR="$ROOT_DIR/Packaging/Release"
CHAT_CORE_PROVENANCE="$ROOT_DIR/../quick-launch/scripts/chat-core-provenance.py"

if [[ "${RTI_SKIP_BUILD:-0}" != "1" ]]; then
  COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    if [[ "${RTI_ALLOW_DIRTY:-0}" == "1" ]]; then
      COMMIT="$COMMIT-dirty"
      echo "WARNING: dirty tree; stamping $COMMIT"
    else
      echo "ERROR: refusing to package a dirty working tree. Commit first, or set RTI_ALLOW_DIRTY=1." >&2
      git status --short >&2
      exit 1
    fi
  fi
  # A clean RTI checkout is not enough: the build also consumes the sibling
  # HouseChatCore package. Its commit and source hash are stamped below.
  python3 "$CHAT_CORE_PROVENANCE" --require-clean

  "$ROOT_DIR/scripts/check-layout.sh"
  # Secrets.swift is gitignored and holds no keys. Seed it from the example.
  [[ -f RTI/Sources/Secrets.swift ]] || cp RTI/Sources/Secrets.swift.example RTI/Sources/Secrets.swift
  echo "==> xcodegen + Release build (arm64, ad hoc)"
  (cd RTI && xcodegen generate >/dev/null)
  rm -rf "$DERIVED"
  xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Release \
    -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build | grep -E "BUILD (SUCCEEDED|FAILED)"
  [[ -d "$APP" ]] || { echo "ERROR: build did not produce $APP" >&2; exit 1; }

  PLIST="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :RTIBuiltFromCommit string $COMMIT" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :RTIBuiltFromCommit $COMMIT" "$PLIST"
  python3 "$CHAT_CORE_PROVENANCE" --require-clean --plist "$PLIST"

  echo "==> ad hoc signature, hardened runtime, with the app entitlements"
  codesign --force --deep -s - --options runtime \
    --entitlements RTI/Sources/RTI.entitlements "$APP"
fi
[[ -d "$APP" ]] || { echo "ERROR: $APP is missing. Run without RTI_SKIP_BUILD." >&2; exit 1; }

ARCHS="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
DMG_NAME="${APP_NAME}-${VERSION}-macos-${ARCHS}.dmg"
DMG="$OUT_DIR/$DMG_NAME"

mkdir -p "$OUT_DIR"
rm -f "$DMG" "$OUT_DIR/SHA256SUMS" "$OUT_DIR/RELEASE_NOTES.md" "$OUT_DIR/verify.log" "$OUT_DIR/spctl-assess.txt"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto keeps the signature, the extended attributes and the symlinks intact.
ditto "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG_NAME"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"

(cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" > SHA256SUMS)
SHA="$(awk '{print $1}' "$OUT_DIR/SHA256SUMS")"

echo "==> Verifying the image"
"$ROOT_DIR/scripts/verify-dmg.sh" "$DMG" "$VERSION" 2>&1 | tee "$OUT_DIR/verify.log"
sed -n '/^---- spctl/,/^---- end spctl/p' "$OUT_DIR/verify.log" > "$OUT_DIR/spctl-assess.txt"

echo "==> Writing RELEASE_NOTES.md"
export APP_NAME VERSION REPO DMG_NAME SHA
HIGHLIGHTS="$(cat "$PKG_DIR/highlights.md")"
FIRST_OPEN="$(sed "s|@APP_NAME@|$APP_NAME|g" "$PKG_DIR/first-open.md.template")"
export HIGHLIGHTS FIRST_OPEN
python3 - "$PKG_DIR/release-notes.md.template" "$OUT_DIR/RELEASE_NOTES.md" <<'PY'
import os, sys
text = open(sys.argv[1]).read()
for key in ("APP_NAME", "VERSION", "REPO", "DMG_NAME", "SHA", "HIGHLIGHTS", "FIRST_OPEN"):
    token = "@SHA256@" if key == "SHA" else f"@{key}@"
    text = text.replace(token, os.environ[key])
open(sys.argv[2], "w").write(text)
PY

echo ""
echo "==> Created:"
echo "    $DMG"
echo "    $OUT_DIR/SHA256SUMS"
echo "    $OUT_DIR/RELEASE_NOTES.md"
echo "    sha256 $SHA"
