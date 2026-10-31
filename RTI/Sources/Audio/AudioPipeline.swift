import AppKit
import AVFoundation
import Foundation
import RTICore

/// Recorder boundary for deterministic capture-lifecycle failures. Production
/// keeps the real writer; injected recorders can fail close without disk faults.
protocol PipelineRecording: AnyObject {
    var onWriteFailure: ((String) -> Void)? { get set }
    var micURL: URL? { get }
    var systemURL: URL? { get }
    func open(in directory: URL) throws
    func appendMic(_ buffer: AVAudioPCMBuffer)
    func appendSystem(_ buffer: AVAudioPCMBuffer)
    func appendMicSilence(matching buffer: AVAudioPCMBuffer)
    func appendSystemSilence(matching buffer: AVAudioPCMBuffer)
    func markMicStarted()
    func markSystemStarted()
    func close()
}

extension MeetingRecorder: PipelineRecording {}

/// Lock guards the first failure across writer callbacks and finalization.
/// The writer callback updates this before scheduling any UI notification.
private final class RecordingFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var firstMessage: String?

    func record(_ message: String) {
        lock.withLock {
            if firstMessage == nil { firstMessage = message }
        }
    }

    var message: String? { lock.withLock { firstMessage } }
}

private final class LockedSTTClient: @unchecked Sendable {
    private let lock = NSLock()
    private var client: STTClient?

