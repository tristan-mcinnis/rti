import AppKit
import AVFoundation
import Combine
import Foundation
import GRDB

struct LiveEntry: Identifiable {
    let id = UUID()
    let speakerId: String
    let text: String
    let startMs: Int
    let confidence: Double
}

@MainActor
final class SessionCoordinator: ObservableObject {
    static let shared = SessionCoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var currentSessionId: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?
    @Published private(set) var liveEntries: [LiveEntry] = []
    @Published private(set) var interimLine: String?
    @Published private(set) var lastError: String?
    /// True when `lastError` came from a Soniox auth/billing failure
    /// (`SonioxFailure.isAuth`). UI uses this to gate the "Open Settings"
    /// affordance on the error banner. Reset whenever `lastError` is
    /// cleared or replaced by a non-auth failure.
    @Published private(set) var lastErrorIsAuth: Bool = false

    private let audio = AudioCaptureManager()
    private let systemAudio = SystemAudioCapture()
    private let wav = WAVWriter()
    private var soniox: SonioxClient?
    private var systemSoniox: SonioxClient?
    private var lastFinalizedEndMs: Int = 0
    private var lastSystemFinalizedEndMs: Int = 0
    private var zeroEndMsSeen: Set<String> = []
    private var zeroSystemEndMsSeen: Set<String> = []
    private var micInterimText: String?
    private var systemInterimText: String?
    private var delayedCompleteTask: Task<Void, Never>?
    /// Active session metadata held in memory — there's no `sessions` row
    /// to persist them. Set on launch, consumed by `CorpusManager.render-
    /// Session` at session-end, cleared after.
    private var activeWavPath: String?
    private var activeModeId: String?

    private static let resumeWindowSeconds: TimeInterval = 300

    private init() {}

    /// Ensure there is a chat session available for LLM turns before any audio
    /// is started. Resumes the most recent session if it was active within the
    /// last 5 minutes; otherwise creates a chat-only session (no WAV path yet).
    func bootstrapChatSession() {
        guard currentSessionId == nil else { return }
        // Try to resume the most recent session from the markdown corpus
        // if it was within the resume window. Otherwise mint a fresh
        // in-memory session id — no DB write needed; the session becomes
        // a markdown file when (and if) the user records audio + the
        // session ends.
        let recent = CorpusBackedStore.allSessions().first
        let now = Date()
        if let recent {
            let reference = recent.endedAt ?? recent.startedAt
            if now.timeIntervalSince(reference) <= Self.resumeWindowSeconds {
                currentSessionId = recent.id
                startedAt = recent.startedAt
                activeModeId = recent.modeId
                activeWavPath = recent.wavPath
                return
            }
        }
        currentSessionId = UUID().uuidString
        startedAt = now
    }

    func switchToSession(id: String) {
        guard !isRunning else { return } // don't swap active-audio session
        guard let session = CorpusBackedStore.session(id: id) else { return }
        currentSessionId = session.id
        startedAt = session.startedAt
        activeWavPath = session.wavPath
        activeModeId = session.modeId
        liveEntries = []
        interimLine = nil
    }

    /// Insert a user-authored note into the current session's transcript at the
    /// current playback offset. Notes use a dedicated speaker_id so the live
    /// view, session detail, and LLM context can render them distinctly while
    /// still flowing through the same TranscriptEntry pipeline.
    @discardableResult
    func insertNote(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionId = currentSessionId else { return false }
        guard let startedAt else { return false }
        let offsetMs = Int(max(0, Date().timeIntervalSince(startedAt) * 1000))
        // Open a JSONL stream lazily — notes can fire before the audio
        // session has launched.
        let writer = CorpusManager.shared.liveWriter(sessionId: sessionId)
            ?? CorpusManager.shared.openLive(sessionId: sessionId)
        writer.append(.note(ts: offsetMs, text: trimmed))
        liveEntries.append(LiveEntry(
            speakerId: "note",
            text: trimmed,
            startMs: offsetMs,
            confidence: 1.0
        ))
        if liveEntries.count > 500 {
            liveEntries.removeFirst(liveEntries.count - 500)
        }
        return true
    }

    func recentSessions(limit: Int = 10) -> [Session] {
        Array(CorpusBackedStore.allSessions().prefix(limit))
    }

