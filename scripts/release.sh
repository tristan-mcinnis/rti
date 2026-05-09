#!/usr/bin/env bash
# RTI release builder — produces a signed, notarized, stapled .dmg ready for
# distribution. Run from the repo root:
#
#   ./scripts/release.sh 0.2.0
#
# Prerequisites (one-time, see DISTRIBUTING.md):
#   - Apple Developer enrollment + a "Developer ID Application" cert installed
#     in your login Keychain (Xcode → Settings → Accounts handles this).
#   - notarytool credentials stored under a keychain profile (default name:
#     `rti-notary`). Create with:
#         xcrun notarytool store-credentials rti-notary \
#           --apple-id you@example.com \
#           --team-id ABCDE12345 \
#           --password <app-specific-password>
#   - A `.release.env` file in the repo root (gitignored) containing:
#         DEVELOPMENT_TEAM=ABCDE12345
#         APPLE_NOTARY_KEYCHAIN_PROFILE=rti-notary   # optional, this is default
#   - `xcodegen` and (optionally) `create-dmg`:
#         brew install xcodegen create-dmg

set -euo pipefail

# -- args + config ----------------------------------------------------------

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>     e.g. $0 0.2.0" >&2
  exit 64
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Pull DEVELOPMENT_TEAM and (optionally) override the notary profile from
# .release.env. Keep this file out of git.
if [[ -f .release.env ]]; then
  # shellcheck source=/dev/null
  set -a; . .release.env; set +a
fi

: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM not set — see .release.env in DISTRIBUTING.md}"
NOTARY_PROFILE="${APPLE_NOTARY_KEYCHAIN_PROFILE:-rti-notary}"

DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$REPO_ROOT/build"
APP_NAME="RTI"
DMG_NAME="$APP_NAME-$VERSION.dmg"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

mkdir -p "$DIST_DIR"

echo "▶ release: $APP_NAME $VERSION  team=$DEVELOPMENT_TEAM"

# -- 1. bump version in Info.plist -----------------------------------------

INFO_PLIST="$REPO_ROOT/RTI/Sources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
# Use a monotonically-increasing build number derived from epoch — survives
# branch hopping and avoids the "duplicate build number" notarization error.
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
echo "  · Info.plist → $VERSION ($BUILD_NUMBER)"

# -- 2. regenerate Xcode project -------------------------------------------

(cd RTI && xcodegen generate >/dev/null)
echo "  · xcodegen ok"

# -- 3. clean Release build -------------------------------------------------

rm -rf "$BUILD_DIR"
xcodebuild \
  -project RTI/RTI.xcodeproj \
  -scheme RTI \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  -allowProvisioningUpdates \
  build \
  | xcbeautify --quiet 2>/dev/null || xcodebuild \
    -project RTI/RTI.xcodeproj \
    -scheme RTI \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    -allowProvisioningUpdates \
    build

if [[ ! -d "$APP_PATH" ]]; then
  echo "✘ build did not produce $APP_PATH" >&2
  exit 1
fi
echo "  · build ok → $APP_PATH"

# -- 4. verify signature ---------------------------------------------------

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH" || {
  echo "  ⚠ spctl rejected the unnotarized app — expected; will pass after stapling"
}
echo "  · codesign ok"

# -- 5. package .dmg -------------------------------------------------------

DMG_PATH="$DIST_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

if command -v create-dmg >/dev/null; then
  create-dmg \
    --volname "$APP_NAME $VERSION" \
    --window-size 540 360 \
    --icon-size 96 \
    --icon "$APP_NAME.app" 140 180 \
    --app-drop-link 400 180 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH" >/dev/null
else
  hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
fi
echo "  · dmg ok → $DMG_PATH"

# -- 6. notarize + staple --------------------------------------------------

echo "  · notarize: submitting (this can take 1–10 minutes)…"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
echo "  · notarized + stapled"

# -- 7. report -------------------------------------------------------------

SHA="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
SIZE="$(du -h "$DMG_PATH" | cut -f1)"

cat <<EOF

✓ release ready

  file:    $DMG_PATH
  size:    $SIZE
  sha256:  $SHA
  version: $VERSION ($BUILD_NUMBER)

Next:
  git tag -a "v$VERSION" -m "RTI $VERSION"
  git push origin "v$VERSION"
  gh release create "v$VERSION" "$DMG_PATH" --title "RTI $VERSION" --generate-notes

EOF
