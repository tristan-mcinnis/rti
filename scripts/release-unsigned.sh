#!/usr/bin/env bash
# RTI release builder — ad-hoc signed DMG for private beta distribution.
# No Apple Developer ID required. Testers will need to right-click → Open the
# first time (or strip the quarantine attr) because the bundle is unsigned.
#
#   ./Scripts/release-unsigned.sh 0.2.0
#
# Output: dist/RTI-<version>.dmg

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>     e.g. $0 0.2.0" >&2
  exit 64
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$REPO_ROOT/build"
APP_NAME="RTI"
DMG_NAME="$APP_NAME-$VERSION.dmg"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

mkdir -p "$DIST_DIR"

echo "▶ unsigned release: $APP_NAME $VERSION"

# -- 1. license-key sanity check ------------------------------------------
LICENSE_FILE="$REPO_ROOT/RTI/Sources/Settings/LicenseStore.swift"
if grep -q 'REPLACE_WITH_BASE64_PUBLIC_KEY' "$LICENSE_FILE"; then
  echo "✘ LicenseStore.swift still has the placeholder public key." >&2
  echo "   Run: swift Scripts/license-tool.swift keygen" >&2
  echo "   Then paste the printed value into publicKeyBase64." >&2
  exit 1
fi

# -- 2. bump version ------------------------------------------------------
INFO_PLIST="$REPO_ROOT/RTI/Sources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
echo "  · Info.plist → $VERSION ($BUILD_NUMBER)"

# -- 3. regenerate project + build (ad-hoc signed) -----------------------
(cd RTI && xcodegen generate >/dev/null)

rm -rf "$BUILD_DIR"
xcodebuild \
  -project RTI/RTI.xcodeproj \
  -scheme RTI \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  build | (xcbeautify --quiet 2>/dev/null || cat)

[[ -d "$APP_PATH" ]] || { echo "✘ build failed: $APP_PATH not found" >&2; exit 1; }
echo "  · build ok → $APP_PATH"

# -- 4. ad-hoc sign (helps with Gatekeeper "damaged" errors) -------------
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH" || true

# -- 5. stage DMG contents ----------------------------------------------
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<'EOF'
RTI — private beta

INSTALL
  1. Drag RTI.app into Applications.
  2. The first time you open it, macOS will refuse because the app is
     not from an identified developer. Fix in one of two ways:
       a) Right-click RTI.app in Applications → Open → Open (in the
          warning dialog). This only needs to happen once.
       b) Or run this in Terminal:
            xattr -dr com.apple.quarantine /Applications/RTI.app
  3. Paste the beta key you were sent when prompted. The key expires
     after the period stated in the email.

PERMISSIONS
  RTI will ask for microphone + screen-recording access on first run.
  Both can be revoked any time in System Settings → Privacy & Security.

SUPPORT
  Reply to the email you got the key in.
EOF

# -- 6. build DMG ---------------------------------------------------------
DMG_PATH="$DIST_DIR/$DMG_NAME"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null

SHA="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
SIZE="$(du -h "$DMG_PATH" | cut -f1)"

cat <<EOF

✓ unsigned release ready

  file:    $DMG_PATH
  size:    $SIZE
  sha256:  $SHA
  version: $VERSION ($BUILD_NUMBER)

Mint a beta key for a tester:
  swift Scripts/license-tool.swift sign tester@example.com 60

EOF
