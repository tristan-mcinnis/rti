# POC-7 — Modes, reference files, settings, Keychain — findings

Stage 4. Adds a builtin mode library, per-mode reference text that's prepended to every Kimi call, a tabbed Settings window, and a launch-at-login toggle. Finalizes the Keychain-only secrets policy.

## Files

- `RTI/Sources/Database/RTIDatabase.swift` — migration `v3_mode_reference_text` adds nullable `reference_text` column to `modes`.
- `RTI/Sources/Database/Models/Mode.swift` — `referenceText: String?` + `CodingKeys`.
- `RTI/Sources/Modes/ModeStore.swift` — NEW. `@MainActor ObservableObject` singleton. Seeds four builtin modes on first launch (`Meeting` / `Interview` / `Coding` / `Custom`), exposes `modes`, `activeModeId` (persisted to `UserDefaults[rti.modes.activeId]`), `activeMode` computed, `update(id:name:systemPrompt:referenceText:)`. First-run defaults to `builtin.meeting` active.
- `RTI/Sources/LLM/LLMController.swift` — `performSend` now builds the system message from `ModeStore.shared.activeMode?.systemPrompt` (falls back to the hardcoded constant) and appends a second system message with the active mode's `referenceText` (capped at 8000 chars, ellipsised) when present. The existing screen-context system message still rides after these.
- `RTI/Sources/Settings/SettingsView.swift` — rewritten as `TabView`: **Keys** (existing Kimi + Soniox), **Modes** (list + name/system-prompt/reference-text editors + Set Active), **General** (Launch at Login toggle + read-only hotkey reference).
- `RTI/Sources/Settings/LaunchAtLogin.swift` — NEW. Thin wrapper over `SMAppService.mainApp` for register / unregister / isEnabled; surfaces errors so the toggle can roll back gracefully on ad-hoc-signed local builds.
- `RTI/Sources/Settings/SettingsWindowController.swift` — window resized to 560×460 to match the new tabs.
- `RTI/Sources/AppDelegate.swift` — touches `ModeStore.shared` at launch to trigger builtin seeding before the first user turn / Settings open.
- `RTI/Sources/Secrets.swift` — **unchanged since Stage 0**. Contains only the `kimiBaseURL` plus two empty `_legacy*` strings used by the one-time migration. There are no API-key literals in committed code.

## Build

```
xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug build
** BUILD SUCCEEDED **
```

## Automated checks (✅ passed)

- [x] Migration `v3_mode_reference_text` is additive (`ALTER TABLE ... ADD COLUMN`); `v1` and `v2` untouched.
- [x] Four builtin modes seeded exactly once (guarded by `UserDefaults[rti.modes.seededV1]`).
- [x] Active mode id persisted; re-reads on next launch via `ModeStore.init`.
- [x] LLMController system message comes from `activeMode.systemPrompt` when the active mode exists and the prompt is non-empty.
- [x] Reference text is capped at 8000 characters before reaching Kimi.
- [x] Launch at Login wrapper handles `register()` / `unregister()` throws, returns error string, no crash.
- [x] Secrets.swift has no hardcoded key values; `Secrets.kimiAPIKey` / `sonioxAPIKey` read exclusively from `CredentialStore` (Keychain).
- [x] POC-2 (transcripts), POC-3 (streaming), POC-4 (screen context), POC-5 (persistence), POC-6 (windows) files functionally unchanged.

## User-attestation (manual)

| # | Step | Pass? |
|---|------|-------|
| 1 | Fresh launch → Settings → Modes shows Meeting / Interview / Coding / Custom; Meeting is active. | [ ] |
| 2 | Select Coding → Set Active → close Settings → send "Fix this Python function: def add(a,b): return a-b". Response is code-first with fenced code. | [ ] |
| 3 | Select Meeting → paste "My name is Alex. Current project: RTI." into reference text → Save → Set Active → send "what is the current project?" → response names RTI. | [ ] |
| 4 | Settings → Modes → edit Meeting's system prompt → Save → next turn reflects new prompt. | [ ] |
| 5 | Settings → General → Launch at Login toggle on → check System Settings → General → Login Items lists RTI (works only for properly-signed builds; ad-hoc may error — error shown inline). | [ ] |
| 6 | Settings → General shows the read-only hotkey table (⌘\ / ⌘⇧R / ⌘↵ / ⌘H). | [ ] |
| 7 | Settings → Keys flow still works (replace a key, save, "Saved" indicator). | [ ] |
| 8 | Quit + relaunch → active mode persists; reference text persists; keys persist in Keychain. | [ ] |
| 9 | POC-1/2/3/4/5/6 regression: overlay + widgets + audio + OCR + recent sessions all still work. | [ ] |

## Known limitations (by design for POC-7)

- **No custom hotkey rebinding.** The General tab only shows the defaults. Rebinding is planned but requires UI + Carbon unregistration plumbing that's out of scope for the POC series.
- **No audio device or retention tabs.** Device selection uses the system default input (`AVAudioEngine.inputNode`). Retention will land with the final release prep.
- **No per-mode multiple reference files.** A single reference-text blob per mode ships here. Multi-file support would need a separate `reference_files` + join table; deferred until real usage justifies it.
- **Mode selector lives only in Settings.** No top-widget dropdown yet — the top widget stays compass/hide/stop. Adding mode switching to the top widget is a low-effort follow-up.
- **LaunchAtLogin on ad-hoc-signed local builds will surface an error from `SMAppService`.** Expected. The release build (Stage 5 / signing) should make it work.
- **Reference text injection is static.** Does not attempt retrieval / chunking — the whole capped string is attached every turn.

## Decision gate for Stage 5

Once user-attestation rows pass, Stage 5 (Release prep: signing, notarization, README, PRIVACY, DMG, GitHub release) is unblocked.
