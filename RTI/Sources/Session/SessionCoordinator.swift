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

    private let audio = AudioCaptureManager()
    private let wav = WAVWriter()
    private var soniox: SonioxClient?
    private var lastFinalizedEndMs: Int = 0
    private var zeroEndMsSeen: Set<String> = []
    private var delayedCompleteTask: Task<Void, Never>?

    private static let resumeWindowSeconds: TimeInterval = 300

    private init() {}

    /// Ensure there is a chat session available for LLM turns before any audio
    /// is started. Resumes the most recent session if it was active within the
    /// last 5 minutes; otherwise creates a chat-only session (no WAV path yet).
    func bootstrapChatSession() {
        guard currentSessionId == nil else { return }

        do {
            let recent: Session? = try RTIDatabase.shared.pool.read { db in
                try Session
                    .order(Column("started_at").desc)
                    .limit(1)
                    .fetchOne(db)
            }
            let now = Date()
            if let recent {
                let reference = recent.endedAt ?? recent.startedAt
                if now.timeIntervalSince(reference) <= Self.resumeWindowSeconds {
                    currentSessionId = recent.id
                    startedAt = recent.startedAt
                    return
                }
            }
            let sessionId = UUID().uuidString
            let session = Session(id: sessionId, startedAt: now, endedAt: nil, wavPath: nil, notes: nil)
            try RTIDatabase.shared.pool.write { db in try session.insert(db) }
            currentSessionId = sessionId
            startedAt = now
        } catch {
            NSLog("[RTI] bootstrapChatSession failed: \(error)")
        }
    }

    func switchToSession(id: String) {
        guard !isRunning else { return } // don't swap active-audio session
        do {
            guard let session = try RTIDatabase.shared.pool.read({ db in
                try Session.fetchOne(db, key: id)
            }) else { return }
            currentSessionId = session.id
            startedAt = session.startedAt
            liveEntries = []
            interimLine = nil
        } catch {
            NSLog("[RTI] switchToSession failed: \(error)")
        }
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
        let entry = TranscriptEntry(
            id: UUID().uuidString,
            sessionId: sessionId,
            speakerId: "note",
            startMs: offsetMs,
            endMs: offsetMs,
            text: trimmed,
            confidence: 1.0,
            isFinal: true,
            createdAt: Date()
        )
        do {
            try RTIDatabase.shared.pool.write { db in try entry.insert(db) }
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
        } catch {
            NSLog("[RTI] insertNote failed: \(error)")
            return false
        }
    }

    func recentSessions(limit: Int = 10) -> [Session] {
        do {
            return try RTIDatabase.shared.pool.read { db in
                try Session
                    .order(Column("started_at").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            NSLog("[RTI] recentSessions failed: \(error)")
            return []
        }
    }

    /// Delete sessions (and FK-cascaded transcripts + chat_messages) older than
    /// `days` from `started_at`. Called on launch for retention. Skips the
    /// currently-active session and any still-open session so we don't pull
    /// data out from under a live recording.
    func pruneOldSessions(days: Int = 30) {
        let threshold = Date().addingTimeInterval(-Double(days) * 86_400)
        let activeId = currentSessionId ?? ""
        do {
            try RTIDatabase.shared.pool.write { db in
                _ = try Session
                    .filter(Column("started_at") < threshold)
                    .filter(Column("ended_at") != nil)
                    .filter(Column("id") != activeId)
                    .deleteAll(db)
            }
        } catch {
            NSLog("[RTI] pruneOldSessions failed: \(error)")
        }
    }

    /// One-time cleanup: close orphaned sessions (endedAt == nil but not current),
    /// fill missing durations for completed sessions.
    func normalizeLegacySessions() {
        do {
            try RTIDatabase.shared.pool.write { db in
                let currentId = currentSessionId
                // Close orphaned open sessions
                try db.execute(sql: """
                    UPDATE sessions
                    SET ended_at = started_at
                    WHERE ended_at IS NULL AND id != ?
                    """, arguments: [currentId ?? ""])
            }
        } catch {
            NSLog("[RTI] normalizeLegacySessions failed: \(error)")
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

    /// Delete a saved session: removes the row (cascades to transcripts /
    /// chat_messages / summary), unlinks the WAV file if present, and clears
    /// currentSessionId if it pointed at the deleted session.
    func deleteSession(id: String) {
        guard !isRunning || currentSessionId != id else {
            // Refuse to delete the actively-recording session.
            return
        }
        do {
            let session = try RTIDatabase.shared.pool.read { db in
                try Session.fetchOne(db, key: id)
            }
            if let path = session?.wavPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            try RTIDatabase.shared.pool.write { db in
                _ = try Session.filter(Column("id") == id).deleteAll(db)
            }
            if currentSessionId == id {
                currentSessionId = nil
                startedAt = nil
                liveEntries = []
                interimLine = nil
            }
        } catch {
            NSLog("[RTI] deleteSession failed: \(error)")
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
        do {
            guard var session = try RTIDatabase.shared.pool.read({ db in
                try Session.fetchOne(db, key: id)
            }) else { return }

            // If the saved mode has been deleted since this session was created,
            // clear the reference so LLMController falls back to the default.
            if let modeId = session.modeId,
               !ModeStore.shared.modes.contains(where: { $0.id == modeId }) {
                session.modeId = nil
            }

            session.endedAt = nil
            try RTIDatabase.shared.pool.write { db in try session.update(db) }

            currentSessionId = session.id
            startedAt = session.startedAt
            liveEntries = []
            interimLine = nil
            LLMController.shared.loadHistoryForCurrentSession()
        } catch {
            NSLog("[RTI] resumeSession failed: \(error)")
        }
    }

    private func launchSession() {
        let now = Date()
        let sessionId: String
        let wavURL: URL

        // If current session is ended (resumed), reuse it for recording
        if let currentId = currentSessionId,
           let existing = try? RTIDatabase.shared.pool.read({ db in try Session.fetchOne(db, key: currentId) }),
           existing.endedAt != nil {
            sessionId = currentId
            wavURL = WAVWriter.defaultURL(for: sessionId)
            do {
                try RTIDatabase.shared.pool.write { db in
                    if var s = try Session.fetchOne(db, key: sessionId) {
                        s.endedAt = nil
                        s.wavPath = wavURL.path
                        s.modeId = ModeStore.shared.activeModeId
                        try s.update(db)
                    }
                }
            } catch {
                lastError = "DB update failed: \(error)"
                return
            }
        } else {
            // Close any previous open session before creating a new one
            if let prevId = currentSessionId {
                do {
                    try RTIDatabase.shared.pool.write { db in
                        if var prev = try Session.fetchOne(db, key: prevId), prev.endedAt == nil {
                            prev.endedAt = now
                            try prev.update(db)
                        }
                    }
                } catch {
                    NSLog("[RTI] close previous session failed: \(error)")
                }
            }
            sessionId = UUID().uuidString
            wavURL = WAVWriter.defaultURL(for: sessionId)
            let calendarEvent = CalendarManager.shared.activeEvent()
            do {
                let session = Session(
                    id: sessionId,
                    startedAt: now,
                    endedAt: nil,
                    wavPath: wavURL.path,
                    notes: nil,
                    title: nil,
                    modeId: ModeStore.shared.activeModeId,
                    calendarEventId: calendarEvent?.eventIdentifier,
                    calendarTitle: calendarEvent?.title
                )
                try RTIDatabase.shared.pool.write { db in try session.insert(db) }
            } catch {
                lastError = "DB insert failed: \(error)"
                return
            }
        }

        do {
            try wav.open(at: wavURL)
        } catch {
            lastError = "Couldn't create audio file: \(error)"
            teardownOnFailure()
            return
        }

        let client = SonioxClient(apiKey: Secrets.sonioxAPIKey, url: SonioxClient.defaultURL)
        client.onWords = { [weak self] words in self?.handleWords(words) }
        client.onError = { [weak self] message in
            guard let self else { return }
            self.lastError = message
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

        currentSessionId = sessionId
        startedAt = now
        endedAt = nil
        liveEntries = []
        interimLine = nil
        lastFinalizedEndMs = 0
        zeroEndMsSeen = []
        isRunning = true
        LLMController.shared.loadHistoryForCurrentSession()
    }

    func stopSession() {
        guard isRunning, let sessionId = currentSessionId else { return }

        audio.stop()
        soniox?.finalize()
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
        wav.close()

        // Capture for the top widget's frozen duration display.
        self.endedAt = endedAt

        do {
            try RTIDatabase.shared.pool.write { db in
                if var session = try Session.fetchOne(db, key: sessionId) {
                    session.endedAt = endedAt
                    try session.update(db)
                }
            }
        } catch {
            NSLog("[RTI] session update failed: \(error)")
        }

        // Keep currentSessionId/startedAt set: chat turns can continue against
        // the same session after audio stops. A fresh session is only minted on
        // next app launch (via bootstrapChatSession) past the 5-minute window.
        interimLine = nil

        triggerSummaryIfNeeded(sessionId: sessionId)
    }

    private func triggerSummaryIfNeeded(sessionId: String) {
        let hasTranscripts: Bool = {
            do {
                return try RTIDatabase.shared.pool.read { db in
                    try TranscriptEntry
                        .filter(Column("session_id") == sessionId)
                        .filter(Column("is_final") == 1)
                        .limit(1)
                        .fetchOne(db) != nil
                }
            } catch { return false }
        }()

        guard hasTranscripts else { return }

        Task { @MainActor in
            await SessionTitleController.shared.generateTitle(for: sessionId)
            await SummaryController.shared.generateSummary(for: sessionId)
        }
    }

    private func teardownOnFailure() {
        audio.stop()
        soniox?.disconnect()
        soniox = nil
        wav.close()
    }

    /// Synchronous teardown invoked from applicationWillTerminate. Soniox is
    /// dropped without waiting for the 1.5s finalize roundtrip — remaining
    /// audio is already on disk via the WAV writer; transcript finals for the
    /// last second or two will be lost, which beats truncating the WAV header.
    func emergencyShutdown() {
        guard isRunning else { return }
        audio.stop()
        soniox?.disconnect()
        soniox = nil
        wav.close()
        if let sid = currentSessionId {
            do {
                try RTIDatabase.shared.pool.write { db in
                    if var s = try Session.fetchOne(db, key: sid), s.endedAt == nil {
                        s.endedAt = Date()
                        try s.update(db)
                    }
                }
            } catch {
                NSLog("[RTI] emergencyShutdown DB write failed: \(error)")
            }
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
            let runs = groupByRuns(finals)
            let now = Date()
            do {
                try RTIDatabase.shared.pool.write { db in
                    for run in runs {
                        let entry = TranscriptEntry(
                            id: UUID().uuidString,
                            sessionId: sessionId,
                            speakerId: speakerLabel(run.speaker),
                            startMs: run.startMs,
                            endMs: run.endMs,
                            text: run.text,
                            confidence: run.confidence,
                            isFinal: true,
                            createdAt: now
                        )
                        try entry.insert(db)
                    }
                }
            } catch {
                NSLog("[RTI] transcript insert failed: \(error)")
            }

            for run in runs {
                liveEntries.append(LiveEntry(
                    speakerId: speakerLabel(run.speaker),
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
            interimLine = nil
        } else {
            let runs = groupByRuns(interims)
            interimLine = runs.map { "\(speakerLabel($0.speaker)): \($0.text)" }.joined(separator: "  ")
        }
    }

    private struct Run {
        let speaker: Int
        let text: String
        let startMs: Int
        let endMs: Int
        let confidence: Double
    }

    private func groupByRuns(_ words: [SonioxWord]) -> [Run] {
        guard !words.isEmpty else { return [] }
        var groups: [[SonioxWord]] = []
        for word in words {
            if groups.last?.last?.speaker == word.speaker {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups.map { group in
            let confidenceAvg = group.map(\.confidence).reduce(0, +) / Double(group.count)
            return Run(
                speaker: group[0].speaker,
                text: group.map(\.text).joined(),
                startMs: group.first?.startMs ?? 0,
                endMs: group.last?.endMs ?? 0,
                confidence: confidenceAvg
            )
        }
    }

    private func speakerLabel(_ speaker: Int) -> String {
        // POC-2 is mic-only: everything captured is the user. When system-audio loopback lands
        // in a later POC, it will run a second audio stream with a different speaker mapping.
        "self"
    }
}