    /// Delete completed sessions older than `days`. Deletes the markdown
    /// file under `~/meetings/` (which is canonical) plus any associated
    /// chat_messages. Skips the currently-active session.
    func pruneOldSessions(days: Int = 30) {
        let threshold = Date().addingTimeInterval(-Double(days) * 86_400)
        let activeId = currentSessionId
        for session in CorpusBackedStore.allSessions() where session.id != activeId {
            guard session.endedAt != nil, session.startedAt < threshold else { continue }
            deleteSession(id: session.id)
        }
    }

    func clearCurrentSessionMessages() {
        guard let sid = currentSessionId else { return }
        do {
            try RTIDatabase.shared.pool.write { db in
                _ = try ChatMessage.filter(Column("session_id") == sid).deleteAll(db)
            }
        } catch {
            NSLog("[RTI] clearCurrentSessionMessages failed: \(error)")
        }
    }

    /// Delete a saved session: deletes the markdown file under
    /// `~/meetings/`, deletes the chat_messages rows for the session,
    /// unlinks the WAV file if present, and clears currentSessionId if
    /// it pointed at the deleted session.
    func deleteSession(id: String) {
        guard !isRunning || currentSessionId != id else { return }
        // Look up the markdown file (if any) for the WAV reference + path.
        if let url = CorpusBackedStore.markdownURL(forSessionId: id) {
            if let fm = try? CorpusReader.readFrontmatter(url),
               let wavPath = fm.wavPath {
                try? FileManager.default.removeItem(atPath: (wavPath as NSString).expandingTildeInPath)
            }
            try? FileManager.default.removeItem(at: url)
        }
        // Drop chat_messages for the session — they live in SQLite.
        do {
            try RTIDatabase.shared.pool.write { db in
                _ = try ChatMessage.filter(Column("session_id") == id).deleteAll(db)
            }
        } catch {
            NSLog("[RTI] deleteSession chat purge failed: \(error)")
        }
        // Reindex FTS so the deleted file's transcript/summary rows go.
        do {
            try CorpusFTSReindexer.reindex(from: CorpusManager.shared.corpusDirectory, in: RTIDatabase.shared.pool)
        } catch {
            NSLog("[RTI] deleteSession FTS reindex failed: \(error)")
        }
        // Drop any orphaned live JSONL.
        CorpusManager.shared.deleteLive(sessionId: id)
        if currentSessionId == id {
            currentSessionId = nil
            startedAt = nil
            liveEntries = []
            interimLine = nil
        }
    }

    func toggleSession() {
        if isRunning {
            stopSession()
        } else {
            startSession()
        }
    }

