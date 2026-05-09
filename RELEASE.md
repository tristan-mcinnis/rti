# Release process — technical recipe

For first-time setup and a plain-English explanation of what notarization,
hardened runtime, and Developer ID actually mean, read **[DISTRIBUTING.md](DISTRIBUTING.md)** first.

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
- `gh` CLI authenticated to the `tristan-mcinnis/rti` repo

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
     --notes-file RELEASE_NOTES.md
   ```

## Troubleshooting

- **`spctl: rejected`** — almost always means notarization failed or wasn't stapled. Re-run notarytool log inspection:

  ```bash
  xcrun notarytool log <submission-id> --keychain-profile rti-notary
  ```

- **`errSecInternalComponent`** during sign — check that the Developer ID certs are in the *login* keychain and not *local items*.

- **GRDB / Starscream `not signed with Developer ID`** — SPM binary targets need to be re-signed as part of the app bundle. Xcode usually handles this; if not, add a `codesign --force --sign "$DEVELOPMENT_TEAM" <framework>` step before packaging.

- **`SMAppService` silently fails in Release** — verify the app bundle is properly signed + the bundle id in the login-items plist matches `com.tristan.rti`.
