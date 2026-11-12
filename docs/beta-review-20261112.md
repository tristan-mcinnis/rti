# RTI beta review

**12 November 2026.** This review covers the local source at `67c44ec8`. The installed recorder is a separate baseline. Its executable fingerprint before this work was `98fa19a87335d5e8dee541daace5a7defda39c501c95133adac1f3d07fea89c3`. The ordinary install script removes the installed bundle and relaunches RTI. The beta needs its own build path.

| Review item | What to decide |
| --- | --- |
| [Stimulus identity and exposure](research-stimulus-design-20261112.md) | Keep the planned guide moment, moderator-confirmed material shown, and material a participant discusses distinct. Preserve both timestamps across an upgrade. |
| [Live answer language](live-answer-language-20261112.md) | In English Assist replies, lead with the English finding. Put exact Chinese evidence and tone-marked pinyin on separate lines. |
| [State-machine coverage](state-coverage-20261112.md) | Prioritize recoverable data loss and false completion. The source index names each owner, transition and remaining proof. |
| [Window stability](window-stability-20261112.md) | Keep the workspace frame and Space stable through live updates. Exercise native drag, zoom, minimize, restore and full-screen transitions before adopting the compact header. |
| [Transcript and state audit](state-audit-20261112.md) | Keep the audio leg as a fact, retain unverified speaker labels as such, preserve original turns across stream changes, and resolve conflicting settings explicitly. |
| [Inline notes and Screenshots](capture-audit-20261112.md) | Accept a typed note only after it is journaled. Anchor marker spans to recorded audio time. Apply the effective screenshot policy at capture, archive and outbound dispatch. |
| [Cmd+K baseline and overlay inventory](palette-baseline-20261112.md) | Use the same timed boundaries before and after the fix. Keep presentation latency, filtering work and focus behavior distinguishable. |
| [Research moderation](research-moderation-design-20261112.md) | Upgrade the three existing actions, add Said vs done, and validate exact words against original turns before displaying claims. |
| [Project codebook](codebook-design-20261112.md) | Store attributable entries per group. Permit two codebook files in the selected project, which RTI currently treats as read-only. Test this first with an invented project. |
| [Guide tracker and header](guide-tracker-design-20261112.md) | Follow the live question by default, preserve manual control, label the active marker, and reclaim about 79 points at both supported widths. The design links the four baseline renders. |

Baseline verification ran all 800 hostless unit tests across two invocations. The standard suite skipped its two opt-in timing checks. Both passed with timing enabled. The Guide render uses an invented session at 860 × 660 and 720 × 520 points. The palette probe uses invented live transcript events and real fixture chat files. Live provider calls, audio hardware capture and a displayed two-instance beta were outside these baseline tests.

## A beta that can coexist with the installed recorder

Build a separate signed app, **RTI Beta.app**, with its own executable name, bundle ID, defaults domain and stable signing identity. Keep its microphone, system audio and screen permissions separate. Give it a visibly different window/menu title. Build from a reviewed local commit with the keyless compile-time stub. Request beta credentials through the beta’s own Settings. Leave the installed recorder available throughout.

| Boundary | Proposed beta behavior and proof |
| --- | --- |
| Files | Resolve preferences, credentials, assets, logs, temporary WAVs, crash marker, sessions, raw exports, projects and chat history inside the beta profile. Set explicit roots on first launch. Refuse recovery or recording when a path is missing, resolves through a symlink to production, or falls back to production. Test a normal Finder launch as well as a fixture launch. Existing seams include `AppSupportPaths`, `VaultPaths` and `AppLog`. |
| Background work | Recover only beta recordings. Keep the downstream meeting processor and login-item registration disabled for the beta. Scope startup WAV sweeps and CoreAudio aggregate creation/cleanup to beta-owned resources. Current code cleans by aggregate display name. Cross-process visibility of those private devices has not been tested. |
| Shortcuts and control | Stable keeps its global shortcuts and Quick Launch control endpoint. Handle beta shortcuts while its window is focused. Use a private beta control socket and omit publication to the stable House command directory. The current socket server can unlink an existing endpoint. Test opening, quitting and relaunching the beta while the other instance owns the fixture socket. |
| Screens | Carry over the current deny-list as a read-only safety input, add both app identities to capture exclusions, and honor local-vision controls. The installed recorder excludes its own identity by default. Exercise capture in both directions with invented windows to see whether it can capture the beta; record the result before testing with meeting content. Validate the effective modes with fake capture and model transports first. |
| Coexistence | Exercise start, pause, markers, screenshot policy, finish and upgrade with an invented session. In a controlled two-instance test, verify continuous audio on the reference recorder, byte-identical reference files, unchanged permissions/settings and working shortcuts. Compare the installed executable fingerprint before handing over a clickable beta. |

After approval, isolate the beta and establish the native window tests. Implement transcript confidence and lifecycle fixes, then journaled notes, palette performance and screenshot controls. Build moderation, codebook and Guide changes on those foundations in separate tested commits. Exercise native controls again with the compact header. Run the long-session performance comparison and the [15-minute manual checklist](../RTI/VERIFY.md). Capture matching after renders. The release decision follows hands-on beta testing.

**Test isolation.** The shared render fixture omits `project_roots`, and the render harness initializes the chat controller before installing that fixture. An offscreen header can therefore enumerate the default project directory. The final baseline runs use a disposable fixture with explicit empty project roots. Apply the same correction to the shared fixture and initialize it before the controller when the implementation phase starts.