    func startSession() {
        guard !isRunning else { return }
        lastError = nil
        lastErrorIsAuth = false
        delayedCompleteTask?.cancel()
        // Cancel any in-flight stream and reset the in-memory entries, but do
        // NOT delete chat_messages from the DB here — that would erase the
        // history of a session the user is about to resume.
        LLMController.shared.resetMemory()

        audio.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.lastError = "Microphone permission denied."
                self.promptForMicrophoneAccess()
                return
            }
            self.launchSession()
        }
    }

    /// Surface mic denial as an actionable NSAlert with a deep link into the
    /// macOS Privacy pane, instead of just leaving an error string on a
    /// surface the user may not be looking at.
    private func promptForMicrophoneAccess() {
        let alert = NSAlert()
        alert.messageText = "Microphone access required"
        alert.informativeText = "RTI needs microphone access to transcribe audio. Open System Settings to grant access, then try Start Session again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func resumeSession(id: String) {
        guard !isRunning else { return }
        guard let session = CorpusBackedStore.session(id: id) else { return }

        // If the saved mode has been deleted since this session was
        // created, clear the reference so LLMController falls back to
        // the default.
        let modeId: String?
        if let mid = session.modeId,
           ModeStore.shared.modes.contains(where: { $0.id == mid }) {
            modeId = mid
        } else {
            modeId = nil
        }

        currentSessionId = session.id
        startedAt = session.startedAt
        endedAt = nil
        activeWavPath = session.wavPath
        activeModeId = modeId
        liveEntries = []
        interimLine = nil
        LLMController.shared.loadHistoryForCurrentSession()
    }

    private func launchSession() {
        let now = Date()
        let sessionId: String
        let wavURL: URL

        // Mint a fresh session id if there's no in-memory one (or the
        // existing one belongs to an already-rendered markdown file we
        // shouldn't overwrite). The bootstrap path is what populates
        // currentSessionId on launch — here we trust it.
        if let currentId = currentSessionId,
           CorpusBackedStore.markdownURL(forSessionId: currentId) == nil {
            sessionId = currentId
        } else {
            sessionId = UUID().uuidString
        }
        wavURL = WAVWriter.defaultURL(for: sessionId)
        activeWavPath = wavURL.path
        activeModeId = ModeStore.shared.activeModeId
        currentSessionId = sessionId
        startedAt = now
        endedAt = nil

        do {
            try wav.open(at: wavURL)
        } catch {
            lastError = "Couldn't create audio file: \(error)"
            teardownOnFailure()
            return
        }

        let client = SonioxClient(apiKey: Secrets.sonioxAPIKey, url: SonioxClient.defaultURL)
        client.onWords = { [weak self] words in self?.handleWords(words) }
        // Phase 3 dual-write: open a JSONL stream for this session so live
        // events land in the on-disk record as well as in SQLite.
        if let sid = currentSessionId {
            CorpusManager.shared.openLive(sessionId: sid)
        }
        client.onError = { [weak self] failure, didOpen in
            guard let self else { return }
            self.lastError = failure.userMessage(didOpen: didOpen)
            self.lastErrorIsAuth = failure.isAuth
            // A terminal Soniox failure means transcription is done; tear down audio
            // so isRunning flips off and the UI stops showing the live state.
            if self.isRunning { self.stopSession() }
        }
        client.connect()
        self.soniox = client

        audio.onPCMBuffer = { [weak self] buffer in self?.handleAudioBuffer(buffer) }
        do {
            try audio.start()
        } catch {
            lastError = "Audio start failed: \(error)"
            teardownOnFailure()
            return
        }

        // System audio: non-fatal if it fails — mic-only transcription still works.
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            let sysClient = SonioxClient(apiKey: Secrets.sonioxAPIKey, url: SonioxClient.defaultURL)
            sysClient.onWords = { [weak self] words in self?.handleSystemWords(words) }
            sysClient.onError = { [weak self] failure, didOpen in
                guard let self else { return }
                // System audio Soniox failure is non-fatal — mic keeps running.
                let message = failure.userMessage(didOpen: didOpen)
                NSLog("[RTI] system audio Soniox error: \(message)")
                RTILog.log("system soniox error — \(message)", category: "soniox")
            }
            sysClient.connect()
            self.systemSoniox = sysClient

            self.systemAudio.onPCMBuffer = { [weak self] buffer in self?.handleSystemAudioBuffer(buffer) }
            self.systemAudio.onError = { [weak self] msg in
                NSLog("[RTI] system audio capture error: \(msg)")
                RTILog.log("system capture error — \(msg)", category: "audio")
            }
            do {
                try await self.systemAudio.start()
            } catch {
                NSLog("[RTI] system audio start failed: \(error)")
                RTILog.log("system audio start failed — \(error)", category: "audio")
            }
        }

        currentSessionId = sessionId
        startedAt = now
        endedAt = nil
        liveEntries = []
        interimLine = nil
        micInterimText = nil
        systemInterimText = nil
        lastFinalizedEndMs = 0
        lastSystemFinalizedEndMs = 0
        zeroEndMsSeen = []
        zeroSystemEndMsSeen = []
        isRunning = true
        LLMController.shared.loadHistoryForCurrentSession()
    }

    func stopSession() {
        guard isRunning, let sessionId = currentSessionId else { return }

        // Stop audio capture before finalizing Soniox. This ordering
        // ensures the mic/system taps are removed so no new audio enters
        // the pipeline while finalize() signals end-of-stream to the
        // WebSocket. The 1.5s delay before disconnect() below gives
        // Soniox time to flush any remaining partial audio and deliver
        // final transcripts.
        //
        // Note: systemAudio.stop() calls SCStream.stopCapture with an
        // async completion handler that we intentionally do not await.
        // Prompt stop is preferred; a new session starting would create
        // a fresh SCStream that is independent of the old one.
        audio.stop()
        systemAudio.stop()
        soniox?.finalize()
        systemSoniox?.finalize()
        isRunning = false

        let endedAt = Date()
        delayedCompleteTask?.cancel()
        delayedCompleteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            self?.completeStop(sessionId: sessionId, endedAt: endedAt)
        }
    }

    private func completeStop(sessionId: String, endedAt: Date) {
        guard currentSessionId == sessionId else { return }

        soniox?.disconnect()
        soniox = nil
        systemSoniox?.disconnect()
        systemSoniox = nil
        wav.close()

        // Capture for the top widget's frozen duration display.
        self.endedAt = endedAt

        // Keep currentSessionId/startedAt set: chat turns can continue against
        // the same session after audio stops. A fresh session is only minted on
        // next app launch (via bootstrapChatSession) past the 5-minute window.
        micInterimText = nil
        systemInterimText = nil
        interimLine = nil

        triggerSummaryIfNeeded(sessionId: sessionId)
    }

    private func triggerSummaryIfNeeded(sessionId: String) {
        // Whether we have any transcript content lives in JSONL now.
        let liveURL = CorpusManager.shared.liveDirectory.appendingPathComponent("\(sessionId).jsonl")
        let hasContent: Bool = {
            guard FileManager.default.fileExists(atPath: liveURL.path) else { return false }
            guard let events = try? LiveJSONLReader.readAll(liveURL) else { return false }
            return events.contains(where: {
                if case .word(_, _, _, true, _, _) = $0 { return true }
                if case .note = $0 { return true }
                return false
            })
        }()

        let renderStartedAt = startedAt ?? Date()
        let renderEndedAt = endedAt
        let renderWavPath = activeWavPath
        let renderModeId = activeModeId

        if !hasContent {
            // Empty session — no markdown render. Drop in-memory active
            // metadata so the next session starts clean.
            activeWavPath = nil
            activeModeId = nil
            return
        }

        Task { @MainActor in
            await SessionTitleController.shared.generateTitle(for: sessionId)
            await SummaryController.shared.generateSummary(for: sessionId)
            await CorpusManager.shared.renderSession(
                sessionId: sessionId,
                startedAt: renderStartedAt,
                endedAt: renderEndedAt,
                wavPath: renderWavPath,
                modeId: renderModeId
            )
            // Active metadata done with — clear it after the render.
            self.activeWavPath = nil
            self.activeModeId = nil
        }
    }

    private func teardownOnFailure() {
        audio.stop()
        systemAudio.stop()
        soniox?.disconnect()
        soniox = nil
        systemSoniox?.disconnect()
        systemSoniox = nil
        wav.close()
    }

    /// Synchronous teardown invoked from applicationWillTerminate. Soniox is
    /// dropped without waiting for the 1.5s finalize roundtrip — remaining
    /// audio is already on disk via the WAV writer; transcript finals for the
    /// last second or two will be lost, which beats truncating the WAV header.
    func emergencyShutdown() {
        guard isRunning else { return }
        audio.stop()
        systemAudio.stop()
        soniox?.disconnect()
        soniox = nil
        systemSoniox?.disconnect()
        systemSoniox = nil
        wav.close()
        if let sid = currentSessionId {
            // Best-effort: flush JSONL so on next launch the orphan
            // recovery path can present this session for re-render.
            CorpusManager.shared.closeLive(sessionId: sid)
        }
        isRunning = false
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        wav.append(buffer)

        guard let int16 = buffer.int16ChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let byteCount = frameLength * MemoryLayout<Int16>.size
        let data = Data(bytes: int16[0], count: byteCount)
        soniox?.sendAudio(data)
    }

    private func handleSystemAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let int16 = buffer.int16ChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let byteCount = frameLength * MemoryLayout<Int16>.size
        let data = Data(bytes: int16[0], count: byteCount)
        systemSoniox?.sendAudio(data)
    }

    private func handleSystemWords(_ words: [SonioxWord]) {
        guard let sessionId = currentSessionId else { return }

        let regularFinals = words.filter { $0.isFinal && $0.endMs > lastSystemFinalizedEndMs }
        let zeroMsFinals: [SonioxWord] = words.compactMap { word in
            guard word.isFinal, word.endMs == 0 else { return nil }
            let key = "\(word.speaker)|\(word.text)|\(word.startMs)"
            return zeroSystemEndMsSeen.insert(key).inserted ? word : nil
        }
        let finals = regularFinals + zeroMsFinals
        let interims = words.filter { !$0.isFinal }

        if !finals.isEmpty {
            let runs = SpeakerTurn.collapse(finals)
            if let writer = CorpusManager.shared.liveWriter(sessionId: sessionId) {
                for run in runs {
                    writer.append(.word(
                        ts: run.startMs,
                        speaker: run.speaker,
                        text: run.text,
                        isFinal: true,
                        confidence: run.confidence,
                        channel: "system"
                    ))
                }
            }

            for run in runs {
                liveEntries.append(LiveEntry(
                    speakerId: SpeakerLabelMapping.rawLabel(speaker: run.speaker, channel: "system"),
                    text: run.text,
                    startMs: run.startMs,
                    confidence: run.confidence
                ))
            }
            if liveEntries.count > 500 {
                liveEntries.removeFirst(liveEntries.count - 500)
            }
            let nonZeroMax = finals.compactMap({ $0.endMs > 0 ? $0.endMs : nil }).max()
            if let m = nonZeroMax { lastSystemFinalizedEndMs = m }
        }

        if interims.isEmpty {
            systemInterimText = nil
        } else {
            let runs = SpeakerTurn.collapse(interims)
            systemInterimText = runs.map { "\(SpeakerLabelMapping.rawLabel(speaker: $0.speaker, channel: "system")): \($0.text)" }.joined(separator: "  ")
        }
        updateInterimLine()
    }

    private func handleWords(_ words: [SonioxWord]) {
        guard let sessionId = currentSessionId else { return }

        // Non-zero endMs: use watermark dedup. Zero endMs: dedup by
        // speaker+text+startMs to avoid duplicates when Soniox doesn't
        // provide timing data (e.g. very short utterances).
        let regularFinals = words.filter { $0.isFinal && $0.endMs > lastFinalizedEndMs }
        let zeroMsFinals: [SonioxWord] = words.compactMap { word in
            guard word.isFinal, word.endMs == 0 else { return nil }
            let key = "\(word.speaker)|\(word.text)|\(word.startMs)"
            return zeroEndMsSeen.insert(key).inserted ? word : nil
        }
        let finals = regularFinals + zeroMsFinals
        let interims = words.filter { !$0.isFinal }

        if !finals.isEmpty {
            let runs = SpeakerTurn.collapse(finals)
            // JSONL is now canonical for live transcripts. Markdown is
            // produced at session-end by `CorpusManager.renderSession`.
            if let writer = CorpusManager.shared.liveWriter(sessionId: sessionId) {
                for run in runs {
                    writer.append(.word(
                        ts: run.startMs,
                        speaker: run.speaker,
                        text: run.text,
                        isFinal: true,
                        confidence: run.confidence,
                        channel: "mic"
                    ))
                }
            }

            for run in runs {
                liveEntries.append(LiveEntry(
                    speakerId: SpeakerLabelMapping.rawLabel(speaker: run.speaker, channel: "mic"),
                    text: run.text,
                    startMs: run.startMs,
                    confidence: run.confidence
                ))
            }
            if liveEntries.count > 500 {
                liveEntries.removeFirst(liveEntries.count - 500)
            }
            let nonZeroMax = finals.compactMap({ $0.endMs > 0 ? $0.endMs : nil }).max()
            if let m = nonZeroMax { lastFinalizedEndMs = m }
        }

        if interims.isEmpty {
            micInterimText = nil
        } else {
            let runs = SpeakerTurn.collapse(interims)
            micInterimText = runs.map { "\(SpeakerLabelMapping.rawLabel(speaker: $0.speaker, channel: "mic")): \($0.text)" }.joined(separator: "  ")
        }
        updateInterimLine()
    }


    private func updateInterimLine() {
        let parts = [micInterimText, systemInterimText].compactMap { $0 }.filter { !$0.isEmpty }
        interimLine = parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}
