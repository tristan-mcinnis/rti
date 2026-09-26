import AppKit
import AVFoundation
import Foundation
import Observation
import RTICore

/// Owns the live recording lifecycle. Ephemeral build: a session is purely a
/// run of live audio → transcript held in memory for the duration. Nothing is
/// persisted — no corpus, no database, no history. When the session ends the
/// transcript stays in memory until the next session resets it, and the WAV
/// recording is deleted.
@Observable @MainActor
final class SessionCoordinator {
    static let shared = SessionCoordinator()

    /// The session lifecycle as an explicit state machine, replacing the old
    /// binary `isRunning` — the missing "what's it doing right now?" signal
    /// (Granola-style). The cases and their transitions are documented on
    /// `SessionPhase` in RTICore, where pure policy over the phase can be
    /// tested without the app module.
    typealias Phase = SessionPhase

    private(set) var phase: Phase = .idle

    /// Audio is being captured (recording or paused). Kept as a derived flag so
    /// the ~40 existing call sites that gate on "is a session live" keep working
    /// unchanged while the richer `phase` drives the new UX.
    var isRunning: Bool {
        phase == .recording || phase == .paused
    }

    var isPaused: Bool {
        phase == .paused
    }

    /// True while the end-of-session summary is being generated (post-stop).
    var isSummarizing: Bool {
        phase == .summarizing
    }

    private(set) var currentSessionId: String?
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    /// When the just-finished session started a pause; used to subtract paused
    /// time from the displayed elapsed duration so the timer reflects captured
    /// time, not wall-clock.
    private(set) var pausedAt: Date?
    private var pausedAccumulated: TimeInterval = 0
    /// Result of the end-of-session auto-summary, surfaced so the record control
    /// can offer "Summary ready" (open it) vs. a quiet failure.
    private(set) var summaryURL: URL?
    private(set) var summaryFailed = false
    /// Short status shown by the recording HUD while the offline pass runs.
    private(set) var postProcessingStatus: String?
    private(set) var liveEntries: [LiveEntry] = []
    private(set) var interimLine: String?
    private(set) var lastError: String?
    /// True when `lastError` came from a Soniox auth/billing failure
    /// (`SonioxFailure.isAuth`). UI uses this to gate the "Open Settings"
    /// affordance on the error banner.
    private(set) var lastErrorIsAuth: Bool = false
    /// Whether live transcription is actually flowing (mic leg). Surfaced in
    /// the UI so the user always knows if their words are being captured.
    private(set) var transcriptionHealth: TranscriptionHealth = .idle
    /// User-facing mic mute (Zoom-style). Mutes only the mic leg — system
    /// audio keeps flowing. NOT for in-person sessions, where the mic IS the
    /// room capture. Resets to unmuted on every session start so a forgotten
    /// mute can't silently eat the next meeting.
    var micMuted = false {
        didSet { audioPipeline.micMuted = micMuted }
    }

    /// Non-fatal notice when the system-audio (other-party) leg drops while
    /// the mic leg keeps recording. nil when system audio is fine/absent.
    private(set) var systemAudioNotice: String?
    private(set) var systemAudioStartOffsetMs: Int?
    /// When non-nil, Soniox will stream translation tokens alongside
    /// the regular transcript. Bound to UserDefaults and the live
    /// transcript toggle.
    var translationConfig: TranslationConfig? {
        didSet {
            guard translationConfig != oldValue else { return }
            audioPipeline.translationConfig = translationConfig
            if isRunning {
                // Keep the transcript across the Soniox reconnect and continue
                // the timeline, so toggling translation never wipes preceding
                // entries or drops the next ones.
                transcriptPipeline.prepareForReconnect()
                audioPipeline.reconfigureStreamingClients()
                publishState()
            }
        }
    }

    private let audioPipeline = AudioPipeline()
    private let transcriptPipeline = TranscriptPipeline()
    /// Set while a start is in flight (during the async mic-permission prompt)
    /// so a second start can't kick off a duplicate permission dialog + launch.
    private var isStarting = false
    private var delayedCompleteTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var translationDefaultsObserver: NSObjectProtocol?
    private var activeSTTProviderId = STTProviders.activeId
    /// When the last session was stopped — used to reject a phantom restart
    /// fired immediately after a manual stop (the stop→start race).
    private var lastStopAt: Date?
    /// Cooldown after a stop during which a new start is ignored.
    private static let restartCooldown: TimeInterval = 3.0

