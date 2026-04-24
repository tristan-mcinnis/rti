# Privacy

RTI is a single-process macOS app. Nothing about your sessions leaves your Mac except what you actively send to the two third-party APIs you configure.

## What leaves your Mac

| Data | Where it goes | When |
|------|--------------|------|
| **Microphone PCM** (16 kHz mono) | Your Soniox account (`wss://api.soniox.com/transcribe-websocket`) | Only while a session is running (⌘⇧R) |
| **Transcript excerpt + your question / screen OCR** | Your Kimi / Moonshot account (`https://api.moonshot.cn/v1`) | Only when you submit an Ask Anything / Assist turn |

RTI itself has no backend, no analytics, no telemetry, no auto-update server, no third-party SDKs.

## What stays on your Mac

| Data | Location | Retention |
|------|----------|-----------|
| **API keys** (Kimi + Soniox) | macOS Keychain, service `com.tristan.rti` | Until you delete them in Settings → Keys |
| **Session metadata** | `~/Library/Application Support/RTI/rti.db` — `sessions` table | 30 days (auto-pruned on launch) |
| **Transcript entries** | Same DB — `transcript_entries` | 30 days via cascading delete |
| **Chat messages** | Same DB — `chat_messages` | 30 days via cascading delete |
| **Modes** (prompts + reference text) | Same DB — `modes` | Until you delete them |
| **Raw WAV audio** (if enabled) | `~/Library/Application Support/RTI/sessions/<id>.wav` | Same retention as the parent session |
| **Crash log** | `~/Library/Application Support/RTI/crash.log` | Rotated at 1 MB |

## What RTI never records

- **Screenshots are never written to disk.** `⌘ H` captures the display in memory, hands the `CGImage` to Vision OCR, sends the text string to Kimi, and discards the image. The binary pixels are not saved.
- **Other apps' window contents.** RTI does not scrape the foreground app, clipboard, browser, etc.
- **Keystrokes outside RTI's own input field.** The global hotkey handler (Carbon `RegisterEventHotKey`) only fires on the four registered combinations and does not inspect or log any other input.

## Permissions RTI asks for

- **Microphone** — required to transcribe your side of a conversation. Requested via `NSMicrophoneUsageDescription` on first ⌘⇧R.
- **Screen Recording** — required for `⌘ H` smart screenshot. Requested by macOS the first time you press `⌘ H`. Decline this and ⌘+H will surface an error toast but the rest of the app keeps working.
- **Accessibility** — not required.

## Third-party processing

- **Soniox** receives real-time audio during an active session. Review their policy at https://soniox.com/privacy.
- **Moonshot / Kimi** receives your question plus the most recent transcript excerpt and any OCR text you attached. Review their policy at https://platform.moonshot.cn.

## Deleting your data

- Clear one session: Menubar → **Clear Current Chat** (wipes chat messages for the current session; keeps the transcript).
- Clear all local data: quit RTI, then `rm -rf ~/Library/Application\ Support/RTI`.
- Revoke keys: Settings → Keys → paste empty strings then Save (or delete the Keychain entries via Keychain Access under service `com.tristan.rti`).
