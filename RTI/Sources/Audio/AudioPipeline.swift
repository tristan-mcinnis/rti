import AppKit
import AVFoundation
import Foundation
import RTICore

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

    /// Pause/resume without tearing anything down. While suspended, real audio
    /// is replaced with silence on BOTH legs so the Soniox sockets stay warm
    /// (resume is instant, no re-handshake) but nothing is transcribed, and
    /// paused audio is not written to the WAV. Distinct from `micMuted`, which
    /// is Zoom-style and only affects the mic leg.
    var suspended = false

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
    /// The active speech-to-text client (Soniox / AssemblyAI / future), built by
    /// STTProviders from the user's Settings choice. `soniox` is a historical
    /// name; it is whichever provider is active.
    private var soniox: STTClient?
    private var systemSoniox: STTClient?

    /// RTI intentionally discards meeting audio. These compatibility accessors
    /// keep the text-archive call sites explicit about that invariant while
    /// older archives remain readable.
    var micRecordingURL: URL? { nil }
    var systemRecordingURL: URL? { nil }

    /// Live capture levels for the Audio I/O monitor. Written from the PCM
    /// callbacks; read on main by the monitor. `systemAudioActive` reflects
    /// whether the system-audio leg is currently wired up.
    let levelMeter = AudioLevelMeter()
    var systemAudioActive: Bool {
        systemAudio != nil
    }

    /// Watches for the mic tap going silent mid-session (device disconnect,
    /// mute, revoked permission) — the "silent dead air" case the user can't
    /// otherwise detect. See `checkMicHealth`.
    private var micWatchdog: Task<Void, Never>?
    private var micOutageReported = false
    /// Seconds without a mic buffer before we call it dead. Generous so a brief
    /// hiccup or device reroute doesn't false-alarm.
    private let micOutageThreshold: TimeInterval = 8
    /// Watches the system-audio backend itself, not just the Soniox socket.
    /// CoreAudio taps can keep "running" while a browser/helper PID changes
    /// underneath them; the watchdog asks the backend to reattach when buffers
    /// stop or stay below the audible floor.
    private var systemAudioWatchdog: Task<Void, Never>?
    private var systemAudioStartedAt: Date?
    private var lastSystemAudioRecoveryAt: Date?
    private var systemAudioOutageReported = false
    private var systemAudioRecoveryAttempts = 0
    private let systemAudioNoBufferThreshold: TimeInterval = 8
    private let systemAudioSilentThreshold: TimeInterval = 12
    private let systemAudioNoticeThreshold: TimeInterval = 30
    private let systemAudioRecoveryCooldown: TimeInterval = 10
    private let systemAudioMaxRecoveryAttempts = 2
    private let systemAudioMinimumAudibleDuration: TimeInterval = 0.25
    /// Starting the CoreAudio/SCK system leg immediately can race with Zoom's
    /// own device/app-audio setup if RTI starts before the user has joined the
    /// call. Let the mic leg settle first; missing the first few seconds of
    /// other-party audio is better than destabilizing the meeting app.
    private let systemAudioStartupDelayNs: UInt64 = 8_000_000_000

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
        guard STTProviders.activeHasKey else {
            throw AudioPipelineError.missingSTTKey
        }

        let wavURL = WAVWriter.defaultURL(for: sessionId)
        try wav.open(at: wavURL)

        let client = STTProviders.makeActiveClient(
            translationConfig: translationConfig,
            contextTerms: contextTerms
        )
        client.onWords = { [weak self] words in self?.onWords?(words) }
        client.onError = { [weak self] failure, didOpen in
            self?.onError?(failure.userMessage(didOpen: didOpen), failure.isAuth)
        }
        client.onStatus = { [weak self] health in self?.onTranscriptionHealth?(health) }
        client.connect()
        soniox = client

        audio.onPCMBuffer = { [weak self] buffer in
            guard let self else { return }
            levelMeter.recordMic(buffer)
            guard let int16 = buffer.int16ChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let byteCount = frameLength * MemoryLayout<Int16>.size
            if suspended {
                // Paused: don't keep the audio (no WAV append) and don't
                // transcribe it — just feed silence so Soniox doesn't idle-out.
                soniox?.sendAudio(Data(count: byteCount))
                return
            }
            wav.append(buffer)
            let data = Data(bytes: int16[0], count: byteCount)
            soniox?.sendAudio(data)
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
        guard STTProviders.activeHasKey else { return }

        Task { @MainActor [weak self] in
            guard let self, isCapturing else { return }
            try? await Task.sleep(nanoseconds: systemAudioStartupDelayNs)
            guard isCapturing else { return }
            let sysClient = STTProviders.makeActiveClient(
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
                    onError?("System audio: \(message)", false)
                }
            }
            sysClient.onStatus = { [weak self] health in self?.onSystemAudioHealth?(health) }
            sysClient.connect()
            systemSoniox = sysClient

            let onPCM: (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
                guard let self else { return }
                levelMeter.recordSystem(buffer)
                guard let int16 = buffer.int16ChannelData else { return }
                let frameLength = Int(buffer.frameLength)
                let byteCount = frameLength * MemoryLayout<Int16>.size
                if suspended {
                    systemSoniox?.sendAudio(Data(count: byteCount))
                    return
                }
                let data = Data(bytes: int16[0], count: byteCount)
                systemSoniox?.sendAudio(data)
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
                    guard isCapturing else { tap.stop(); return }
                    systemAudio = tap
                    markSystemAudioStarted()
                    return
                } catch {
                    RTILog.log("CoreAudio tap unavailable, falling back to ScreenCaptureKit — \(error)", category: "audio")
                }
            }

            guard isCapturing else { return }
            let sck = SystemAudioCapture()
            sck.onPCMBuffer = onPCM
            sck.onError = onErr
            do {
                try await sck.start()
                guard isCapturing else { sck.stop(); return }
                systemAudio = sck
                markSystemAudioStarted()
            } catch {
                RTILog.log("system audio start failed — \(error)", category: "audio")
            }
        }
    }

    private func markSystemAudioStarted() {
        systemAudioStartedAt = Date()
        systemAudioOutageReported = false
        lastSystemAudioRecoveryAt = nil
        systemAudioRecoveryAttempts = 0
        reportSystemAudioStart()
        startSystemAudioWatchdog()
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
                guard let self, isCapturing else { continue }
                checkMicHealth()
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

    // MARK: - System audio health watchdog

    private func startSystemAudioWatchdog() {
        systemAudioWatchdog?.cancel()
        systemAudioWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, isCapturing, !suspended else { continue }
                await checkSystemAudioHealth()
            }
        }
    }

    private func stopSystemAudioWatchdog() {
        systemAudioWatchdog?.cancel()
        systemAudioWatchdog = nil
        systemAudioStartedAt = nil
        lastSystemAudioRecoveryAt = nil
        systemAudioOutageReported = false
        systemAudioRecoveryAttempts = 0
    }

    private func checkSystemAudioHealth() async {
        guard let backend = systemAudio, let startedAt = systemAudioStartedAt else { return }
        let health = backend.captureHealth()
        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= systemAudioNoBufferThreshold else { return }

        let secondsSinceBuffer = health.lastBufferAt.map { now.timeIntervalSince($0) } ?? elapsed
        let secondsSinceAudible = health.lastAudibleBufferAt.map { now.timeIntervalSince($0) } ?? elapsed
        let hasAudibleAudio = health.audibleDuration >= systemAudioMinimumAudibleDuration

        if secondsSinceBuffer > systemAudioNoBufferThreshold {
            await attemptSystemAudioRecovery(
                reason: "stopped delivering buffers",
                elapsed: elapsed,
                health: health,
                notifyIfPersistent: true
            )
            return
        }

        guard elapsed >= systemAudioSilentThreshold else { return }
        if !hasAudibleAudio {
            await attemptSystemAudioRecovery(
                reason: "has not produced audible samples",
                elapsed: elapsed,
                health: health,
                notifyIfPersistent: true
            )
            return
        }

        if secondsSinceAudible > systemAudioSilentThreshold {
            await attemptSystemAudioRecovery(
                reason: "has been silent for \(Int(secondsSinceAudible))s",
                elapsed: elapsed,
                health: health,
                notifyIfPersistent: false
            )
            return
        }

        if systemAudioOutageReported {
            systemAudioOutageReported = false
            onSystemAudioHealth?(.live)
        }
        systemAudioRecoveryAttempts = 0
        lastSystemAudioRecoveryAt = nil
    }

    private func attemptSystemAudioRecovery(
        reason: String,
        elapsed: TimeInterval,
        health: SystemAudioCaptureHealth,
        notifyIfPersistent: Bool
    ) async {
        let now = Date()
        if let lastSystemAudioRecoveryAt,
           now.timeIntervalSince(lastSystemAudioRecoveryAt) < systemAudioRecoveryCooldown {
            reportPersistentSystemAudioOutageIfNeeded(reason: reason, elapsed: elapsed, health: health, shouldNotify: notifyIfPersistent)
            return
        }

        if systemAudioRecoveryAttempts < systemAudioMaxRecoveryAttempts {
            lastSystemAudioRecoveryAt = now

            if await (systemAudio?.recoverFromSilentAudio() ?? false) {
                systemAudioRecoveryAttempts += 1
                RTILog.log(
                    "system audio backend recovered after \(reason) (\(systemAudioRecoveryAttempts)/\(systemAudioMaxRecoveryAttempts), captured=\(String(format: "%.1f", health.duration))s audible=\(String(format: "%.1f", health.audibleDuration))s peakRMS=\(String(format: "%.4f", health.peakRMSLevel)))",
                    category: "audio"
                )
                systemAudioOutageReported = false
                onSystemAudioHealth?(.live)
                return
            }
        }

        reportPersistentSystemAudioOutageIfNeeded(reason: reason, elapsed: elapsed, health: health, shouldNotify: notifyIfPersistent)
    }

    private func reportPersistentSystemAudioOutageIfNeeded(
        reason: String,
        elapsed: TimeInterval,
        health: SystemAudioCaptureHealth,
        shouldNotify: Bool
    ) {
        guard shouldNotify, elapsed >= systemAudioNoticeThreshold, !systemAudioOutageReported else { return }
        systemAudioOutageReported = true
        RTILog.log(
            "system audio \(reason) for \(Int(elapsed))s (captured=\(String(format: "%.1f", health.duration))s audible=\(String(format: "%.1f", health.audibleDuration))s peakRMS=\(String(format: "%.4f", health.peakRMSLevel)))",
            category: "audio"
        )
        onSystemAudioHealth?(.failed)
    }

    /// Stop capture and signal end-of-audio to Soniox. Call `finish()`
    /// after the 1.5 s finalize window to disconnect and close the WAV.
    func finalize() {
        isCapturing = false
        stopMicWatchdog()
        stopSystemAudioWatchdog()
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

    /// Swap the live transcription clients to apply a new provider and/or
    /// translation config mid-session, without interrupting audio capture or
    /// losing the WAV file. Old clients are disconnected; new ones are created
    /// with the current `translationConfig` and immediately receive incoming
    /// PCM buffers via the existing `onPCMBuffer` closures.
    func reconfigureStreamingClients() {
        guard STTProviders.activeHasKey else { return }

        // Mic leg.
        soniox?.disconnect()
        let mic = STTProviders.makeActiveClient(
            translationConfig: translationConfig,
            contextTerms: contextTerms
        )
        mic.onWords = { [weak self] words in self?.onWords?(words) }
        mic.onError = { [weak self] failure, didOpen in
            self?.onError?(failure.userMessage(didOpen: didOpen), failure.isAuth)
        }
        mic.onStatus = { [weak self] health in self?.onTranscriptionHealth?(health) }
        mic.connect()
        soniox = mic

        // System leg (if active).
        if systemSoniox != nil {
            systemSoniox?.disconnect()
            let sys = STTProviders.makeActiveClient(
                translationConfig: translationConfig,
                contextTerms: contextTerms
            )
            sys.onWords = { [weak self] words in self?.onSystemWords?(words) }
            sys.onError = { [weak self] failure, didOpen in
                guard let self else { return }
                if failure.isAuth {
                    onError?("System audio: \(failure.userMessage(didOpen: didOpen))", false)
                }
            }
            sys.onStatus = { [weak self] health in self?.onSystemAudioHealth?(health) }
            sys.connect()
            systemSoniox = sys
        }
    }

    /// Immediate teardown for failures and app termination.
    func abort() {
        isCapturing = false
        stopMicWatchdog()
        stopSystemAudioWatchdog()
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
    case missingSTTKey

    var errorDescription: String? {
        switch self {
        case .missingSTTKey:
            "No speech-to-text API key set for the selected provider. Open Settings to paste a key, then start the session again."
        }
    }
}
