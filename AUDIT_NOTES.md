# RTI Code Audit — 2026-05-01

## Architecture

**RTI** is a macOS (14.0+) real-time meeting intelligence app. It captures mic + system audio via AVAudioEngine and ScreenCaptureKit, streams to Soniox for live diarized transcription, provides AI assistance through DeepSeek's chat API (deepseek-v4-flash), and persists everything to a local SQLite database (GRDB) with FTS5 search.

- **Audio**: Mic capture (`AudioCaptureManager`), system audio via SCStream (`SystemAudioCapture`), WAV writer
- **Soniox**: Realtime WebSocket transcription (`SonioxClient` via Starscream), async file transcription (`SonioxFileTranscribeClient`)
- **LLM**: DeepSeek chat streaming (`DeepSeekClient`), conversation controller, prompts for assist/recap/followups
- **Session**: Lifecycle management (`SessionCoordinator`), export, search (FTS5), Q&A, title generation, transcript regeneration
- **Database**: GRDB-backed, 8 schema migrations, models for sessions/transcripts/chat/summaries/modes
- **UI**: Floating overlay panel, mini/top widgets, session history, session detail, debug console, settings, onboarding
- **Credentials**: File-backed JSON store (`KeychainStore`) — avoids macOS Keychain ACL re-auth on ad-hoc signed builds
- **No test suite** exists in this repository

## Full Findings Table

| # | File:Line | Severity | Category | Problem | Fix Applied |
|---|-----------|----------|----------|---------|-------------|
| F1 | `SessionCoordinator.swift:383-407` | **HIGH** | Correctness (race) | System audio Soniox client & SCStream start even after `teardownOnFailure()` fires, because the async `Task { @MainActor }` block hasn't executed yet. Leads to leaked resources. | ✅ Fixed — added `self.isRunning` guard |
| F2 | `SummaryController.swift:197-206` | **MEDIUM** | Correctness (data loss) | `parseSections` silently drops all LLM response content before the first `##` heading — text is appended to `currentContent` with `currentSection=nil` then never emitted. | ✅ Fixed — captures preamble in `"Preamble"` key |
| F3 | `DeepSeekClient.swift:58` | **MEDIUM** | Correctness (dead code) | `request.timeoutInterval = smart ? 120 : 60` has no effect — `URLRequest.timeoutInterval` is ignored by the async `session.bytes(for:)` API. Smart-mode hangs could persist 300s instead of 120s. | ✅ Fixed — added `withThrowingTaskGroup` timeout race |
| F4 | `SessionTitleController.swift:102-107` | **LOW** | Performance | Three `NSRegularExpression` instances recreated via `try?` on every `parseFirstTitle` call. | ❌ Skipped (low impact) |
| F5 | `SonioxFileTranscribeClient.swift:72-76` | **LOW** | Code quality | Force-unwrap `data(using: .utf8)!` on multipart body strings — practically safe but an anti-pattern. | ❌ Skipped (low impact) |
| F6 | `OCRService.swift:11-45` | **SUSPECT** | Correctness (leak) | `withCheckedThrowingContinuation` might never resume if Vision's completion handler silently fails to fire (theoretical). | ❌ Flagged for review |
| F7 | `LLMController.swift:172,255` | **SUSPECT** | Correctness (latent) | `persistSessionId` captured before stream; if session changed mid-stream, assistant message persists to wrong session. Protected by `cancel()` on session change in practice. | ❌ Flagged for review |

## Fix Diffs

### F1 — `SessionCoordinator.swift` line 384

**Rationale**: `teardownOnFailure()` runs synchronously when mic/audio capture fails, but the system audio `Task { @MainActor }` hasn't executed yet. Without this guard, a new Soniox client + SCStream would be created and leaked after the session already failed.

```diff
- guard let self else { return }
+ guard let self, self.isRunning else { return }
```

### F2 — `SummaryController.swift` lines 199-203

**Rationale**: When the LLM produces preamble text before the first `## Summary` heading, the old code appended it to `currentContent` but `currentSection` was `nil`, so it was never flushed to `result`. The full response is still saved as `rawResponse`/`summaryText`, but structured section extraction now preserves preamble.

```diff
     if let section = currentSection {
         result[section] = ...
+    } else if !currentContent.isEmpty {
+        result["Preamble"] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
     }
```

### F3 — `DeepSeekClient.swift` lines 43-91

**Rationale**: `URLRequest.timeoutInterval` is not enforced by the async `URLSession.bytes(for:)` API — only `URLSessionConfiguration.timeoutIntervalForResource` (300s) applies. Added a `withThrowingTaskGroup` that races the SSE stream against a `Task.sleep` timer (60s normal / 120s smart mode). The stream processing loop was extracted to `processStream()`.

```diff
- request.timeoutInterval = smart ? 120 : 60
+ let streamTimeoutSeconds: Double = smart ? 120 : 60

- for try await line in bytes.lines { ... }
- continuation.finish()
+ try await withThrowingTaskGroup(of: Void.self) { group in
+     group.addTask {
+         try await Task.sleep(nanoseconds: UInt64(streamTimeoutSeconds * 1_000_000_000))
+         throw DeepSeekError.streamError("Stream timed out after \(Int(streamTimeoutSeconds))s")
+     }
+     group.addTask { [self] in
+         try await processStream(bytes, continuation: continuation)
+     }
+     _ = try await group.next()
+     group.cancelAll()
+ }
```

## Suspect Findings (Not Fixed — Flagged for Review)

### F6 — OCRService continuation leak (theoretical)

The `withCheckedThrowingContinuation` in `OCRService.recognizeText` dispatches `handler.perform([request])` on a background queue. If Vision somehow never calls the completion handler (a bug in the OS framework itself), the continuation would leak and the caller would hang forever. This is extremely unlikely in practice — `VNRecognizeTextRequest` is a well-tested framework API. Worth noting but not worth adding boilerplate timeouts for.

### F7 — LLM persistSessionId capture

`LLMController.performSend` captures `persistSessionId` before starting the stream. If the user switches sessions during the stream (via the `cancel()` path), the assistant's response could be persisted to the wrong session. In practice this is protected because `performSend` always calls `currentTask?.cancel()` first, and `loadHistoryForCurrentSession` is called on session switch. The worst case is a stale DB row that belongs to an old session — no data leak, just a misplaced chat message. Low severity, but worth a follow-up refactor to re-read `currentSessionId` after the stream completes.

## Build Verification

All changes compile cleanly with `xcodebuild -project RTI/RTI.xcodeproj -scheme RTI -configuration Debug`. Only pre-existing warnings (unused `self` capture, deprecated `onChange` variant) remain.
