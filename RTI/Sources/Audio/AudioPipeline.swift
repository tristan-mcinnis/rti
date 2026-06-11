import AppKit
import RTICore
import AVFoundation
import Foundation

/// Owns the full audio capture → WAV + Soniox pipeline for both mic and
/// system audio. Hides the dual-channel complexity behind a small interface:
/// prepare, start, finalize, finish, abort.
@MainActor
final class AudioPipeline {

    var onWords: (([SonioxWord]) -> Void)?
    var onSystemWords: (([SonioxWord]) -> Void)?
    /// Fires once when the system-audio leg actually starts, with how many
    /// milliseconds later it started than the mic leg. Used to align the two
    /// channels' transcript timestamps onto a common timeline.
    var onSystemAudioStarted: ((Int) -> Void)?
    /// Fires on terminal mic-audio failures. `isAuth` gates the "Open Settings"
    /// affordance in the UI.
    var onError: ((String, Bool) -> Void)?
    /// Mic-leg transcription connection health (drives the UI "● live" dot).
    var onTranscriptionHealth: ((TranscriptionHealth) -> Void)?
    /// System-audio-leg health — used to surface a non-fatal "other party
    /// audio lost" notice without stopping the (mic-driven) session.
    var onSystemAudioHealth: ((TranscriptionHealth) -> Void)?

    /// Mute the user's mic leg (system-audio capture is unaffected). True
    /// mute — buffers are dropped inside the capture manager before they
    /// reach Soniox.
    var micMuted: Bool {
        get { audio.micMuted }
        set { audio.micMuted = newValue }
    }

    private let audio = AudioCaptureManager()
    /// Picked at `start()`: a CoreAudio process tap when available (macOS
    /// 14.2+ and permission granted), else the ScreenCaptureKit fallback.
    private var systemAudio: SystemAudioCapturing?
    /// True between `start()` and `finalize()`/`abort()`. System-audio capture
    /// starts on an async Task; this flag lets that Task notice if the session
    /// was already torn down while it was awaiting startup, so it can release
    /// the backend instead of leaking a running tap.
    private var isCapturing = false
    /// Wall-clock instant the mic leg started sending audio (≈ the mic Soniox
    /// stream's `startMs == 0`). Used to measure how much later the system
    /// leg starts so its timestamps can be aligned to the mic timeline.
    private var captureStartWall: Date?
    private let wav = WAVWriter()
    private var soniox: SonioxClient?
    private var systemSoniox: SonioxClient?

    /// Live capture levels for the Audio I/O monitor. Written from the PCM
    /// callbacks; read on main by the monitor. `systemAudioActive` reflects
    /// whether the system-audio leg is currently wired up.
    let levelMeter = AudioLevelMeter()
    var systemAudioActive: Bool { systemAudio != nil }

    /// Watches for the mic tap going silent mid-session (device disconnect,
    /// mute, revoked permission) — the "silent dead air" case the user can't
    /// otherwise detect. See `checkMicHealth`.
    private var micWatchdog: Task<Void, Never>?
    private var micOutageReported = false
    /// Seconds without a mic buffer before we call it dead. Generous so a brief
    /// hiccup or device reroute doesn't false-alarm.
    private let micOutageThreshold: TimeInterval = 8

