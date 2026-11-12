#!/bin/bash
# Build a separate, signed test app from the committed source and a keyless stub.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
revision="$(git -C "$repo" rev-parse HEAD)"
out="$repo/dist/beta"
derived="$out/DerivedData"
destination="$out/$revision/RTI Beta.app"
mkdir -p "$out"
snapshot="$(mktemp -d "$out/source.XXXXXX")"
trap 'rm -rf "$snapshot"' EXIT
git -C "$repo" archive "$revision" | tar -x -C "$snapshot"
cp "$snapshot/RTI/Sources/Secrets.swift.example" "$snapshot/RTI/Sources/Secrets.swift"
(cd "$snapshot/RTI" && xcodegen generate >/dev/null)

if [[ ! -d "$derived/SourcePackages" && -d "$repo/.deriveddata/SourcePackages" ]]; then
  mkdir -p "$derived"
  cp -cR "$repo/.deriveddata/SourcePackages" "$derived/"
fi
xcodebuild -project "$snapshot/RTI/RTI.xcodeproj" -scheme RTI -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$derived" \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  'RTI_APP_NAME=RTI Beta' RTI_APP_ID=com.tristan.rti.personal.beta CODE_SIGNING_ALLOWED=NO build

app="$derived/Build/Products/Release/RTI Beta.app"
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == com.tristan.rti.personal.beta ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" == 'RTI Beta' ]]
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$plist"
/usr/libexec/PlistBuddy -c "Add :RTIBuiltFromCommit string $revision" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :RTIBuiltFromCommit $revision" "$plist"
python3 "$snapshot/scripts/stamp-package-pins.py" \
  --resolved "$snapshot/RTI/RTI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" --plist "$plist"

# Ship only the invented materials for an optional practice call.
example="$app/Contents/Resources/Practice Project"
fixture="$snapshot/docs/fixtures/stimulus-review"
mkdir -p "$example/06-discussion-guide" "$example/stimulus"
cp "$fixture/stim-manifest.json" "$fixture/guide.md" "$example/stimulus/"
cp -R "$fixture/slides" "$example/stimulus/"
cp "$fixture/dg-questions.json" "$example/06-discussion-guide/"
echo "An invented comparison of two storage boards for testing RTI Beta." > "$example/00-status.md"
echo "concept | Storage shape（收纳形状）" > "$example/codebook-seed.md"

identity="${RTI_SIGN_IDENTITY:-}"
if [[ -z "$identity" && -f "$repo/.release.env" ]]; then
  identity="$(sed -n 's/^RTI_SIGN_IDENTITY=//p' "$repo/.release.env" | head -1 | tr -d '"')"
fi
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
: "${identity:?A stable Apple Development signing identity is needed for beta permission grants}"
codesign --force --deep --options runtime --sign "$identity" --entitlements "$snapshot/RTI/Sources/RTI.entitlements" "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$destination")"
ditto "$app" "$destination"
codesign --verify --deep --strict "$destination"
echo "$destination"
