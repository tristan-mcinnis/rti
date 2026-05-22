import AppKit
import AVFoundation
import Foundation
import GRDB
import Observation

struct LiveEntry: Identifiable {
    let id = UUID()
    let speakerId: String
    let text: String
    let startMs: Int
    let confidence: Double
    /// "none" | "original" | "translation"
    let translationStatus: String
    /// Language code (e.g. "en", "fr") — nil for pre-translation tokens
    let language: String?
    /// Original language for translation tokens
    let sourceLanguage: String?
}

@Observable @MainActor
final class SessionCoordinator {
    static let shared = SessionCoordinator()

    private(set) var isRunning = false
    private(set) var currentSessionId: String?
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    /// Project this session is associated with (if any). Drives whether the
    /// live assistant prepends the project's curated instructions and is
    /// snapshotted into the session's markdown frontmatter at render time.
    /// Backed by `project_sessions` in SQLite for durability + UserDefaults
    /// for cross-launch stickiness.
    /// Forwarded from `SessionProjectBinding.shared` so existing callers
    /// (`LLMController`, views) see no change.
    var activeProjectId: String? { SessionProjectBinding.shared.activeProjectId }
    private(set) var liveEntries: [LiveEntry] = []
    private(set) var interimLine: String?
    private(set) var lastError: String?
    /// True when `lastError` came from a Soniox auth/billing failure
    /// (`SonioxFailure.isAuth`). UI uses this to gate the "Open Settings"
    /// affordance on the error banner. Reset whenever `lastError` is
    /// cleared or replaced by a non-auth failure.
    private(set) var lastErrorIsAuth: Bool = false
    /// When non-nil, Soniox will stream translation tokens alongside
    /// the regular transcript. Bound to UserDefaults and the live
    /// transcript toggle.
    var translationConfig: TranslationConfig? {
        didSet {
            audioPipeline.translationConfig = translationConfig
            // If a session is live, swap the Soniox transcription clients
            // so the change takes effect immediately (small 1–2s gap while
            // the new WebSocket handshakes — audio capture is uninterrupted).
            if isRunning {
                audioPipeline.reconfigureTranslation()
            }
        }
    }

    private let audioPipeline = AudioPipeline()
    private let transcriptPipeline = TranscriptPipeline()
    private var delayedCompleteTask: Task<Void, Never>?
    /// Active session metadata held in memory — there's no `sessions` row
    /// to persist them. Set on launch, consumed by `CorpusManager.render-
    /// Session` at session-end, cleared after.
    private var activeWavPath: String?
    private var activeModeId: String?

    private static let resumeWindowSeconds: TimeInterval = 300

    private init() {
        // SessionProjectBinding reads the sticky project from UserDefaults;
        // activeProjectId forwards to it.
        commonInit()
    }

    private func commonInit() {
        audioPipeline.onWords = { [weak self] words in
            self?.handleWords(words)
        }
        audioPipeline.onSystemWords = { [weak self] words in
            self?.handleSystemWords(words)
        }
        audioPipeline.onError = { [weak self] message, isAuth in
            self?.lastError = message
            self?.lastErrorIsAuth = isAuth
            if self?.isRunning == true { self?.stopSession() }
        }
    }

