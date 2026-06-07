# Release process — technical recipe

This is a **personal build**: releases are signed DMGs for my own machines, not
public distribution. The one-time signing/notarization setup is in the
"One-time setup" section below.

For a one-command path, use:

```bash
./scripts/release.sh 0.2.0
```

The rest of this file documents the same flow as a series of commands you can
run by hand if you want to inspect any individual step.

## Prerequisites

- Apple Developer account with Developer ID Application cert installed in the login Keychain
- `DEVELOPMENT_TEAM` (your 10-char team ID) exported, e.g.: `export DEVELOPMENT_TEAM=ABCDE12345`
- `APPLE_ID`, `APPLE_TEAM_ID`, and an app-specific password stored in the Keychain under the profile `rti-notary` (see notarytool step below)
- `create-dmg` (`brew install create-dmg`) or stick with `hdiutil`
- `gh` CLI authenticated to the `tristan-mcinnis/rti-personal` repo

## One-time setup

```bash
# Store notarization credentials in Keychain
xcrun notarytool store-credentials rti-notary \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "<app-specific-password>"
```

## Cut a release

Set the version string once:

```bash
export RTI_VERSION=0.1.0
```

1. Bump `CFBundleShortVersionString` in `RTI/Sources/Info.plist` to `$RTI_VERSION` if it isn't already.
2. Set the signing team in `RTI/project.yml` under `settings.base.DEVELOPMENT_TEAM` (leave empty for ad-hoc local Debug; set for Release).
3. Regenerate and build Release:

   ```bash
   cd RTI
   xcodegen generate
   xcodebuild \
     -project RTI.xcodeproj \
     -scheme RTI \
     -configuration Release \
     -derivedDataPath build \
     DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM \
     CODE_SIGN_STYLE=Automatic \
     CODE_SIGN_IDENTITY="Developer ID Application" \
     -allowProvisioningUpdates \
     build
   ```

4. Verify the signature and gatekeeper assessment:

   ```bash
   APP="build/Build/Products/Release/RTI.app"
   codesign --verify --deep --strict --verbose=2 "$APP"
   spctl --assess --type execute --verbose "$APP"
   ```

5. Package into a DMG:

   ```bash
   create-dmg \
     --volname "RTI $RTI_VERSION" \
     --window-size 540 360 \
     --icon "RTI.app" 140 180 \
     --app-drop-link 400 180 \
     "RTI-$RTI_VERSION.dmg" \
     "$APP"
   ```

   Or with plain `hdiutil`:

   ```bash
   hdiutil create -volname "RTI $RTI_VERSION" -srcfolder "$APP" -ov -format UDZO "RTI-$RTI_VERSION.dmg"
   ```

6. Notarize + staple:

   ```bash
   xcrun notarytool submit "RTI-$RTI_VERSION.dmg" --keychain-profile rti-notary --wait
   xcrun stapler staple "RTI-$RTI_VERSION.dmg"
   spctl --assess --type open --context context:primary-signature --verbose "RTI-$RTI_VERSION.dmg"
   ```

7. Tag + push + GitHub release:

   ```bash
   git tag -a "v$RTI_VERSION" -m "RTI $RTI_VERSION"
   git push origin "v$RTI_VERSION"
   gh release create "v$RTI_VERSION" "RTI-$RTI_VERSION.dmg" \
     --title "RTI $RTI_VERSION" \
     --notes "Personal signed build."
   ```

## Updates (how testers learn about new builds)

RTI uses a lightweight GitHub-Releases check rather than Sparkle/appcasts:

- On a normal launch (keys present) and via **menubar → Check for Updates…**,
  `UpdateChecker` queries `repos/tristan-mcinnis/rti-personal/releases/latest`,
  compares `tag_name` to the running `CFBundleShortVersionString`
  (`SemanticVersion` handles `v`-prefixes and `-betaN` pre-releases), and if a
  newer release exists, offers a **Download** button that opens the release page.
- The launch check is silent unless a newer build is published, so a tester just
  re-downloads the DMG when prompted.
- Therefore: **publish each release via `gh release create v<version> dist/RTI-<version>.dmg`** (the tag is what the checker reads). No appcast to host, no update signing key to manage. If you later want true in-place auto-update, swap in Sparkle with a signed appcast — `UpdateChecker` is the seam.

## Troubleshooting

- **`spctl: rejected`** — almost always means notarization failed or wasn't stapled. Re-run notarytool log inspection:

  ```bash
  xcrun notarytool log <submission-id> --keychain-profile rti-notary
  ```

- **`errSecInternalComponent`** during sign — check that the Developer ID certs are in the *login* keychain and not *local items*.

- **Starscream / Yams / MarkdownUI `not signed with Developer ID`** — SPM binary targets need to be re-signed as part of the app bundle. Xcode usually handles this; if not, add a `codesign --force --sign "$DEVELOPMENT_TEAM" <framework>` step before packaging.

- **`SMAppService` silently fails in Release** — verify the app bundle is properly signed + the bundle id in the login-items plist matches `com.tristan.rti.personal`.

## Released versions

Ad-hoc-signed DMGs are built via `./scripts/release-unsigned.sh <version>`. They are **not** notarized — right-click → **Open** on first launch. Signed/notarized DMGs follow the recipe above.

### Personal refocus (baseline)
- **Stripped to real-time-only.** Removed everything that wasn't live meeting assistance: the SQLite database + markdown corpus, session history/detail UI, audio/video import, cross-corpus "Ask" + project Q&A, FTS5 + dense-embedding search, the periodic post-hoc analysis (notes / dossiers / themes / discussion guide), the `rti-mcp` JSON-RPC server, and calendar integration. The app is now **ephemeral**: the live transcript and chat are held in memory for the session and dropped when it ends; the WAV recording is deleted on stop. Dropped the GRDB dependency — modes are stored as a small JSON file, user counter-panels are in-memory.