    /// How long a stopped session's failure notice stays on screen.
    ///
    /// Long enough to read, short enough that it cannot still be there the next
    /// morning. Internal and mutable so a test need not wait five minutes.
    static var stopErrorRetirementNs: UInt64 = 300_000_000_000

    private var stopErrorRetireTask: Task<Void, Never>?

    /// WAV path for the active recording, deleted when the session ends.
    private var activeWavPath: String?

#if DEBUG
    /// Debug-only seam for the offscreen render proof (`RTIRenderTests`). It
    /// pushes transcript rows and a phase straight into the published state so
    /// the design can be compared against the mockups without a live meeting.
    /// Never compiled into a Release build and never called by the app.
    func seedForRenderProof(
        entries: [LiveEntry],
        interim: String?,
        phase: Phase,
        startedAt: Date?,
        lastError: String? = nil,
        lastErrorIsAuth: Bool = false
    ) {
        self.liveEntries = entries
        self.interimLine = interim
        self.phase = phase
        self.startedAt = startedAt
        self.lastError = lastError
        self.lastErrorIsAuth = lastErrorIsAuth
    }
#endif

    private init() {
        commonInit()
    }

    /// Register the periodic analysis tasks with the scheduler. Called once
    /// at launch from AppDelegate. The scheduler only fires the tasks whose
    /// enable flag is set, and only while a session is running.
    func registerAnalysisTasks() {
        AnalysisScheduler.shared.register(
            id: "notes",
            task: .init(enabledKey: AnalysisSettingsDefaults.notesEnabledKey) { _ in
                // Notes own their own watermark (so the manual Generate button
                // can't duplicate) — ignore the scheduler's sinceMs.
                await NotesGenerationController.shared.generate(sessionId: SessionCoordinator.shared.currentSessionId ?? "")
            }
        )
        AnalysisScheduler.shared.register(
            id: "discussionGuide",
            task: .init(enabledKey: AnalysisSettingsDefaults.guideEnabledKey) { sinceMs in
                await DiscussionGuideController.shared.match(sessionId: SessionCoordinator.shared.currentSessionId ?? "", sinceMs: sinceMs)
            }
        )
        AnalysisScheduler.shared.register(
            id: "findings",
            task: .init(enabledKey: AnalysisSettingsDefaults.findingsEnabledKey) { _ in
                // Intel owns its own watermark (so the manual Generate button
                // can't duplicate) — ignore the scheduler's sinceMs.
                await FindingsController.shared.generate(sessionId: SessionCoordinator.shared.currentSessionId ?? "")
            }
        )
        AnalysisScheduler.shared.register(
            id: "autoAssist",
            task: .init(enabledKey: AnalysisSettingsDefaults.autoAssistEnabledKey) { _ in
                // Auto mode owns its own watermark — ignore the scheduler's sinceMs.
                await AutoAssistController.shared.generate(sessionId: SessionCoordinator.shared.currentSessionId ?? "")
            }
        )
    }