    func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        AudioCaptureManager().requestPermission(completion)
    }

    /// Create the WAV file and the mic Soniox client. Does **not** start
    /// capture yet — call `start()` after this returns.
    /// - Returns: the URL of the WAV file being prepared.
    var translationConfig: TranslationConfig?

    /// Proper nouns from past meetings, sent to Soniox as `context.terms`
    /// to bias recognition of names/brands/orgs. Set before `prepare`.
    var contextTerms: [String] = []

    func prepare(sessionId: String) throws -> URL {
        // Fast-fail before opening a WAV on disk: a missing/empty Soniox
        // key would otherwise let the user "record" silently for 5 retries
        // before any error surfaces, leaving an orphan WAV behind.
        guard !Secrets.sonioxAPIKey.isEmpty else {
            throw AudioPipelineError.missingSonioxKey
        }

        let wavURL = WAVWriter.defaultURL(for: sessionId)
        try wav.open(at: wavURL)

        let client = SonioxClient(
            apiKey: Secrets.sonioxAPIKey,
            url: SonioxClient.defaultURL,
            translationConfig: translationConfig,
            contextTerms: contextTerms
        )
        client.onWords = { [weak self] words in self?.onWords?(words) }
        client.onError = { [weak self] failure, didOpen in
            self?.onError?(failure.userMessage(didOpen: didOpen), failure.isAuth)
        }
        client.onStatus = { [weak self] health in self?.onTranscriptionHealth?(health) }
        client.connect()
        self.soniox = client

        audio.onPCMBuffer = { [weak self] buffer in
            self?.levelMeter.recordMic(buffer)
            self?.wav.append(buffer)
            guard let int16 = buffer.int16ChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let byteCount = frameLength * MemoryLayout<Int16>.size
            let data = Data(bytes: int16[0], count: byteCount)
            self?.soniox?.sendAudio(data)
        }

        return wavURL
    }

    /// Start mic capture immediately; system audio starts asynchronously
    /// (non-fatal if it fails).
    func start() throws {
        captureStartWall = Date()
        try audio.start()
        isCapturing = true
        startMicWatchdog()

        // Don't even attempt the system-audio Soniox leg without a key.
        // The mic leg already enforces this in `prepare`; this guard
        // mirrors it so we don't silently consume Soniox credits on a
        // doomed second connection.
        guard !Secrets.sonioxAPIKey.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self, self.isCapturing else { return }
            let sysClient = SonioxClient(
                apiKey: Secrets.sonioxAPIKey,
                url: SonioxClient.defaultURL,
                translationConfig: translationConfig,
                contextTerms: contextTerms
            )
            sysClient.onWords = { [weak self] words in self?.onSystemWords?(words) }
            sysClient.onError = { [weak self] failure, didOpen in
                guard let self else { return }
                let message = failure.userMessage(didOpen: didOpen)
                RTILog.log("system audio Soniox error — \(message)", category: "soniox")
                // System-audio failure is non-fatal for the session (mic
                // continues). Surface it once via the same `onError`
                // callback the mic leg uses, with `isAuth=false` so the
                // UI banner is informational rather than recommending
                // Settings (the mic side already would have for an auth
                // error).
                if failure.isAuth {
                    self.onError?("System audio: \(message)", false)
                }
            }
            sysClient.onStatus = { [weak self] health in self?.onSystemAudioHealth?(health) }
            sysClient.connect()
            self.systemSoniox = sysClient

            let onPCM: (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
                self?.levelMeter.recordSystem(buffer)
                guard let int16 = buffer.int16ChannelData else { return }
                let frameLength = Int(buffer.frameLength)
                let byteCount = frameLength * MemoryLayout<Int16>.size
                let data = Data(bytes: int16[0], count: byteCount)
                self?.systemSoniox?.sendAudio(data)
            }
            let onErr: (String) -> Void = { msg in
                RTILog.log("system audio capture error — \(msg)", category: "audio")
            }

            // Prefer the CoreAudio process tap (no Screen Recording
            // permission, doesn't disturb screenshot OCR, follows the output
            // device). Fall back to ScreenCaptureKit if the tap is
            // unavailable (older macOS) or its permission is denied.
            if #available(macOS 14.2, *) {
                let tap = CoreAudioTapCapture()
                tap.onPCMBuffer = onPCM
                tap.onError = onErr
                do {
                    try await tap.start()
                    // The session may have been stopped while we awaited
                    // startup; if so, release the tap instead of leaking it.
                    guard self.isCapturing else { tap.stop(); return }
                    self.systemAudio = tap
                    self.reportSystemAudioStart()
                    return
                } catch {
                    RTILog.log("CoreAudio tap unavailable, falling back to ScreenCaptureKit — \(error)", category: "audio")
                }
            }

            guard self.isCapturing else { return }
            let sck = SystemAudioCapture()
            sck.onPCMBuffer = onPCM
            sck.onError = onErr
            do {
                try await sck.start()
                guard self.isCapturing else { sck.stop(); return }
                self.systemAudio = sck
                self.reportSystemAudioStart()
            } catch {
                RTILog.log("system audio start failed — \(error)", category: "audio")
            }
        }
    }

    /// Report how much later the system-audio leg started than the mic leg,
    /// so the transcript can align the two channels' timestamps.
    private func reportSystemAudioStart() {
        let offsetMs = Int(max(0, Date().timeIntervalSince(captureStartWall ?? Date()) * 1000))
        onSystemAudioStarted?(offsetMs)
    }

    // MARK: - Mic health watchdog

    private func startMicWatchdog() {
        micOutageReported = false
        micWatchdog?.cancel()
        micWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.isCapturing else { continue }
                self.checkMicHealth()
            }
        }
    }

    private func stopMicWatchdog() {
        micWatchdog?.cancel()
        micWatchdog = nil
    }

    /// If the mic tap has stopped delivering buffers for longer than the
    /// threshold, the input is effectively dead — surface it (which stops the
    /// session) so the user isn't unknowingly recording silence. Fires at most
    /// once per outage. Ignores the startup window (nil = no buffer yet).
    private func checkMicHealth() {
        guard let since = audio.secondsSinceLastBuffer() else { return }
        if since > micOutageThreshold {
            guard !micOutageReported else { return }
            micOutageReported = true
            onError?(
                "Microphone audio stopped (\(Int(since))s ago) — the input device may have disconnected or RTI lost mic access. Restart the session, or check Settings → Privacy → Microphone.",
                false
            )
        } else {
            micOutageReported = false
        }
    }

    /// Stop capture and signal end-of-audio to Soniox. Call `finish()`
    /// after the 1.5 s finalize window to disconnect and close the WAV.
    func finalize() {
        isCapturing = false
        stopMicWatchdog()
        levelMeter.reset()
        audio.stop()
        systemAudio?.stop()
        systemAudio = nil
        soniox?.finalize()
        systemSoniox?.finalize()
    }

    /// Disconnect Soniox and close the WAV file. Call after `finalize()`.
    func finish() {
        soniox?.disconnect()
        soniox = nil
        systemSoniox?.disconnect()
        systemSoniox = nil
        wav.close()
    }

    /// Swap the Soniox transcription clients to apply a new translation
    /// config mid-session, without interrupting audio capture or losing the
    /// WAV file. Old clients are disconnected; new ones are created with
    /// the current `translationConfig` and immediately receive incoming
    /// PCM buffers via the existing `onPCMBuffer` closures.
    func reconfigureTranslation() {
        guard !Secrets.sonioxAPIKey.isEmpty else { return }

        // Mic leg.
        soniox?.disconnect()
        let mic = SonioxClient(
            apiKey: Secrets.sonioxAPIKey,
            url: SonioxClient.defaultURL,
            translationConfig: translationConfig,
            contextTerms: contextTerms
        )
        mic.onWords = { [weak self] words in self?.onWords?(words) }
        mic.onError = { [weak self] failure, didOpen in
            self?.onError?(failure.userMessage(didOpen: didOpen), failure.isAuth)
        }
        mic.onStatus = { [weak self] health in self?.onTranscriptionHealth?(health) }
        mic.connect()
        self.soniox = mic

        // System leg (if active).
        if systemSoniox != nil {
            systemSoniox?.disconnect()
            let sys = SonioxClient(
                apiKey: Secrets.sonioxAPIKey,
                url: SonioxClient.defaultURL,
                translationConfig: translationConfig,
                contextTerms: contextTerms
            )
            sys.onWords = { [weak self] words in self?.onSystemWords?(words) }
            sys.onError = { [weak self] failure, didOpen in
                guard let self else { return }
                if failure.isAuth {
                    self.onError?("System audio: \(failure.userMessage(didOpen: didOpen))", false)
                }
            }
            sys.onStatus = { [weak self] health in self?.onSystemAudioHealth?(health) }
            sys.connect()
            self.systemSoniox = sys
        }
    }

    /// Immediate teardown for failures and app termination.
    func abort() {
        isCapturing = false
        stopMicWatchdog()
        levelMeter.reset()
        audio.stop()
        systemAudio?.stop()
        systemAudio = nil
        soniox?.disconnect()
        soniox = nil
        systemSoniox?.disconnect()
        systemSoniox = nil
        wav.close()
    }
}

enum AudioPipelineError: LocalizedError {
    case missingSonioxKey

    var errorDescription: String? {
        switch self {
        case .missingSonioxKey:
            return "No Soniox API key set. Open Settings to paste a key, then start the session again."
        }
    }
}
