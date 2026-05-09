# Distributing RTI

This document is for the case where you want someone other than yourself to install RTI without scary "unidentified developer" warnings or right-click-Open ceremony. It explains the four moving parts (Apple Developer enrollment, code signing, hardened runtime, notarization) in plain English, what *you* personally need to do once, and what then happens automatically every release.

If you just want to build it locally for yourself, see [README.md](README.md) — none of this applies.

---

## What each thing actually means

**Code signing.** A cryptographic signature on the `.app` that says "this binary came from Tristan and hasn't been tampered with since." Without one (or with an "ad-hoc" one, which is what local builds use), macOS Gatekeeper either blocks the app outright or makes the user right-click → **Open**.

**Developer ID.** The specific kind of code-signing certificate Apple issues to identified developers for distributing apps *outside* the Mac App Store. You get one by enrolling in the [Apple Developer Program](https://developer.apple.com/programs/) ($99/year) and asking Xcode to download it. There are several certificate types; the one that matters here is **Developer ID Application**.

**Hardened Runtime.** A set of opt-in macOS security restrictions that an app declares it can live with — no unsigned dylib loading, no process injection, etc. Apple requires Hardened Runtime to be enabled on any app you submit for notarization. RTI's Release config turns this on; the entitlements file [`RTI/Sources/RTI.entitlements`](RTI/Sources/RTI.entitlements) opens exactly the holes RTI needs (microphone, network).

**Notarization.** You upload your signed `.dmg` to Apple. They scan it for malware and known bad patterns, then send back a "ticket" you *staple* to the file. After that, Gatekeeper trusts it on any Mac, online or offline. Notarization is automated, but it requires a one-time credential setup so the upload tool knows who you are.

The `scripts/release.sh` in this repo does the signing, packaging, and notarization in one command. **What follows is the one-time setup you need to do before that script can work.**

---

## One-time setup (~30 minutes plus Apple's review wait)

### 1. Enroll in the Apple Developer Program

Go to <https://developer.apple.com/programs/enroll/> and sign up. $99/year. As an individual you'll usually be approved within a day. Confirm your enrollment before the next step or Xcode won't see your team.

### 2. Get your Team ID

Sign in at <https://developer.apple.com/account>. The 10-character alphanumeric **Team ID** is on the **Membership** page (e.g. `ABCDE12345`). Save it; you'll paste it in step 4.

### 3. Install the Developer ID certificate

1. Open **Xcode → Settings → Accounts**, click `+`, sign in with your Apple ID.
2. Select your team in the list, click **Manage Certificates…**, click `+`, choose **Developer ID Application**.
3. Xcode will create the cert in Apple's portal and install the matching private key in your **login** Keychain. (Critical: must be the *login* Keychain, not *local items*. If `errSecInternalComponent` shows up later, this is why.)

Verify:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see one line with your name. That's the identity `xcodebuild` will pick up automatically.

### 4. Create an app-specific password for notarization

Apple won't let `notarytool` use your real Apple ID password.

1. Sign in to <https://appleid.apple.com>.
2. **Sign-In and Security → App-Specific Passwords → Generate**, label it `rti-notary`.
3. Copy the password (you won't see it again).

### 5. Store the notarization credentials in your Keychain

Once. The `notarytool` keychain profile means you never have to type the password again.

```bash
xcrun notarytool store-credentials rti-notary \
  --apple-id you@example.com \
  --team-id ABCDE12345 \
  --password <the app-specific password from step 4>
```

The profile name `rti-notary` is what `scripts/release.sh` expects by default.

### 6. Drop your team ID into a local env file

Create `.release.env` in the repo root (already gitignored):

```bash
DEVELOPMENT_TEAM=ABCDE12345
# Optional override — defaults to rti-notary, matches what you set in step 5:
# APPLE_NOTARY_KEYCHAIN_PROFILE=rti-notary
```

### 7. Install the build helpers (one line)

```bash
brew install xcodegen create-dmg
```

`create-dmg` is optional — `release.sh` falls back to `hdiutil` if it's not present, but `create-dmg` produces a prettier installer window.

That's it for the one-time setup.

---

## Cutting a release

```bash
./scripts/release.sh 0.2.0
```

What it does:

1. Bumps `CFBundleShortVersionString` to `0.2.0` and `CFBundleVersion` to a fresh epoch-derived build number.
2. `xcodegen generate` to refresh the Xcode project.
3. Clean Release build with your Developer ID identity and Hardened Runtime enabled.
4. Verifies the signature with `codesign --verify` and checks Gatekeeper assessment.
5. Packages the `.app` into `dist/RTI-0.2.0.dmg`.
6. Submits the DMG to Apple's notarization service and waits (1–10 minutes typical).
7. Staples the notarization ticket onto the DMG.
8. Prints the path, size, and sha256.

Final hop:

```bash
git tag -a "v0.2.0" -m "RTI 0.2.0"
git push origin "v0.2.0"
gh release create "v0.2.0" "dist/RTI-0.2.0.dmg" \
  --title "RTI 0.2.0" \
  --generate-notes
```

(That last command line is also printed at the end of `release.sh` for copy-paste.)

---

## Troubleshooting

**`spctl: rejected`.** Notarization didn't run, or stapling failed. Re-run `xcrun notarytool log <submission-id> --keychain-profile rti-notary` to see Apple's complaint.

**`errSecInternalComponent` during signing.** The Developer ID cert is in the wrong Keychain. Open **Keychain Access**, find "Developer ID Application: …", and drag it into **login** if it's somewhere else.

**`The Apple-Intermediate certificate could not be found`.** Open Keychain Access, **Keychain Access → Certificate Assistant → Evaluate**. Or just download the **Developer ID — G2** intermediate cert from <https://www.apple.com/certificateauthority/> and double-click it.

**Notarization succeeds but Gatekeeper still rejects.** You forgot to staple, or you re-zipped the DMG after stapling. Stapling has to happen on the exact bits the user downloads.

**SPM frameworks (GRDB / Starscream / Yams) refuse to load with library-validation errors.** They need to be re-signed as part of the bundle. Xcode usually does this in the Release archive flow; if not, add `--force` to the `codesign` step in `release.sh` or strip and re-sign with the same identity.

**`SMAppService` (Launch at Login) silently fails.** That helper service refuses to register on ad-hoc-signed builds. If you're testing it, install the notarized DMG, not a Debug build out of DerivedData.

---

## What this does *not* cover

- **Sparkle / auto-update.** Each release ships a fresh `.dmg`; users install over the old version. If you start having more than a handful of users, wire up [Sparkle](https://sparkle-project.org/) — but that's a separate decision.
- **GitHub Actions CI.** Notarization needs your app-specific password, which means a repo secret — defer until you actually want green-button-deploys.
- **Mac App Store.** Different cert (Mac App Distribution), different entitlements (sandboxing required), different review process. RTI does too many sandbox-incompatible things (global Carbon hotkeys, system audio capture, free-form file system access) to be worth pursuing.