    var value: STTClient? {
        get { lock.withLock { client } }
        set { lock.withLock { client = newValue } }
    }
}

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
    /// Provider failures degrade live text, but must not stop durable audio.
    var onTranscriptionError: ((_ message: String, _ isAuth: Bool, _ channel: String) -> Void)?
    /// Mic-leg transcription connection health (drives the UI "● live" dot).
    var onTranscriptionHealth: ((TranscriptionHealth) -> Void)?
    /// System-audio-leg health — used to surface a non-fatal "other party
    /// audio lost" notice without stopping the (mic-driven) session.
    var onSystemAudioHealth: ((TranscriptionHealth) -> Void)?
    /// Fires when a leg ("mic" / "system") opens a stream after its first one,
    /// with how many milliseconds into the capture it opened. Each socket is a
    /// new Soniox stream whose word timestamps restart at 0: an automatic
    /// reconnect, the system leg rejoining after a park, or a mid-session
    /// client swap. The transcript re-bases that leg on this instant.
    var onStreamRestarted: ((_ channel: String, _ atMs: Int) -> Void)?
    /// Streams opened per leg this session; the first one defines the leg's
    /// timeline, every later one is a restart.
    private var micStreamsOpened = 0
    private var systemStreamsOpened = 0

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

    private let audio: MicrophoneCapturing
    private let hasSTTKey: () -> Bool
    private let makeSTTClient: (TranslationConfig?, [String]) -> STTClient
    private let makeSystemCapture: (() -> SystemAudioCapturing)?
    private let systemAudioEnabled: Bool
    private let now: () -> Date
    private let log: (String, LogCategory) -> Void
    /// Picked at `start()`: a CoreAudio process tap when available (macOS
    /// 14.2+ and permission granted), else the ScreenCaptureKit fallback.
    private var systemAudio: SystemAudioCapturing?
    /// True between `start()` and `finalize()`/`abort()`. System-audio capture
    /// starts on an async Task; this flag lets that Task notice if the session
    /// was already torn down while it was awaiting startup, so it can release
    /// the backend instead of leaking a running tap.
    private var isCapturing = false
    /// Bumped by every `start()`. The system leg starts on a Task that sleeps
    /// eight seconds first; a session stopped and a new one started inside
    /// that window left `isCapturing` true again, so the OLD Task went on to
    /// attach a second tap and STT client, and the new Task then overwrote
    /// them without stopping them. The Task now checks it is still the
    /// capture it was started for.
    private var captureGeneration = 0
    /// Wall-clock instant the mic leg started sending audio (≈ the mic Soniox
    /// stream's `startMs == 0`). Used to measure how much later the system
    /// leg starts so its timestamps can be aligned to the mic timeline.
    private var captureStartWall: Date?
    /// A rebound device needs its own first-buffer grace period. The session
    /// clock must stay fixed for transcript timestamps.
    private var micInputStartedAt: Date?
    private let recorder: PipelineRecording
    private var recordingFailure = RecordingFailureLatch()
    /// The active speech-to-text client (Soniox today), built by
    /// STTProviders from the user's Settings choice. `soniox` is a historical
    /// name; it is whichever provider is active. Capture callbacks read
    /// both off the main thread while main swaps them, so each sits behind
    /// a lock and a read returns a retained reference.
    private let micClient = LockedSTTClient()
    private let systemClient = LockedSTTClient()
    private var soniox: STTClient? {
        get { micClient.value }
        set { micClient.value = newValue }
    }
    private var systemSoniox: STTClient? {
        get { systemClient.value }
        set { systemClient.value = newValue }
    }

    /// The two retained capture legs. SessionArchive moves them out of temp at
    /// stop so the automatic second-pass transcript can diarize and align them.
    var micRecordingURL: URL? { recorder.micURL }
    var systemRecordingURL: URL? { recorder.systemURL }
    var recordingFailureMessage: String? { recordingFailure.message }

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
    /// Mic delivering buffers of exact zeros (not just quiet) this long is a
    /// dead leg, not a silent room: rebuild the engine, up to a few times.
    private let micZeroThreshold: TimeInterval = 10
    private let micZeroRestartBackoff: TimeInterval = 15
    private let micZeroMaxRestarts = 3
    private var micZeroRestarts = 0
    private var lastMicZeroRestartAt: Date?
    private var micZeroNoticeShown = false
    /// Non-fatal mic notice: a message while the mic leg is dead, nil when cleared.
    var onMicNotice: ((String?) -> Void)?
    /// Watches the system-audio backend itself, not just the Soniox socket.
    /// CoreAudio taps can keep "running" while a browser/helper PID changes
    /// underneath them; the watchdog asks the backend to reattach when buffers
    /// stop or stay below the audible floor.
    private var systemAudioWatchdog: Task<Void, Never>?
    private var systemAudioStartedAt: Date?
    private var lastSystemAudioRecoveryAt: Date?
    private var systemAudioOutageReported = false
    private var systemAudioRecoveryAttempts = 0
    /// The system-leg PCM/error handlers, kept so the watchdog can rewire
    /// them onto a ScreenCaptureKit backend if the CoreAudio tap turns out
    /// to deliver nothing (seen with Bluetooth output devices).
    private var systemPCMHandler: ((AVAudioPCMBuffer) -> Void)?
    private var systemCaptureErrorHandler: ((String) -> Void)?
    /// One-shot per session: a dead tap swaps to SCK at most once.
    private var didFallBackToSCK = false
    /// The system-leg STT socket connects only once the backend actually
    /// delivers audio. Connecting eagerly meant a dead tap left Soniox with
    /// a config and no audio → endless 408 timeout/reconnect spam.
    private var systemSTTConnected = false
    private var systemTranscriptionHealth: TranscriptionHealth = .idle
    /// Idle management for the system STT leg. Soniox terminates any stream
    /// that has carried no speech for ~55s with a 408 — measured directly
    /// 2026-08-31, and it fires even while continuous silence DATA is being
    /// received, so a silence keepalive cannot help (it only bills streamed
    /// audio time). With a Bluetooth output device the tap additionally stops
    /// delivering buffers entirely whenever nothing is playing. Both cases
    /// are handled the same way: after `systemIdleDisconnectThreshold` with
    /// no buffers the leg's socket is parked deliberately, and the next real
    /// buffer re-connects it (`connectSystemSTTIfNeeded`). No 408 churn, no
    /// billed silence, ~handshake-time rejoin when the other party speaks.
    private var systemIdleMonitorTask: Task<Void, Never>?
    /// Wall-clock of the most recent real backend buffer. Written on the
    /// backend's delivery queue, read at 1 Hz on main — tearing is benign.
    private var lastSystemBufferAt: Date?
    /// Set on the backend's delivery queue when a connect has been requested;
    /// cleared (on main) when the leg is parked so the next buffer re-arms.
    private var systemSTTLinkArmed = false
    private let systemIdleDisconnectThreshold: TimeInterval = 5
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
    private let systemAudioStartupDelayNs: UInt64

    init(
        audio: MicrophoneCapturing = AudioCaptureManager(),
        hasSTTKey: @escaping () -> Bool = { STTProviders.activeHasKey },
        makeSTTClient: @escaping (TranslationConfig?, [String]) -> STTClient = {
            STTProviders.makeActiveClient(translationConfig: $0, contextTerms: $1)
        },
        makeSystemCapture: (() -> SystemAudioCapturing)? = nil,
        systemAudioEnabled: Bool = true,
        systemAudioStartupDelayNs: UInt64 = 8_000_000_000,
        now: @escaping () -> Date = Date.init,
        log: @escaping (String, LogCategory) -> Void = { RTILog.log($0, category: $1) },
        recorder: PipelineRecording = MeetingRecorder()
    ) {
        self.audio = audio
        self.hasSTTKey = hasSTTKey
        self.makeSTTClient = makeSTTClient
        self.makeSystemCapture = makeSystemCapture
        self.systemAudioEnabled = systemAudioEnabled
        self.systemAudioStartupDelayNs = systemAudioStartupDelayNs
        self.now = now
        self.log = log
        self.recorder = recorder
    }

    func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        AudioCaptureManager().requestPermission(completion)
    }

    /// Open the durable recording legs and the mic Soniox client. Does
    /// **not** start capture yet — call `start()` after this returns.
    var translationConfig: TranslationConfig?

    /// Proper nouns from past meetings, sent to Soniox as `context.terms`
    /// to bias recognition of names/brands/orgs. Set before `prepare`.
    var contextTerms: [String] = []

    func prepare(recordingDirectory: URL) throws {
        // Fast-fail before opening a WAV on disk: a missing/empty Soniox
        // key would otherwise let the user "record" silently for 5 retries
        // before any error surfaces, leaving an orphan WAV behind.
        guard hasSTTKey() else {
            throw AudioPipelineError.missingSTTKey
        }

        micStreamsOpened = 0
        systemStreamsOpened = 0
        let failure = RecordingFailureLatch()
        recordingFailure = failure
        let onWriteFailure: @Sendable (String) -> Void = { [weak self, failure] message in
            failure.record(message)
            // Legacy writer callback bridge. Remove when recording events
            // expose an actor-safe stream; finalization reads the latch now.
            Task { @MainActor [weak self] in
                guard let self, recordingFailure === failure else { return }
                onError?(message, false)
            }
        }
        recorder.onWriteFailure = onWriteFailure
        try recorder.open(in: recordingDirectory)

        let client = makeSTTClient(translationConfig, contextTerms)
        client.onWords = { [weak self] words in self?.onWords?(words) }
        client.onError = { [weak self] failure, didOpen in
            self?.reportTranscriptionFailure(failure, didOpen: didOpen, system: false)
        }
        client.onStatus = { [weak self] health in self?.micStatusChanged(health) }
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
                // transcribe it. Preserve matching silence in the durable leg
                // so offline timestamps stay aligned with notes after resume.
                recorder.appendMicSilence(matching: buffer)
                soniox?.sendAudio(Data(count: byteCount))
                return
            }
            recorder.appendMic(buffer)
            let data = Data(bytes: int16[0], count: byteCount)
            soniox?.sendAudio(data)
        }
    }

    /// Start mic capture immediately; system audio starts asynchronously
    /// (non-fatal if it fails).
    func start() throws {
        captureStartWall = now()
        micInputStartedAt = captureStartWall
        try audio.start()
        recorder.markMicStarted()
        isCapturing = true
        captureGeneration += 1
        let generation = captureGeneration
        didFallBackToSCK = false
        systemSTTConnected = false
        systemTranscriptionHealth = .idle
        lastSystemBufferAt = nil
        systemSTTLinkArmed = false
        startMicWatchdog()

        // Don't even attempt the system-audio Soniox leg without a key.
        // The mic leg already enforces this in `prepare`; this guard
        // mirrors it so we don't silently consume Soniox credits on a
        // doomed second connection.
        guard systemAudioEnabled, hasSTTKey() else { return }

        Task { @MainActor [weak self] in
            guard let self, isCapturing else { return }
            try? await Task.sleep(nanoseconds: systemAudioStartupDelayNs)
            guard isCapturing, captureGeneration == generation else { return }
            let sysClient = makeSTTClient(translationConfig, contextTerms)
            sysClient.onWords = { [weak self] words in self?.onSystemWords?(words) }
            sysClient.onError = { [weak self] failure, didOpen in
                guard let self else { return }
                let message = failure.userMessage(didOpen: didOpen)
                log("system audio Soniox error — \(message)", .soniox)
                // A transcription outage does not stop either retained leg.
                reportTranscriptionFailure(failure, didOpen: didOpen, system: true)
            }
            sysClient.onStatus = { [weak self] health in self?.systemStatusChanged(health) }
            // Deliberately NOT connected yet — see `connectSystemSTTIfNeeded`:
            // the socket opens on the first real buffer from the backend.
            systemSoniox = sysClient

            var systemBufferCount = 0
            let onPCM: (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
                guard let self else { return }
                lastSystemBufferAt = now()
                systemBufferCount += 1
                if systemBufferCount == 1 || systemBufferCount % 200 == 0 {
                    log("system PCM buffer #\(systemBufferCount): frames=\(buffer.frameLength) int16=\(buffer.int16ChannelData != nil)", .audio)
                }
                if !systemSTTLinkArmed {
                    systemSTTLinkArmed = true
                    DispatchQueue.main.async { [weak self] in self?.connectSystemSTTIfNeeded() }
                }
                levelMeter.recordSystem(buffer)
                guard let int16 = buffer.int16ChannelData else { return }
                let frameLength = Int(buffer.frameLength)
                let byteCount = frameLength * MemoryLayout<Int16>.size
                if suspended {
                    recorder.appendSystemSilence(matching: buffer)
                    systemSoniox?.sendAudio(Data(count: byteCount))
                    return
                }
                recorder.appendSystem(buffer)
                let data = Data(bytes: int16[0], count: byteCount)
                systemSoniox?.sendAudio(data)
            }
            let onErr: @Sendable (String) -> Void = { [weak self] msg in
                // Legacy capture callbacks can arrive on a backend queue.
                // Remove this bridge when capture events use an actor-safe stream.
                Task { @MainActor [weak self] in
                    guard let self, isCapturing, captureGeneration == generation else { return }
                    log("system audio capture error — \(msg)", .audio)
                    systemAudioOutageReported = true
                    onSystemAudioHealth?(.failed)
                }
            }
            systemPCMHandler = onPCM
            systemCaptureErrorHandler = onErr

            if let makeSystemCapture {
                let backend = makeSystemCapture()
                backend.onPCMBuffer = onPCM
                backend.onError = onErr
                do {
                    try await backend.start()
                    guard isCapturing, captureGeneration == generation else { backend.stop(); return }
                    systemAudio = backend
                    markSystemAudioStarted()
                } catch {
                    onSystemAudioHealth?(.failed)
                }
                return
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
                    guard isCapturing, captureGeneration == generation else { tap.stop(); return }
                    systemAudio = tap
                    markSystemAudioStarted()
                    return
                } catch {
                    log("CoreAudio tap unavailable, falling back to ScreenCaptureKit — \(error)", .audio)
                }
            }

            guard isCapturing, captureGeneration == generation else { return }
            let sck = SystemAudioCapture()
            sck.onPCMBuffer = onPCM
            sck.onError = onErr
            do {
                try await sck.start()
                guard isCapturing, captureGeneration == generation else { sck.stop(); return }
                systemAudio = sck
                markSystemAudioStarted()
            } catch {
                log("system audio start failed — \(error)", .audio)
                onSystemAudioHealth?(.failed)
            }
        }
    }

    /// A client reports `.live` once per socket it opens, so a second `.live`
    /// on a leg is a new stream (see `onStreamRestarted`).
    private func micStatusChanged(_ health: TranscriptionHealth) {
        if health == .live {
            micStreamsOpened += 1
            if micStreamsOpened > 1 { onStreamRestarted?("mic", captureElapsedMs()) }
        }
        onTranscriptionHealth?(health)
    }

    private func systemStatusChanged(_ health: TranscriptionHealth) {
        systemTranscriptionHealth = health
        if health == .live {
            systemStreamsOpened += 1
            if systemStreamsOpened > 1 { onStreamRestarted?("system", captureElapsedMs()) }
        }
        onSystemAudioHealth?(systemAudioOutageReported ? .failed : health)
    }

    private func reportTranscriptionFailure(_ failure: SonioxFailure, didOpen: Bool, system: Bool) {
        if system { systemStatusChanged(.failed) }
        else { micStatusChanged(.failed) }
        // Retryable failures reach onError only when the client's retry budget
        // is exhausted. Its ordinary drop message still says "reconnecting".
        let captureState = suspended ? "Recording remains paused." : "Audio is still recording."
        let message = failure.shouldRetry
            ? "Live transcription stopped after repeated connection failures. \(captureState)"
            : failure.userMessage(didOpen: didOpen)
        onTranscriptionError?((system ? "System audio: " : "") + message, failure.isAuth, system ? "system" : "mic")
    }

    private func captureElapsedMs() -> Int {
        Int(max(0, now().timeIntervalSince(captureStartWall ?? now()) * 1000))
    }

    /// Open the system-leg STT socket the first time the backend proves it
    /// can deliver audio. Idempotent; called (via main) from the PCM path.
    private func connectSystemSTTIfNeeded() {
        guard isCapturing, !systemSTTConnected, let client = systemSoniox else { return }
        systemSTTConnected = true
        log("system audio flowing — connecting system STT leg", .audio)
        client.connect()
        startSystemIdleMonitor()
    }

    private func startSystemIdleMonitor() {
        guard systemIdleMonitorTask == nil else { return }
        systemIdleMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, isCapturing else { continue }
                parkSystemSTTIfIdle()
            }
        }
    }

    private func stopSystemIdleMonitor() {
        systemIdleMonitorTask?.cancel()
        systemIdleMonitorTask = nil
    }

    /// Park the leg's socket while the backend delivers nothing. Deliberate
    /// disconnect, so SonioxClient suppresses reconnects; the next buffer
    /// re-arms via `connectSystemSTTIfNeeded`.
    private func parkSystemSTTIfIdle() {
        guard systemSTTConnected, let client = systemSoniox else { return }
        let last = lastSystemBufferAt ?? .distantPast
        guard now().timeIntervalSince(last) > systemIdleDisconnectThreshold else { return }
        log("system audio idle \(Int(now().timeIntervalSince(last)))s — parking system STT leg until audio resumes", .audio)
        systemSTTConnected = false
        systemSTTLinkArmed = false
        client.disconnect()
    }

    private func markSystemAudioStarted() {
        recorder.markSystemStarted()
        systemAudioStartedAt = now()
        systemAudioOutageReported = false
        lastSystemAudioRecoveryAt = nil
        systemAudioRecoveryAttempts = 0
        reportSystemAudioStart()
        startSystemAudioWatchdog()
    }

    /// Report how much later the system-audio leg started than the mic leg,
    /// so the transcript can align the two channels' timestamps.
    private func reportSystemAudioStart() {
        let offsetMs = Int(max(0, now().timeIntervalSince(captureStartWall ?? now()) * 1000))
        onSystemAudioStarted?(offsetMs)
    }

    // MARK: - Mic health watchdog

    private func startMicWatchdog() {
        micOutageReported = false
        micZeroRestarts = 0
        lastMicZeroRestartAt = nil
        micZeroNoticeShown = false
        audio.onRestarted = { [weak self] in
            guard let self else { return }
            let restartedAt = now()
            lastMicZeroRestartAt = restartedAt
            micInputStartedAt = restartedAt
        }
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
    /// once per outage.
    func checkMicHealth() {
        guard let since = audio.secondsSinceLastBuffer() else {
            // No FIRST buffer ever. This used to be treated as "still starting
            // up" forever, which let a bound-but-dead input device (2026-08-31:
            // an A2DP-parked AirPods mic) record silently-nothing for a whole
            // meeting. Apply the threshold from the last input start instead.
            if let started = micInputStartedAt,
               now().timeIntervalSince(started) > micOutageThreshold,
               !micOutageReported {
                micOutageReported = true
                onError?(
                    "The microphone never delivered audio — the selected input device may be unavailable. Check the input device in Settings, then start the session again.",
                    false
                )
            }
            return
        }
        if since > micOutageThreshold {
            guard !micOutageReported else { return }
            micOutageReported = true
            onError?(
                "Microphone audio stopped (\(Int(since))s ago) — the input device may have disconnected or RTI lost mic access. Restart the session, or check Settings → Privacy → Microphone.",
                false
            )
        } else {
            micOutageReported = false
            checkMicSilence()
        }
    }

    /// Exact-zero mic audio (liveness is fine, content is dead): log, rebuild
    /// the engine with backoff, and surface a non-fatal notice if that fails.
    private func checkMicSilence() {
        guard !suspended, !audio.micMuted, let zero = audio.secondsAllZero(), zero >= micZeroThreshold else {
            if micZeroNoticeShown {
                micZeroNoticeShown = false
                onMicNotice?(nil)
            }
            return
        }
        if let last = lastMicZeroRestartAt, now().timeIntervalSince(last) < micZeroRestartBackoff { return }
        if micZeroRestarts < micZeroMaxRestarts {
            micZeroRestarts += 1
            lastMicZeroRestartAt = now()
            log("mic leg all-zero for \(Int(zero))s, restarting (attempt \(micZeroRestarts)/\(micZeroMaxRestarts))", .audio)
            do { try audio.restart() } catch {
                log("mic restart failed: \(error)", .audio)
            }
        } else if !micZeroNoticeShown {
            micZeroNoticeShown = true
            log("mic leg still all-zero after \(micZeroMaxRestarts) restarts", .audio)
            onMicNotice?("Your microphone is recording silence. Another app may hold it. Pause and resume, or check the input device.")
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

    func checkSystemAudioHealth() async {
        guard let backend = systemAudio, let startedAt = systemAudioStartedAt else { return }
        let health = backend.captureHealth()
        let now = self.now()
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
            onSystemAudioHealth?(systemTranscriptionHealth)
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
        let now = self.now()
        if let lastSystemAudioRecoveryAt,
           now.timeIntervalSince(lastSystemAudioRecoveryAt) < systemAudioRecoveryCooldown {
            reportPersistentSystemAudioOutageIfNeeded(reason: reason, elapsed: elapsed, health: health, shouldNotify: notifyIfPersistent)
            return
        }

        if systemAudioRecoveryAttempts < systemAudioMaxRecoveryAttempts {
            lastSystemAudioRecoveryAt = now

            if await (systemAudio?.recoverFromSilentAudio() ?? false) {
                systemAudioRecoveryAttempts += 1
                log(
                    "system audio backend recovered after \(reason) (\(systemAudioRecoveryAttempts)/\(systemAudioMaxRecoveryAttempts), captured=\(String(format: "%.1f", health.duration))s audible=\(String(format: "%.1f", health.audibleDuration))s peakRMS=\(String(format: "%.4f", health.peakRMSLevel)))",
                    .audio
                )
                return
            }
        }

        if await fallBackToSCKIfTapDead(health: health) { return }

        reportPersistentSystemAudioOutageIfNeeded(reason: reason, elapsed: elapsed, health: health, shouldNotify: notifyIfPersistent)
    }

    /// Last-resort backend swap: the CoreAudio tap can "run" while delivering
    /// no buffers at all (seen 2026-08-31 with a Bluetooth output device —
    /// captured=0.0s for a whole meeting, so the other party was never
    /// transcribed). When rebuild attempts are exhausted and the tap has
    /// produced essentially nothing, replace it with the ScreenCaptureKit
    /// backend. Only fires for a tap that never delivered — buffers arriving
    /// with silent CONTENT just mean nobody is talking, and stay untouched.
    private func fallBackToSCKIfTapDead(health: SystemAudioCaptureHealth) async -> Bool {
        guard !didFallBackToSCK, isCapturing,
              health.duration < 0.5,
              let onPCM = systemPCMHandler, let onErr = systemCaptureErrorHandler else { return false }
        guard #available(macOS 14.2, *), systemAudio is CoreAudioTapCapture else { return false }
        didFallBackToSCK = true
        log("CoreAudio tap delivered no audio — falling back to ScreenCaptureKit", .audio)
        systemAudio?.stop()
        systemAudio = nil
        let sck = SystemAudioCapture()
        sck.onPCMBuffer = onPCM
        sck.onError = onErr
        do {
            try await sck.start()
            guard isCapturing else { sck.stop(); return false }
            systemAudio = sck
            markSystemAudioStarted()
            return true
        } catch {
            log("ScreenCaptureKit fallback failed — \(error)", .audio)
            onSystemAudioHealth?(.failed)
            return false
        }
    }

    private func reportPersistentSystemAudioOutageIfNeeded(
        reason: String,
        elapsed: TimeInterval,
        health: SystemAudioCaptureHealth,
        shouldNotify: Bool
    ) {
        guard shouldNotify, elapsed >= systemAudioNoticeThreshold, !systemAudioOutageReported else { return }
        systemAudioOutageReported = true
        log(
            "system audio \(reason) for \(Int(elapsed))s (captured=\(String(format: "%.1f", health.duration))s audible=\(String(format: "%.1f", health.audibleDuration))s peakRMS=\(String(format: "%.4f", health.peakRMSLevel)))",
            .audio
        )
        onSystemAudioHealth?(.failed)
    }

    /// Stop capture and signal end-of-audio to Soniox. Call `finish()`
    /// after the 1.5 s finalize window to disconnect and close the WAV.
    func finalize() {
        isCapturing = false
        stopMicWatchdog()
        stopSystemAudioWatchdog()
        stopSystemIdleMonitor()
        levelMeter.reset()
        audio.stop()
        systemAudio?.stop()
        systemAudio = nil
        systemPCMHandler = nil
        systemCaptureErrorHandler = nil
        soniox?.finalize()
        systemSoniox?.finalize()
    }

    /// Disconnect Soniox and close the WAV file. The synchronous result also
    /// includes failures whose UI notification is still queued on MainActor.
    @discardableResult
    func finish() -> Bool {
        soniox?.disconnect()
        soniox = nil
        systemSoniox?.disconnect()
        systemSoniox = nil
        recorder.close()
        return recordingFailure.message == nil
    }

    /// Swap the live transcription clients to apply a new provider and/or
    /// translation config mid-session, without interrupting audio capture or
    /// losing the WAV file. Old clients are disconnected; new ones are created
    /// with the current `translationConfig` and immediately receive incoming
    /// PCM buffers via the existing `onPCMBuffer` closures.
    func reconfigureStreamingClients() {
        guard hasSTTKey() else { return }

        // Mic leg.
        soniox?.disconnect()
        let mic = makeSTTClient(translationConfig, contextTerms)
        mic.onWords = { [weak self] words in self?.onWords?(words) }
        mic.onError = { [weak self] failure, didOpen in
            self?.reportTranscriptionFailure(failure, didOpen: didOpen, system: false)
        }
        mic.onStatus = { [weak self] health in self?.micStatusChanged(health) }
        mic.connect()
        soniox = mic

        // System leg (if active).
        if systemSoniox != nil {
            systemSoniox?.disconnect()
            let sys = makeSTTClient(translationConfig, contextTerms)
            sys.onWords = { [weak self] words in self?.onSystemWords?(words) }
            sys.onError = { [weak self] failure, didOpen in
                self?.reportTranscriptionFailure(failure, didOpen: didOpen, system: true)
            }
            sys.onStatus = { [weak self] health in self?.systemStatusChanged(health) }
            // Same lazy rule as at start: only open the socket if the backend
            // has proven it delivers audio (connectSystemSTTIfNeeded covers
            // the not-yet case when the first buffer eventually arrives).
            if systemSTTConnected { sys.connect() }
            systemSoniox = sys
        }
    }

    /// Immediate teardown for failures and app termination.
    func abort() {
        isCapturing = false
        stopMicWatchdog()
        stopSystemAudioWatchdog()
        stopSystemIdleMonitor()
        levelMeter.reset()
        audio.stop()
        systemAudio?.stop()
        systemAudio = nil
        systemPCMHandler = nil
        systemCaptureErrorHandler = nil
        soniox?.disconnect()
        soniox = nil
        systemSoniox?.disconnect()
        systemSoniox = nil
        recorder.close()
    }
}

enum AudioPipelineError: LocalizedError {
    case missingSTTKey
    case recordingArchiveUnavailable

    var errorDescription: String? {
        switch self {
        case .missingSTTKey:
            "No speech-to-text API key set for the selected provider. Open Settings to paste a key, then start the session again."
        case .recordingArchiveUnavailable:
            "RTI couldn't create a durable meeting folder. Recording was not started."
        }
    }
}
