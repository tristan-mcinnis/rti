import AppKit
import RTICore
import AVFoundation
import Foundation
import Observation

/// Owns the live recording lifecycle. Ephemeral build: a session is purely a
/// run of live audio → transcript held in memory for the duration. Nothing is
/// persisted — no corpus, no database, no history. When the session ends the
/// transcript stays in memory until the next session resets it, and the WAV
/// recording is deleted.
@Observable @MainActor
final class SessionCoordinator {
    static let shared = SessionCoordinator()

    private(set) var isRunning = false
    private(set) var currentSessionId: String?
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var liveEntries: [LiveEntry] = []
    /// When the session was started to overlay a meeting that the external
    /// Meeting Sentinel tool is recording, the linked meeting. Lets Step 3
    /// tie RTI's notes/chat back to Sentinel's recording + vault record.
    private(set) var linkedMeeting: SentinelMeeting?
    private(set) var interimLine: String?
    private(set) var lastError: String?
    /// True when `lastError` came from a Soniox auth/billing failure
    /// (`SonioxFailure.isAuth`). UI uses this to gate the "Open Settings"
    /// affordance on the error banner.
    private(set) var lastErrorIsAuth: Bool = false
    /// Whether live transcription is actually flowing (mic leg). Surfaced in
    /// the UI so the user always knows if their words are being captured.
    private(set) var transcriptionHealth: TranscriptionHealth = .idle
    /// Non-fatal notice when the system-audio (other-party) leg drops while
    /// the mic leg keeps recording. nil when system audio is fine/absent.
    private(set) var systemAudioNotice: String?
    /// When non-nil, Soniox will stream translation tokens alongside
    /// the regular transcript. Bound to UserDefaults and the live
    /// transcript toggle.
    var translationConfig: TranslationConfig? {
        didSet {
            audioPipeline.translationConfig = translationConfig
            if isRunning {
                // Keep the transcript across the Soniox reconnect and continue
                // the timeline, so toggling translation never wipes preceding
                // entries or drops the next ones.
                transcriptPipeline.prepareForReconnect()
                audioPipeline.reconfigureTranslation()
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
    /// WAV path for the active recording, deleted when the session ends.
    private var activeWavPath: String?

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
    }

    private func commonInit() {
        audioPipeline.onWords = { [weak self] words in
            self?.handleWords(words)
        }
        audioPipeline.onSystemWords = { [weak self] words in
            self?.handleSystemWords(words)
        }
        audioPipeline.onSystemAudioStarted = { [weak self] offsetMs in
            self?.transcriptPipeline.setSystemStartOffset(ms: offsetMs)
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

    /// Insert a user-authored note into the live transcript at the current
    /// offset so it renders distinctly and feeds the LLM context.
    @discardableResult
    func insertNote(_ text: String) -> Bool {
        guard let startedAt else { return false }
        let ok = transcriptPipeline.insertNote(text, startedAt: startedAt)
        if ok { publishState() }
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

    func toggleSession() {
        if isRunning {
            stopSession()
        } else {
            startSession()
        }
    }

    func startSession(linkedTo meeting: SentinelMeeting? = nil) {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        linkedMeeting = meeting
        if let meeting { MeetingContextStore.shared.autoLink(toMeetingNamed: meeting.name) }
        lastError = nil
        lastErrorIsAuth = false
        delayedCompleteTask?.cancel()
        LLMController.shared.resetMemory()

        audioPipeline.requestPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.isStarting = false
                    self.lastError = "Microphone permission denied."
                    self.promptForMicrophoneAccess()
                    return
                }
                self.launchSession()
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
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
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

        // Reset the live transcript for the fresh session.
        liveEntries = []
        interimLine = nil
        transcriptPipeline.reset()

        // Bind the analysis controllers to the fresh session and start the
        // periodic scheduler. Each task self-gates on its Settings toggle.
        NotesGenerationController.shared.reset(for: sessionId)
        DiscussionGuideController.shared.reset(for: sessionId)
        AnalysisScheduler.shared.start(
            intervalKey: AnalysisSettingsDefaults.notesIntervalKey,
            defaultInterval: AnalysisSettingsDefaults.defaultInterval
        )

        // Keep Bluetooth headphones in full-volume A2DP: if the default mic is a
        // BT headset, route capture to the built-in mic for the session. Must run
        // before the engine reads the default input device.
        BluetoothMicGuard.shared.engage()

        do {
            _ = try audioPipeline.prepare(sessionId: sessionId)
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
            BluetoothMicGuard.shared.release()
            return
        }

        publishState()
        isRunning = true
    }

    func stopSession() {
        guard isRunning, let sessionId = currentSessionId else { return }

        // Stop audio capture before finalizing Soniox so no new audio enters
        // the pipeline while finalize() signals end-of-stream. The 1.5s delay
        // before the final teardown gives Soniox time to flush remaining
        // partial audio and deliver final transcripts.
        audioPipeline.finalize()
        AnalysisScheduler.shared.stop()
        isRunning = false
        transcriptionHealth = .idle
        systemAudioNotice = nil

        let endedAt = Date()
        self.endedAt = endedAt   // freeze widget timer immediately
        NotificationCenter.default.post(name: .rtiSessionDidStop, object: nil)
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
        // Restore the user's original default mic now that capture has stopped.
        BluetoothMicGuard.shared.release()
        self.endedAt = endedAt

        // Persist a Markdown record of the transcript (notes inline) and chat
        // before the WAV is dropped. This is the one intentional break from the
        // ephemeral rule — audio is still discarded, only the text is kept.
        if let startedAt {
            let transcript = transcriptPipeline.liveEntries
            let chat = LLMController.shared.entries
            let analysis = SessionArchive.Analysis(
                notes: NotesGenerationController.shared.notes,
                guide: DiscussionGuideController.shared.guide
            )
            SessionArchive.write(
                startedAt: startedAt,
                endedAt: endedAt,
                transcript: transcript,
                chat: chat,
                analysis: analysis
            )
            // If this session was overlaid on a Sentinel-recorded meeting, also
            // drop the notes + chat + generated analysis into that meeting's
            // vault record so the downstream workflow can fold them in.
            if let linkedMeeting {
                SessionArchive.writeLinkedMeetingNotes(
                    meeting: linkedMeeting,
                    transcript: transcript,
                    chat: chat,
                    analysis: analysis
                )
            }
        }

        // Ephemeral: discard the WAV recording — nothing is kept on disk.
        if let path = activeWavPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        activeWavPath = nil
        // The live transcript stays in memory so chat turns can continue
        // referencing it after audio stops; it's reset on the next session.
        publishState()
    }

    /// Synchronous teardown invoked from applicationWillTerminate.
    func emergencyShutdown() {
        // Restore the default mic even on an abrupt quit (no-op if not switched).
        BluetoothMicGuard.shared.release()
        guard isRunning else { return }
        audioPipeline.abort()
        if let path = activeWavPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        isRunning = false
        transcriptionHealth = .idle
        systemAudioNotice = nil
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