    /// Register all periodic analysis tasks with the scheduler. Extracted
    /// from the SessionCoordinator init so the wiring lives alongside other
    /// app-level wiring in AppDelegate rather than inside the session
    /// lifecycle. The scheduler stores watermarks internally; callers (the
    /// controllers) track their per-session state.
    static func registerAnalysisTasks() {
        let s = AnalysisScheduler.shared
        s.register(id: "notes", task: AnalysisScheduler.AnalysisTask(
            enabledKey: AnalysisSettingsDefaults.notesEnabledKey,
            execute: { sinceMs in
                await NotesGenerationController.shared.generate(
                    sessionId: SessionCoordinator.shared.currentSessionId ?? "",
                    sinceMs: sinceMs
                )
            }
        ))
        s.register(id: "dossiers", task: AnalysisScheduler.AnalysisTask(
            enabledKey: AnalysisSettingsDefaults.dossiersEnabledKey,
            execute: { sinceMs in
                await DossierController.shared.generate(
                    sessionId: SessionCoordinator.shared.currentSessionId ?? "",
                    sinceMs: sinceMs
                )
            }
        ))
        s.register(id: "themes", task: AnalysisScheduler.AnalysisTask(
            enabledKey: AnalysisSettingsDefaults.themesEnabledKey,
            execute: { sinceMs in
                await ThemesController.shared.generate(
                    sessionId: SessionCoordinator.shared.currentSessionId ?? "",
                    sinceMs: sinceMs
                )
            }
        ))
        s.register(id: "guide", task: AnalysisScheduler.AnalysisTask(
            enabledKey: AnalysisSettingsDefaults.guideEnabledKey,
            execute: { sinceMs in
                await DiscussionGuideController.shared.match(
                    sessionId: SessionCoordinator.shared.currentSessionId ?? "",
                    sinceMs: sinceMs
                )
            }
        ))
    }

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
                SessionProjectBinding.shared.refreshMembership(for: recent.id)
                return
            }
        }
        let newId = UUID().uuidString
        currentSessionId = newId
        startedAt = now
        // Carry the sticky project over to the fresh chat session so any
        // pre-recording Q&A already inherits the project's instructions.
        SessionProjectBinding.shared.carryOverToNewSession(newId)
    }

    func switchToSession(id: String) {
        guard !isRunning else { return } // don't swap active-audio session
        guard let session = CorpusBackedStore.session(id: id) else { return }
        currentSessionId = session.id
        startedAt = session.startedAt
        activeWavPath = session.wavPath
        activeModeId = session.modeId
        SessionProjectBinding.shared.refreshMembership(for: session.id)
        transcriptPipeline.reset()
        publishState()
    }

    /// Set (or clear) the project this session is associated with. Writes
    /// the new membership to `project_sessions`, removes any prior
    /// membership for this session, and persists the selection to
    /// UserDefaults so the picker remembers it across launches.
    func setActiveProject(_ projectId: String?) {
        SessionProjectBinding.shared.setActiveProject(projectId, forSessionId: currentSessionId)
    }

    /// Insert a user-authored note into the current session's transcript at the
    /// current playback offset. Notes use a dedicated speaker_id so the live
    /// view, session detail, and LLM context can render them distinctly while
    /// still flowing through the same TranscriptEntry pipeline.
    @discardableResult
    func insertNote(_ text: String) -> Bool {
        guard let sessionId = currentSessionId, let startedAt else { return false }
        let ok = transcriptPipeline.insertNote(text, sessionId: sessionId, startedAt: startedAt)
        if ok { publishState() }
        return ok
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
            RTILog.log("clearCurrentSessionMessages failed: \(error)", category: "session")
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
            RTILog.log("deleteSession chat purge failed: \(error)", category: "session")
        }
        // Reindex FTS so the deleted file's transcript/summary rows go.
        do {
            try CorpusFTSReindexer.reindex(from: CorpusManager.shared.corpusDirectory, in: RTIDatabase.shared.pool)
            try CorpusIndexer.reindex(from: CorpusManager.shared.corpusDirectory, in: RTIDatabase.shared.pool)
        } catch {
            RTILog.log("deleteSession FTS reindex failed: \(error)", category: "session")
        }
        // Drop any orphaned live JSONL.
        LiveSessionStore.shared.deleteLive(sessionId: id)
        NotificationCenter.default.post(name: .rtiSessionsChanged, object: nil)
        if currentSessionId == id {
            currentSessionId = nil
            startedAt = nil
            transcriptPipeline.reset()
            publishState()
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

        audioPipeline.requestPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.lastError = "Microphone permission denied."
                    self.promptForMicrophoneAccess()
                    return
                }
                self.launchSession()
            }
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
        SessionProjectBinding.shared.refreshMembership(for: session.id)
        transcriptPipeline.reset()
        publishState()
        LLMController.shared.loadHistoryForCurrentSession()
    }

    private func launchSession() {
        let now = Date()
        let sessionId: String

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
        activeWavPath = WAVWriter.defaultURL(for: sessionId).path
        activeModeId = ModeStore.shared.activeModeId
        currentSessionId = sessionId
        startedAt = now
        endedAt = nil

        // If the user has a sticky project selected, make sure the new
        // sessionId is registered in `project_sessions` — this is how the
        // live LLM controller looks up "what project is this session a
        // member of" each turn, and how renderSession captures the project
        // name into the markdown frontmatter when the session ends.
        SessionProjectBinding.shared.carryOverToNewSession(sessionId)

        do {
            _ = try audioPipeline.prepare(sessionId: sessionId)
        } catch {
            lastError = "Couldn't create audio file: \(error)"
            audioPipeline.abort()
            return
        }

        // Open a JSONL stream for this session so live events land in the
        // on-disk record alongside the in-memory transcript.
        LiveSessionStore.shared.openLive(sessionId: sessionId)

        do {
            try audioPipeline.start()
        } catch {
            lastError = "Audio start failed: \(error)"
            audioPipeline.abort()
            return
        }

        transcriptPipeline.reset()
        publishState()
        isRunning = true
        NotesGenerationController.shared.reset(for: sessionId)
        DossierController.shared.reset(for: sessionId)
        ThemesController.shared.reset(for: sessionId)
        DiscussionGuideController.shared.reset(for: sessionId)
        PeriodicCardsController.shared.resetForSession(sessionId)
        AnalysisScheduler.shared.start(
            intervalKey: AnalysisSettingsDefaults.notesIntervalKey,
            defaultInterval: AnalysisSettingsDefaults.defaultInterval
        )
        LLMController.shared.loadHistoryForCurrentSession()
    }

    func stopSession() {
        guard isRunning, let sessionId = currentSessionId else { return }

        AnalysisScheduler.shared.stop()

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
        audioPipeline.finalize()
        isRunning = false

        let endedAt = Date()
        self.endedAt = endedAt   // freeze widget timer immediately
        delayedCompleteTask?.cancel()
        delayedCompleteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            self?.completeStop(sessionId: sessionId, endedAt: endedAt)
        }
    }

    private func completeStop(sessionId: String, endedAt: Date) {
        guard currentSessionId == sessionId else { return }

        audioPipeline.finish()

        // Capture for the top widget's frozen duration display.
        self.endedAt = endedAt

        // Keep currentSessionId/startedAt set: chat turns can continue against
        // the same session after audio stops. A fresh session is only minted on
        // next app launch (via bootstrapChatSession) past the 5-minute window.
        transcriptPipeline.reset()
        publishState()

        // Don't `clear()` notes/dossiers here — they're persisted now and
        // the user wants to read them after the recording ends. The next
        // session's startSession() will call reset(for: newSessionId)
        // which loads that session's notes from the DB.

        finalizeCorpus(
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            wavPath: activeWavPath,
            modeId: activeModeId
        )
        activeWavPath = nil
        activeModeId = nil
    }

    /// Trigger the async title-gen → summary-gen → themes → markdown-render
    /// chain for a completed session. Skips the render if the session has
    /// no content (empty JSONL, no final words or notes).
    private func finalizeCorpus(
        sessionId: String,
        startedAt: Date?,
        endedAt: Date?,
        wavPath: String?,
        modeId: String?
    ) {
        // Close + flush JSONL so any pending writes are on disk.
        LiveSessionStore.shared.closeLive(sessionId: sessionId)
        let liveURL = LiveSessionStore.shared.liveDirectory.appendingPathComponent("\(sessionId).jsonl")
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
        guard hasContent else { return }
        Task { @MainActor in
            async let title: String? = SessionTitleController.shared.generateTitle(for: sessionId)
            async let summary: SessionSummary? = SummaryController.shared.generateSummary(for: sessionId)
            async let themesDone: Void = ThemesController.shared.generateHiFi(sessionId: sessionId)
            _ = await (title, summary, themesDone)
            await CorpusManager.shared.renderSession(
                sessionId: sessionId,
                startedAt: renderStartedAt,
                endedAt: endedAt,
                wavPath: wavPath,
                modeId: modeId
            )
            NotificationCenter.default.post(name: .rtiSessionsChanged, object: nil)
        }
    }

    private func teardownOnFailure() {
        audioPipeline.abort()
    }

    /// Synchronous teardown invoked from applicationWillTerminate. Soniox is
    /// dropped without waiting for the 1.5s finalize roundtrip — remaining
    /// audio is already on disk via the WAV writer; transcript finals for the
    /// last second or two will be lost, which beats truncating the WAV header.
    func emergencyShutdown() {
        guard isRunning else { return }
        audioPipeline.abort()
        if let sid = currentSessionId {
            // Best-effort: flush JSONL so on next launch the orphan
            // recovery path can present this session for re-render.
            LiveSessionStore.shared.closeLive(sessionId: sid)
        }
        isRunning = false
    }

    private func handleSystemWords(_ words: [SonioxWord]) {
        guard currentSessionId != nil else { return }
        transcriptPipeline.process(words: words, channel: "system")
        publishState()
    }

    private func handleWords(_ words: [SonioxWord]) {
        guard currentSessionId != nil else { return }
        transcriptPipeline.process(words: words, channel: "mic")
        publishState()
    }

    private func publishState() {
        interimLine = transcriptPipeline.interimLine
        liveEntries = transcriptPipeline.liveEntries
    }
}
