import AppKit
import AVFoundation
import Foundation
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
    private(set) var interimLine: String?
    private(set) var lastError: String?
    /// True when `lastError` came from a Soniox auth/billing failure
    /// (`SonioxFailure.isAuth`). UI uses this to gate the "Open Settings"
    /// affordance on the error banner.
    private(set) var lastErrorIsAuth: Bool = false
    /// When non-nil, Soniox will stream translation tokens alongside
    /// the regular transcript. Bound to UserDefaults and the live
    /// transcript toggle.
    var translationConfig: TranslationConfig? {
        didSet {
            audioPipeline.translationConfig = translationConfig
            if isRunning {
                audioPipeline.reconfigureTranslation()
            }
        }
    }

    private let audioPipeline = AudioPipeline()
    private let transcriptPipeline = TranscriptPipeline()
    private var delayedCompleteTask: Task<Void, Never>?
    /// WAV path for the active recording, deleted when the session ends.
    private var activeWavPath: String?

    private init() {
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

    /// Insert a user-authored note into the live transcript at the current
    /// offset so it renders distinctly and feeds the LLM context.
    @discardableResult
    func insertNote(_ text: String) -> Bool {
        guard let startedAt else { return false }
        let ok = transcriptPipeline.insertNote(text, startedAt: startedAt)
        if ok { publishState() }
        return ok
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

        do {
            _ = try audioPipeline.prepare(sessionId: sessionId)
        } catch {
            lastError = "Couldn't create audio file: \(error)"
            audioPipeline.abort()
            return
        }

        do {
            try audioPipeline.start()
        } catch {
            lastError = "Audio start failed: \(error)"
            audioPipeline.abort()
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
        self.endedAt = endedAt

        // Persist a Markdown record of the transcript (notes inline) and chat
        // before the WAV is dropped. This is the one intentional break from the
        // ephemeral rule — audio is still discarded, only the text is kept.
        if let startedAt {
            SessionArchive.write(
                startedAt: startedAt,
                endedAt: endedAt,
                transcript: transcriptPipeline.liveEntries,
                chat: LLMController.shared.entries
            )
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
        guard isRunning else { return }
        audioPipeline.abort()
        if let path = activeWavPath {
            try? FileManager.default.removeItem(atPath: path)
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
