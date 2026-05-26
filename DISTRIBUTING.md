# Distributing RTI

This is a **personal build** — RTI is for my own machines, not for handing to
other people. For day-to-day use you don't need any of this: build it locally
(see [README.md](README.md)) and run it out of DerivedData.

The only reason to sign + notarize is so a release `.dmg` runs cleanly on my
*own* other Macs without the right-click → **Open** Gatekeeper dance (and so
`SMAppService` "Launch at Login" works, which refuses ad-hoc-signed builds).

If/when I want that, the one-time setup is:

1. Apple Developer Program enrolment + a **Developer ID Application** certificate in the **login** Keychain.
   Verify: `security find-identity -v -p codesigning | grep "Developer ID Application"`
2. A notarization keychain profile:
   ```bash
   xcrun notarytool store-credentials rti-notary \
     --apple-id you@example.com --team-id ABCDE12345 \
     --password <app-specific-password>
   ```
3. `.release.env` in the repo root (gitignored) with `DEVELOPMENT_TEAM=ABCDE12345`.
4. `brew install xcodegen create-dmg`

Then `./scripts/release.sh <version>` signs, packages, notarizes, and staples
the DMG. See [RELEASE.md](RELEASE.md) for the release flow itself.

Out of scope for a personal tool: auto-update (Sparkle), CI notarization, and
the Mac App Store (RTI uses global Carbon hotkeys and system-audio capture,
which aren't sandbox-compatible).
