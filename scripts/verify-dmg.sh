#!/bin/bash
# verify-dmg.sh <dmg> <expected-version>
# Checks a release DMG without launching the app: mounts it read-only, checks
# the layout, the signature of the app and every piece of nested code, the
# architecture, the version, and the notices, then detaches. Exits non-zero on
# the first failed check. The Gatekeeper assessment is printed, not judged: an
# ad hoc build is expected to be rejected.
set -euo pipefail

DMG="${1:?usage: verify-dmg.sh <dmg> <expected-version>}"
EXPECTED_VERSION="${2:?usage: verify-dmg.sh <dmg> <expected-version>}"
APP_NAME="RTI"
EXECUTABLE="RTI"
BUNDLE_ID="com.tristan.rti.personal"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[[ -f "$DMG" ]] || fail "no such file: $DMG"
MOUNT="$(mktemp -d)"
cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG" -nobrowse -readonly -noverify -mountpoint "$MOUNT" -quiet || fail "could not attach $DMG"
APP="$MOUNT/${APP_NAME}.app"

[[ -d "$APP" ]] && pass "${APP_NAME}.app is in the image" || fail "${APP_NAME}.app is missing"
[[ -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == "/Applications" ]] \
  && pass "Applications symlink points to /Applications" || fail "Applications symlink is missing or wrong"

PLIST="$APP/Contents/Info.plist"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
[[ "$SHORT" == "$EXPECTED_VERSION" ]] \
  && pass "Info.plist version $SHORT matches $EXPECTED_VERSION" || fail "Info.plist version is $SHORT, expected $EXPECTED_VERSION"
[[ "$(basename "$DMG")" == *"-${EXPECTED_VERSION}-"* ]] \
  && pass "file name carries version $EXPECTED_VERSION" || fail "file name does not carry version $EXPECTED_VERSION"
COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :RTIBuiltFromCommit' "$PLIST" 2>/dev/null || true)"
[[ -n "$COMMIT" && "$COMMIT" != *dirty* ]] \
  && pass "built from commit $COMMIT" || fail "no clean commit stamp in Info.plist (got '$COMMIT')"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")"
[[ "$ARCHS" == "arm64" ]] && pass "main binary archs: $ARCHS" || fail "main binary archs are '$ARCHS', expected arm64"
[[ "$(basename "$DMG")" == *"-macos-${ARCHS}.dmg" ]] \
  && pass "file name carries arch $ARCHS" || fail "file name does not carry arch $ARCHS"

# Signature: nested code deepest first, then the app, all strict.
NESTED="$(find "$APP/Contents" \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' -o -name '*.dylib' \) -print 2>/dev/null || true)"
COUNT=0
if [[ -n "$NESTED" ]]; then
  while IFS= read -r item; do
    codesign --verify --strict --verbose=2 "$item" 2>&1 || fail "nested code does not verify: $item"
    COUNT=$((COUNT + 1))
  done <<< "$NESTED"
fi
pass "nested code verified: $COUNT item(s)"
codesign --verify --strict --verbose=2 "$APP" 2>&1 || fail "app signature does not verify"
pass "app signature verifies (strict)"
SIGLINE="$(codesign -dvv "$APP" 2>&1 | grep -E '^Signature=' || true)"
[[ "$SIGLINE" == "Signature=adhoc" ]] && pass "signature is ad hoc" || fail "signature is '$SIGLINE', expected ad hoc"
IDENT="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Identifier=//p')"
[[ "$IDENT" == "$BUNDLE_ID" ]] && pass "signing identifier $IDENT" || fail "signing identifier is '$IDENT'"

for NOTICE in THIRD_PARTY_NOTICES.md LICENSE; do
  [[ -s "$APP/Contents/Resources/$NOTICE" ]] && pass "$NOTICE is inside the app" || fail "$NOTICE is missing from the app"
done

echo "---- spctl --assess (a rejection is expected for an ad hoc build) ----"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true
echo "---- end spctl ----"
echo "ALL CHECKS PASSED for $DMG"