    private func commonInit() {
        // Keep the live translation config in sync with UserDefaults without
        // letting every view push its own copy. Views mutate the defaults keys;
        // this store-derived update is the single writer to `translationConfig`.
        translationConfig = TranslationStore.currentConfig()
        translationDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let nextTranslation = TranslationStore.currentConfig()
                if self.translationConfig != nextTranslation {
                    self.translationConfig = nextTranslation
                }
                let nextSTTProviderId = STTProviders.activeId
                if self.activeSTTProviderId != nextSTTProviderId {
                    self.activeSTTProviderId = nextSTTProviderId
                    self.handleActiveSTTProviderChanged()
                }
            }
        }

        audioPipeline.onWords = { [weak self] words in
            self?.handleWords(words)
        }
        audioPipeline.onSystemWords = { [weak self] words in
            self?.handleSystemWords(words)
        }
        audioPipeline.onSystemAudioStarted = { [weak self] offsetMs in
            self?.systemAudioStartOffsetMs = offsetMs
            self?.transcriptPipeline.setSystemStartOffset(ms: offsetMs)
        }
        audioPipeline.onStreamRestarted = { [weak self] channel, atMs in
            guard let self, isRunning else { return }
            transcriptPipeline.restartStream(channel: channel, atMs: atMs)
            publishState()
        }
        audioPipeline.onError = { [weak self] message, isAuth in
            self?.lastError = message
            self?.lastErrorIsAuth = isAuth
            if self?.isRunning == true { self?.stopSession() }
        }
        audioPipeline.onTranscriptionHealth = { [weak self] health in
            self?.transcriptionHealth = health
        }
        audioPipeline.onSystemAudioHealth = { [weak self] health in
            switch health {
            case .failed:
                self?.systemAudioNotice = "Other-party audio stopped — still capturing your mic."
            case .live:
                self?.systemAudioNotice = nil
            case .idle, .connecting, .reconnecting:
                break
            }
        }
    }

    private func handleActiveSTTProviderChanged() {
        guard isRunning else { return }
        transcriptPipeline.prepareForReconnect()
        audioPipeline.reconfigureStreamingClients()
        publishState()
    }

    /// Insert a user-authored note into the live transcript at the current
    /// offset so it renders distinctly and feeds the LLM context.
    @discardableResult
    func insertNote(_ text: String) -> Bool {
        guard let startedAt else { return false }
        let startMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let ok = transcriptPipeline.insertNote(text, startedAt: startedAt)
        if ok {
            FindingsController.shared.recordUserMarkedNote(text, startMs: startMs)
            publishState()
        }
        return ok
    }

    /// Cheap live levels for the Audio I/O monitor — safe to poll at meter
    /// rate (~15 Hz). Device names are resolved separately (`audioDeviceNames`)
    /// since CoreAudio enumeration is heavier.
    func audioLevels() -> AudioLevels {
        let snap = audioPipeline.levelMeter.snapshot()
        return AudioLevels(
            isRunning: isRunning,
            systemActive: audioPipeline.systemAudioActive,
            mic: snap.micLevel,
            system: snap.systemLevel,
            micFlowing: snap.micFlowing,
            systemFlowing: snap.systemFlowing
        )
    }

    /// The input device in use and the output device the system-audio tap
    /// follows. Heavier (HAL enumeration) — poll at ~1 Hz, not meter rate.
    func audioDeviceNames() -> (input: String, output: String) {
        (AudioInputDeviceStore.currentInputName(), AudioInputDeviceStore.currentOutputName())
    }

    /// The record control's primary click. Idle/done → start a fresh session
    /// (the previous one is already archived — "new recording", not "clear").
    /// Recording/paused → finish. No-op during the brief finishing flush.
    func toggleSession() {
        switch phase {
        case .recording, .paused:
            stopSession()
        case .idle, .done, .summarizing:
            startSession(userInitiated: true)
        case .finishing:
            break
        }
    }

    /// Suspend capture without tearing down: stop feeding real audio to Soniox
    /// (the socket stays warm on silence, so resume is instant — no
    /// re-handshake) and freeze the elapsed timer. Paused audio is never
    /// transcribed. Mirrors the pause/resume contract users expect from Granola
    /// and Tactiq.
    func pause() {
        guard phase == .recording else { return }
        pausedAt = Date()
        audioPipeline.suspended = true
        VisualContextTrail.shared.setPaused(true)
        phase = .paused
        publishState()
    }

    func resume() {
        guard phase == .paused else { return }
        if let pausedAt { pausedAccumulated += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        audioPipeline.suspended = false
        VisualContextTrail.shared.setPaused(false)
        phase = .recording
        publishState()
    }

    func togglePause() {
        switch phase {
        case .recording: pause()
        case .paused: resume()
        default: break
        }
    }

    /// Captured-time elapsed (wall clock minus any paused spans). Drives the
    /// record control's timer so it counts real recorded time.
    func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        let end = endedAt ?? now
        var paused = pausedAccumulated
        if let pausedAt { paused += end.timeIntervalSince(pausedAt) }
        return max(0, end.timeIntervalSince(startedAt) - paused)
    }

    func startSession(userInitiated: Bool = false) {
        guard !isRunning, !isStarting else { return }
        // Reject the stop→start race: a phantom restart fired ~4s after a manual
        // stop (the "0:05 / no audio received" blip). Don't start while a stop is
        // still finalizing, or within a short cooldown after one. The cooldown
        // only guards against *automatic* restarts — a deliberate user
        // "new recording" press bypasses it.
        if delayedCompleteTask != nil { return }
        if !userInitiated,
           let stopped = lastStopAt, Date().timeIntervalSince(stopped) < Self.restartCooldown { return }
        isStarting = true
        lastError = nil
        lastErrorIsAuth = false
        // A retire task left over from the last session must not clear this
        // one's failure.
        stopErrorRetireTask?.cancel()
        stopErrorRetireTask = nil
        delayedCompleteTask?.cancel()
        LLMController.shared.resetMemory()

        audioPipeline.requestPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    isStarting = false
                    lastError = "Microphone permission denied."
                    promptForMicrophoneAccess()
                    return
                }
                launchSession()
            }
        }
    }

    /// Surface mic denial as an actionable NSAlert with a deep link into the
    /// macOS Privacy pane.
    private func promptForMicrophoneAccess() {
        let alert = NSAlert()
        alert.messageText = "Microphone access required"
        alert.informativeText = "RTI needs microphone access to transcribe audio. Open System Settings to grant access, then try Start Session again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        {
            NSWorkspace.shared.open(url)
        }
    }

    private func launchSession() {
        isStarting = false
        let now = Date()
        let sessionId = UUID().uuidString
        activeWavPath = WAVWriter.defaultURL(for: sessionId).path
        currentSessionId = sessionId
        startedAt = now
        endedAt = nil
        systemAudioStartOffsetMs = nil
        pausedAt = nil
        pausedAccumulated = 0
        audioPipeline.suspended = false
        summaryURL = nil
        summaryFailed = false
        postProcessingStatus = nil

        // Don't let "passive listener" framing bleed across sessions: a fieldwork
        // session leaves listenerMode on, which then mis-frames the next meeting
        // ("I never speak") where the user is actually a participant. Reconcile
        // to the active mode at every start.
        LLMController.shared.reconcileListenerModeForSessionStart()

        // Use a conservative current-calendar suggestion as optional context.
        // A manual choice made in Meeting options always wins.
        let calendar = CalendarMeetingStore.shared
        calendar.refresh(at: now)
        if MeetingContextStore.shared.calendarMeeting == nil,
           let suggestion = calendar.suggestion {
            MeetingContextStore.shared.selectCalendarMeeting(suggestion)
            MeetingContextStore.shared.autoLink(toMeetingNamed: suggestion.title)
        }

        // Auto-attach a same-day prep brief for this meeting (if one matches),
        // so Meeting-mode Assist works against "what we said we needed from this
        // call", not just the transcript. Read fresh each start; no-op when none.
        MeetingContextStore.shared.loadBriefForSession(meetingName: nil)

        // Meetings are when vault searches cluster — wake Neon now so the first
        // in-session search is warm, not a ~10-15s cold-start.
        VaultSearchCLI.warmUp()

        // Reset the live transcript for the fresh session.
        liveEntries = []
        interimLine = nil
        transcriptPipeline.reset()
        SpeakerNameStore.shared.reset()

        // Bind the analysis controllers to the fresh session. The periodic
        // scheduler and the Neon keep-warm start only once audio is running
        // (below): `stopSession` is what stops them, and it never runs for a
        // start that failed, so starting them here left both ticking until
        // the next session.
        NotesGenerationController.shared.reset(for: sessionId)
        DiscussionGuideController.shared.reset(for: sessionId)
        FindingsController.shared.reset(for: sessionId)
        AutoAssistController.shared.reset(for: sessionId)

        // Keep Bluetooth headphones in full-volume A2DP: if the default mic is a
        // BT headset, route capture to the built-in mic for the session. Must run
        // before the engine reads the default input device.
        BluetoothMicGuard.shared.engage()

        do {
            guard let recordingDirectory = SessionArchive.sessionDirectory(startedAt: now) else {
                throw AudioPipelineError.recordingArchiveUnavailable
            }
            _ = try audioPipeline.prepare(sessionId: sessionId, recordingDirectory: recordingDirectory)
            SessionArchive.seedTranscriptForAutomaticUpgrade(in: recordingDirectory, startedAt: now)
            SessionArchive.markAutomaticUpgradePending(in: recordingDirectory)
        } catch {
            lastError = "Couldn't create audio file: \(error)"
            audioPipeline.abort()
            BluetoothMicGuard.shared.release()
            return
        }

        do {
            try audioPipeline.start()
        } catch {
            lastError = "Audio start failed: \(error)"
            audioPipeline.abort()
            if let directory = SessionArchive.sessionDirectory(startedAt: now) {
                SessionArchive.clearAutomaticUpgradePending(in: directory)
            }
            BluetoothMicGuard.shared.release()
            return
        }

        // Each task self-gates on its Settings toggle.
        AnalysisScheduler.shared.start(
            intervalKey: AnalysisSettingsDefaults.notesIntervalKey,
            defaultInterval: AnalysisSettingsDefaults.defaultInterval
        )
        startKeepWarm()

        publishState()
        micMuted = false
        phase = .recording
        VisualContextTrail.shared.start(sessionStartedAt: now)
        startCheckpointLoop()
    }

    func stopSession() {
        guard isRunning, let sessionId = currentSessionId else { return }
        lastStopAt = Date()
        VisualContextTrail.shared.stopCapturing()

        // Settle any in-progress pause so the frozen duration excludes it.
        if phase == .paused, let pausedAt {
            pausedAccumulated += Date().timeIntervalSince(pausedAt)
        }
        pausedAt = nil
        audioPipeline.suspended = false

        // Stop audio capture before finalizing Soniox so no new audio enters
        // the pipeline while finalize() signals end-of-stream. The 1.5s delay
        // before the final teardown gives Soniox time to flush remaining
        // partial audio and deliver final transcripts.
        audioPipeline.finalize()
        AnalysisScheduler.shared.stop()
        keepWarmTimer?.invalidate()
        keepWarmTimer = nil
        checkpointTask?.cancel()
        checkpointTask = nil
        phase = .finishing
        transcriptionHealth = .idle
        systemAudioNotice = nil

        let endedAt = Date()
        self.endedAt = endedAt // freeze widget timer immediately
        NotificationCenter.default.post(name: .rtiSessionDidStop, object: nil)
        scheduleStopErrorRetirement()
        delayedCompleteTask?.cancel()
        delayedCompleteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            // Gather this recording's structured chats BEFORE archiving, so the
            // projection carries every thread and turn id. A recording that
            // held several chats keeps all of them.
            await self?.prepareChatThreadProjection(sessionId: sessionId)
            self?.completeStop(sessionId: sessionId, endedAt: endedAt)
        }
    }

    /// The recording's stored chats and turns, gathered once so the
    /// synchronous archive can project them. Nothing here ends or changes the
    /// recording; it only reads ids.
    private var chatThreadProjection: [ChatProjectionMarkdown.Thread] = []
    private var unreadableChatCount = 0

    private func prepareChatThreadProjection(sessionId: String) async {
        chatThreadProjection = []
        unreadableChatCount = 0
        do {
            guard let store = try ChatThreadStore.shared() else { return }
            let projection = await store.sessionChatProjection(linkedToSession: sessionId)
            chatThreadProjection = projection.threads
            unreadableChatCount = projection.unreadable
        } catch {
            // The store could not be opened. The archive still writes the
            // session; it just cannot name the structured chats, and says so by
            // counting it rather than pretending there were none.
            unreadableChatCount = 1
            RTILog.log("chat projection unavailable: \(error)", category: .llm)
        }
    }

    private func completeStop(sessionId: String, endedAt: Date) {
        guard currentSessionId == sessionId else { return }
        // Clear the handle: a completed-but-non-nil task otherwise convinces
        // emergencyShutdown a stop is still pending, triggering a phantom
        // re-archive on quit long after the session ended.
        delayedCompleteTask = nil

        audioPipeline.finish()
        // Restore the user's original default mic now that capture has stopped.
        BluetoothMicGuard.shared.release()
        self.endedAt = endedAt

        // Persist a Markdown record of the transcript (notes inline), chat, and
        // retained m4a legs. The audio is used only by Upgrade Transcript; this
        // does not revive the old corpus/import/search architecture.
        if let startedAt {
            let snapshot = finalizerSnapshot(startedAt: startedAt, endedAt: endedAt, sessionId: sessionId)
            let archiveResult = SessionFinalizer(snapshot: snapshot).archive()
            let archiveDir = archiveResult.archiveDir
            let transcript = snapshot.transcript
            let chat = snapshot.chat
            let analysis = snapshot.analysis
            let summaryContext = archiveResult.summaryContext
            // Render the transcript NOW and hand it to the summary call. The old
            // path re-read the live transcript inside the async summary, so
            // starting a new recording before it finished would summarise the
            // wrong (empty) session. Capturing it here makes "finish → start
            // again immediately" safe.
            let transcriptText = archiveResult.transcriptText

            if let archiveDir {
                // Preserve chat/analysis in the sidecar without writing a
                // provisional raw transcript. Only upgraded text becomes the
                // canonical transcript and reaches meeting processing.
                SessionArchive.writeCanonicalMeetingSidecar(
                    startedAt: startedAt,
                    chat: chat,
                    analysis: analysis,
                    archiveDir: archiveDir
                )
                phase = .summarizing
                SessionArchive.markAutomaticUpgradePending(in: archiveDir)
                postProcessingStatus = TranscriptUpgradeService.audioInputs(in: archiveDir).isEmpty
                    ? "Writing notes…"
                    : "Improving transcript…"
                // This session's speaker renames, read now: a new recording
                // may start while the upgrade runs, and it resets the store.
                let speakerNames = SpeakerNameStore.shared.names
                Task { @MainActor [weak self] in
                    var url: URL?
                    if !TranscriptUpgradeService.audioInputs(in: archiveDir).isEmpty {
                        do {
                            let result = try await TranscriptUpgradeService.upgrade(
                                sessionDirectory: archiveDir,
                                startedAt: startedAt,
                                provider: AsyncTranscriptProviders.soniox,
                                referenceContext: summaryContext
                            ) { progress in
                                Task { @MainActor in
                                    let coordinator = SessionCoordinator.shared
                                    guard coordinator.currentSessionId == sessionId else { return }
                                    coordinator.postProcessingStatus = progress.message
                                }
                            }
                            SessionArchive.clearAutomaticUpgradePending(in: archiveDir)
                            url = result.summaryURL
                        } catch {
                            RTILog.log("automatic Soniox transcript upgrade failed; retained audio is available for retry: \(error.localizedDescription)", category: .archive)
                            self?.postProcessingStatus = "Upgrade failed · audio retained"
                            url = nil
                        }
                    } else {
                        self?.postProcessingStatus = "Upgrade unavailable · audio retained"
                        url = nil
                    }
                    // Reliability net: whatever kept the upgrade from producing
                    // a summary (provider failure, empty upgrade result, no
                    // retained audio), still summarize + title the session from
                    // the live transcript so real content is never left as
                    // "Untitled session" with no summary.
                    if url == nil, !transcriptText.isEmpty,
                       !FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent("summary.md").path) {
                        url = await SessionArchive.writeAutoSummary(
                            transcriptText: transcriptText,
                            to: archiveDir,
                            startedAt: startedAt,
                            speakerNames: speakerNames,
                            referenceContext: summaryContext
                        )
                        if url != nil { self?.postProcessingStatus = nil }
                    }
                    guard let self else { return }
                    // Only resolve to `done` if this is still the session the
                    // user is looking at — a new recording may already be live.
                    if currentSessionId == sessionId, phase == .summarizing {
                        summaryURL = url
                        summaryFailed = (url == nil)
                        if postProcessingStatus != "Upgrade failed · audio retained" {
                            postProcessingStatus = url == nil ? "Session saved" : "Notes ready"
                        }
                        phase = .done
                        resetWorkspaceForDone()
                    }
                }
            } else {
                // Nothing worth summarising (or archive failed) — go straight to
                // done and still route whatever was captured.
                phase = .done
                resetWorkspaceForDone()
                if let archiveDir { SessionArchive.runVaultRouter(sessionDir: archiveDir) }
                exportCanonicalMeeting(
                    startedAt: startedAt,
                    transcript: transcript,
                    chat: chat,
                    analysis: analysis,
                    archiveDir: archiveDir
                )
            }
            MeetingContextStore.shared.resetAfterSession()
        } else {
            phase = .done
            resetWorkspaceForDone()
        }

        // Discard the live pipeline's temporary WAV. The compact mic/system
        // recordings have already moved into the session archive.
        if let path = activeWavPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        activeWavPath = nil
        // The live transcript stays in memory so chat turns can continue
        // referencing it after audio stops; it's reset on the next session.
        publishState()
    }

    /// When a session reaches `done`, reset the interactive Assist chat back to
    /// its "ready" state. The meeting's substance is already saved (summary +
    /// transcript on disk; transcript/notes/intel tabs stay reviewable until
    /// the next recording) — leaving the live chat hanging around just reads as
    /// stale. Fixes the "why is the old chat still there after Done?" confusion.
    private func resetWorkspaceForDone() {
        LLMController.shared.clear()
    }

    /// Synchronous teardown invoked from applicationWillTerminate.
    ///
    /// Quit must never destroy a session record: the quit dialog promises
    /// "finalize the session", so archive whatever we have before tearing the
    /// pipeline down. Covers both quit-while-recording and quit during the
    /// 1.5s post-stop flush window (where completeStop hasn't run yet).
    func emergencyShutdown() {
        // Restore the default mic even on an abrupt quit (no-op if not switched).
        BluetoothMicGuard.shared.release()
        VisualContextTrail.shared.stopCapturing()

        let stopPending = delayedCompleteTask != nil
        guard isRunning || stopPending else { return }
        delayedCompleteTask?.cancel()
        delayedCompleteTask = nil

        if isRunning {
            audioPipeline.abort()
        }
        // Retain the closed audio and checkpoint transcript, but leave routing
        // to the resumable automatic upgrade on the next launch.
        archiveCurrentSession(endedAt: endedAt ?? Date(), route: false)

        if let path = activeWavPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        phase = .idle
        transcriptionHealth = .idle
        systemAudioNotice = nil
    }

    /// Write the archive for the in-memory session state (shared by the
    /// normal completeStop path, emergencyShutdown, and the periodic
    /// crash-safety checkpoint). Returns the archive dir. Safe to call
    /// repeatedly — SessionArchive overwrites the same folder. `route` is
    /// false for mid-session checkpoints: routing a half-finished session
    /// would create a premature field-notes file the final route then skips.
    @discardableResult
    private func archiveCurrentSession(endedAt: Date, route: Bool = true) -> URL? {
        guard let startedAt else { return nil }
        let snapshot = finalizerSnapshot(
            startedAt: startedAt,
            endedAt: endedAt,
            sessionId: currentSessionId,
            includeAudio: route
        )
        let result = SessionFinalizer(snapshot: snapshot).archive()
        let dir = result.archiveDir
        if route, let dir { SessionArchive.runVaultRouter(sessionDir: dir) }
        if route {
            exportCanonicalMeeting(
                startedAt: startedAt,
                transcript: snapshot.transcript,
                chat: snapshot.chat,
                analysis: snapshot.analysis,
                archiveDir: dir
            )
        }
        return dir
    }

    private func finalizerSnapshot(
        startedAt: Date,
        endedAt: Date,
        sessionId: String?,
        includeAudio: Bool = true
    ) -> SessionFinalizer.Snapshot {
        let summaryContext = [
            MeetingContextStore.shared.summaryContext,
            VisualContextTrail.shared.summaryReferenceContext(),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        return SessionFinalizer.Snapshot(
            startedAt: startedAt,
            endedAt: endedAt,
            transcript: transcriptPipeline.liveEntries,
            chat: LLMController.shared.entries,
            analysis: SessionArchive.Analysis(
                notes: NotesGenerationController.shared.notes,
                guide: DiscussionGuideController.shared.guide,
                findings: FindingsController.shared.findings,
                visualContext: VisualContextTrail.shared.events
            ),
            sessionId: sessionId,
            micRecordingURL: includeAudio ? audioPipeline.micRecordingURL : nil,
            systemRecordingURL: includeAudio ? audioPipeline.systemRecordingURL : nil,
            systemAudioStartOffsetMs: systemAudioStartOffsetMs,
            workstreamItem: MeetingContextStore.shared.workstreamItem,
            modeName: ModeStore.shared.activeMode?.name,
            summaryContext: summaryContext.isEmpty ? nil : summaryContext,
            chatThreads: chatThreadProjection,
            unreadableChatCount: unreadableChatCount
        )
    }

    private func exportCanonicalMeeting(
        startedAt: Date,
        transcript: [LiveEntry],
        chat: [ChatEntry],
        analysis: SessionArchive.Analysis,
        archiveDir: URL?,
        process: Bool = true
    ) {
        guard let export = SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt,
            transcript: transcript,
            chat: chat,
            analysis: analysis,
            archiveDir: archiveDir
        ) else { return }
        if process { SessionArchive.runMeetingProcessor(transcriptURL: export.transcriptURL) }
    }

    /// Crash-safety checkpoint: while a session runs, re-write the archive
    /// every 5 minutes so a hard crash (the one teardown path that can't
    /// archive) loses at most the last few minutes of notes/transcript.
    private func startCheckpointLoop() {
        checkpointTask?.cancel()
        checkpointTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                guard let self, isRunning, !Task.isCancelled else { return }
                archiveCurrentSession(endedAt: Date(), route: false)
            }
        }
    }

    private func handleSystemWords(_ words: [SonioxWord]) {
        guard currentSessionId != nil else { return }
        let entriesChanged = transcriptPipeline.process(words: words, channel: "system")
        publishState(entriesChanged: entriesChanged)
    }

    private func handleWords(_ words: [SonioxWord]) {
        guard currentSessionId != nil else { return }
        let entriesChanged = transcriptPipeline.process(words: words, channel: "mic")
        publishState(entriesChanged: entriesChanged)
    }

    // Coalesced UI publishing. Soniox delivers frames many times a second; each
    // one updating the @Observable `interimLine`/`liveEntries` makes SwiftUI
    // re-run the transcript view's O(n) body. At ~40min that flooded the main
    // thread's update queue (`SwiftUICore.flushObservers → Update.ensure`) into
    // a 100%-CPU invalidation storm that froze the UI. So we mark state dirty on
    // each frame but flush to the observed properties at most ~8x/sec — well
    // under the run loop's capacity, smooth for live text, and bounded no matter
    // how long the session runs.
    private var publishFlushScheduled = false
    private var pendingEntriesChanged = false
    private static let publishIntervalNs: UInt64 = 120_000_000 // ~8 Hz

    private func publishState(entriesChanged: Bool = true) {
        pendingEntriesChanged = pendingEntriesChanged || entriesChanged
        guard !publishFlushScheduled else { return }
        publishFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.publishIntervalNs)
            guard let self else { return }
            publishFlushScheduled = false
            let changed = pendingEntriesChanged
            pendingEntriesChanged = false
            flushPublishState(entriesChanged: changed)
        }
    }

    /// Copy the latest pipeline state into the observed properties. `interimLine`
    /// is cheap; the big `liveEntries` array is republished only when finals
    /// actually appended (interim-only frames just refresh the partial line).
    private func flushPublishState(entriesChanged: Bool) {
        let newInterim = transcriptPipeline.interimLine
        if newInterim != interimLine { interimLine = newInterim }
        if entriesChanged {
            liveEntries = transcriptPipeline.liveEntries
            // New speech just landed → let Auto mode react proactively (it
            // debounces and rate-limits internally, so this is cheap to call).
            AutoAssistController.shared.noteActivity()
        }
    }

    /// Retire the failure notice this session left behind.
    ///
    /// An error that *stops* a session is the only place the reason is stated —
    /// `AudioPipeline`'s `onError` calls `stopSession` in the same breath — so
    /// it is kept long enough to read. It must not still be there the next
    /// morning: a mic outage at 21:52 was still painted above the composer at
    /// 08:12, reading "206s ago" as though it were happening then (2026-09-23).
    /// An auth or billing failure stays, because its message carries the fix.
    ///
    /// Internal rather than private so the test can drive it: `stopSession`
    /// needs a running session, which a unit test cannot stand up. The wiring
    /// from `stopSession` to here is one call and is not covered by a test.
    func scheduleStopErrorRetirement() {
        stopErrorRetireTask?.cancel()
        guard lastError != nil, !lastErrorIsAuth else { return }
        stopErrorRetireTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.stopErrorRetirementNs)
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    // MARK: - Keep-warm

    /// During a session, vault searches (Assist tool calls + Auto mode) cluster.
    /// Neon's serverless compute suspends after a few minutes idle, which would
    /// make the next search eat a ~15s cold start (past VaultSearchCLI's 12s
    /// timeout → silent grep fallback). A light periodic ping keeps it warm so
    /// every in-session search stays on the ~2.4s semantic path.
    private var keepWarmTimer: Timer?
    private static let keepWarmInterval: TimeInterval = 240

    private func startKeepWarm() {
        keepWarmTimer?.invalidate()
        keepWarmTimer = Timer.scheduledTimer(withTimeInterval: Self.keepWarmInterval, repeats: true) { _ in
            VaultSearchCLI.warmUp()
        }
        keepWarmTimer?.tolerance = 30
    }
}
