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
    @Published private(set) var liveEntries: [LiveEntry] = []
    @Published private(set) var interimLine: String?
    @Published private(set) var lastError: String?

    private let audio = AudioCaptureManager()
    private let wav = WAVWriter()
    private var soniox: SonioxClient?
    private var lastFinalizedEndMs: Int = 0

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
    /// `days` from `started_at`. Called on launch for retention.
    func pruneOldSessions(days: Int = 30) {
        let threshold = Date().addingTimeInterval(-Double(days) * 86_400)
        do {
            try RTIDatabase.shared.pool.write { db in
                _ = try Session
                    .filter(Column("started_at") < threshold)
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
        LLMController.shared.clear()

        audio.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.lastError = "Microphone permission denied. Grant access in System Settings → Privacy → Microphone."
                return
            }
            self.launchSession()
        }
    }

    func resumeSession(id: String) {
        guard !isRunning else { return }
        do {
            guard var session = try RTIDatabase.shared.pool.read({ db in
                try Session.fetchOne(db, key: id)
            }) else { return }

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
            NSLog("[RTI] WAV open failed: \(error)")
        }

        let client = SonioxClient(apiKey: Secrets.sonioxAPIKey, url: SonioxClient.defaultURL)
        client.onWords = { [weak self] words in self?.handleWords(words) }
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
        liveEntries = []
        interimLine = nil
        lastFinalizedEndMs = 0
        isRunning = true
        LLMController.shared.loadHistoryForCurrentSession()
    }

    func stopSession() {
        guard isRunning, let sessionId = currentSessionId else { return }

        audio.stop()
        soniox?.finalize()
        isRunning = false

        let endedAt = Date()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.completeStop(sessionId: sessionId, endedAt: endedAt)
        }
    }

    private func completeStop(sessionId: String, endedAt: Date) {
        guard currentSessionId == sessionId else { return }

        soniox?.disconnect()
        soniox = nil
        wav.close()

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
            await SummaryController.shared.generateSummary(for: sessionId)
        }
    }

    private func teardownOnFailure() {
        audio.stop()
        soniox?.disconnect()
        soniox = nil
        wav.close()
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

        let finals = words.filter { $0.isFinal && $0.endMs > lastFinalizedEndMs }
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
            lastFinalizedEndMs = max(lastFinalizedEndMs, finals.map(\.endMs).max() ?? lastFinalizedEndMs)
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
