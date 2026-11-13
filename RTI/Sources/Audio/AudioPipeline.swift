import AppKit
import AVFoundation
import Foundation
import RTICore

/// Recorder boundary for deterministic capture-lifecycle failures. Production
/// keeps the real writer; injected recorders can fail close without disk faults.
protocol PipelineRecording: AnyObject {
    /// Fatal: a leg could not be written for `MeetingRecorder.writeFailureTolerance`,
    /// or the file could not be closed. The session stops.
    var onWriteFailure: ((String) -> Void)? { get set }
    /// Degraded: a leg write failed (message) or works again (nil). Capture
    /// goes on and the missed frames are written as silence on recovery.
    var onWriteDegraded: ((_ leg: String, _ message: String?) -> Void)? { get set }
    /// A stretch of a leg was written as silence (no audio, or owed by a
    /// failed write). Recorded as a capture gap (AUD-4).
    var onGapFilled: ((_ leg: String, _ startFrame: Int, _ frameCount: Int, _ writeFailed: Bool) -> Void)? { get set }
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
    /// Fires on terminal recording failures: the durable WAV could not be
    /// written for `MeetingRecorder.writeFailureTolerance` or not closed. A
    /// lost or rebinding microphone is NOT terminal (`onMicNotice`), so the
    /// other leg keeps recording. `isAuth` gates the "Open Settings" affordance.
    var onError: ((String, Bool) -> Void)?
    /// Non-fatal: a durable audio write is failing (message) or works again
    /// (nil). Capture continues; the missed frames become silence.
    var onRecordingNotice: ((String?) -> Void)?
    /// Provider failures degrade live text, but must not stop durable audio.
    var onTranscriptionError: ((_ message: String, _ isAuth: Bool, _ channel: String) -> Void)?
    /// Mic-leg transcription connection health (drives the UI "● live" dot).
    var onTranscriptionHealth: ((TranscriptionHealth) -> Void)?
    /// System-audio-leg health — used to surface a non-fatal "other party
    /// audio lost" notice without stopping the (mic-driven) session.
    var onSystemAudioHealth: ((TranscriptionHealth) -> Void)?
    /// Fires when a leg opens a stream, with how many milliseconds into the
    /// capture it opened: the mic after its first stream, the system leg on
    /// every stream (its first socket opens only at the first system buffer).
    /// Each socket is a new Soniox stream whose word timestamps restart at 0:
    /// the first system stream, an automatic
    /// reconnect, the system leg rejoining after a park, or a mid-session
    /// client swap. The transcript re-bases that leg on this instant.
    var onStreamRestarted: ((_ channel: String, _ atMs: Int) -> Void)?
    /// Mic streams opened this session; the first one defines the mic
    /// timeline, every later one is a restart.
    /// Automatic mic reconnects since the mic last reached `.live`. Each one
    /// doubles the pause before the next (`micAutoReconnectDelay`).
    private var micAutoReconnectAttempts = 0
    /// The same for the system leg since it last reached `.live`. Without
    /// it a spent system budget left the other side's live transcript dead
    /// for the rest of the call: a tap that keeps delivering (silent)
    /// buffers never parks, so nothing re-armed the leg.
    private var systemAutoReconnectAttempts = 0

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
    private let makeSTTClient: (TranslationConfig?, SonioxContext?, Bool) -> STTClient
    private let makeSystemCapture: (() -> SystemAudioCapturing)?
    private let systemAudioEnabled: Bool
    private let now: () -> Date
    private let log: (String, LogCategory) -> Void
    /// The backend the watchdog swaps a never-delivering process tap for.
    private let makeFallbackSystemCapture: () -> SystemAudioCapturing
    /// Screen Recording is optional for RTI, and asking for it mid-call
    /// raises a TCC prompt. The fallback is tried only when already granted.
    private let screenCapturePermitted: () -> Bool
    /// Sleep and wake arrive here (`NSWorkspace`'s center in production).
    private let workspaceNotifications: NotificationCenter
    private var sleepObservers: [NSObjectProtocol] = []
    /// True between willSleep and didWake. The watchdogs run on a clock that
    /// counts sleep, so their first tick after wake must not judge the legs.
    private(set) var isAsleep = false
    private var sleepStartedAt: Date?
    /// The system watchdog waits this long after wake before it judges the
    /// leg (the mic uses `micInputStartedAt` for the same grace).
    private var systemWakeGraceUntil: Date?
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
    private(set) var captureStartWall: Date?
    /// A rebound device needs its own first-buffer grace period. The session
    /// clock must stay fixed for transcript timestamps.
    private var micInputStartedAt: Date?
    private let recorder: PipelineRecording
    private var recordingFailure = RecordingFailureLatch()
    /// Stretches a leg did not record this session (AUD-4): mic outages and
    /// all-zero input, system capture failures, and the writer's silence
    /// fills. Written to session.json, transcript.md and the sidecar.
    private(set) var captureGapLog = CaptureGapLog()
    /// When the system leg started, in session milliseconds: the writer
    /// counts system frames from there.
    private var systemLegStartMs: Int?
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
    /// Set while the mic delivers nothing: the session keeps recording the
    /// other leg and the watchdog rebinds the input with backoff.
    private(set) var micOutageStartedAt: Date?
    private(set) var micOutageRestarts = 0
    private var lastMicOutageRestartAt: Date?
    /// Seconds without a mic buffer before we call it dead. Generous so a brief
    /// hiccup or device reroute doesn't false-alarm.
    private let micOutageThreshold: TimeInterval = 8
    /// Pause before outage rebind `attempt` (0-based): at once, then 5 s,
    /// doubling to a 60 s cap, for as long as the outage lasts.
    static func micOutageRestartDelay(attempt: Int) -> TimeInterval {
        attempt <= 0 ? 0 : min(5 * pow(2, Double(min(attempt - 1, 4))), 60)
    }

    static let micLostNotice = "Your microphone stopped sending audio. RTI keeps recording the other side and is reconnecting the mic. If this stays, check the input device in Settings or Privacy & Security > Microphone."
    static let recordingWriteNotice = "RTI could not save meeting audio to disk. It keeps trying, and the missed seconds are kept as silence. Free disk space now; recording stops if this lasts 30 seconds."
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
    /// The system CAPTURE failed (not just its transcription), so the other
    /// side is not being recorded. Read by the session's notice.
    private(set) var systemAudioOutageReported = false
    private var systemAudioRecoveryAttempts = 0
    /// The system-leg PCM/error handlers, kept so the watchdog can rewire
    /// them onto a ScreenCaptureKit backend if the CoreAudio tap turns out
    /// to deliver nothing (seen with Bluetooth output devices).
    private var systemPCMHandler: ((AVAudioPCMBuffer) -> Void)?
    private var systemCaptureErrorHandler: ((String) -> Void)?
    /// One-shot per session: a dead tap swaps to SCK at most once.
    private var didFallBackToSCK = false
    /// After the fast recovery attempts are spent, the watchdog keeps
    /// rebuilding a silent backend at this slower cadence for the whole call.
    private let systemAudioSlowRecoveryInterval: TimeInterval = 60
    /// Legs whose durable writes are failing now, with the latest error.
    private var degradedWriteLegs: [String: String] = [:]
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
    /// How long a leg (mic or system) whose client spent its retry budget
    /// waits before the first fresh reconnect. Auth and client-bug failures
    /// never schedule one.
    private let micAutoReconnectDelayNs: UInt64
    /// The pause doubles per spent budget up to this many times the base
    /// (45 s → 6 min), so a long outage does not flap the error banner.
    static let micAutoReconnectMaxBackoffFactor: UInt64 = 8
    /// The pending automatic mic reconnect. Cancelled by `.live`, a
    /// manual client swap, a new session, finalize and abort.
    private var micAutoReconnectTask: Task<Void, Never>?
    /// The pending automatic system-leg reconnect, cancelled the same way.
    private var systemAutoReconnectTask: Task<Void, Never>?

    init(
        audio: MicrophoneCapturing = AudioCaptureManager(),
        hasSTTKey: @escaping () -> Bool = { STTProviders.activeHasKey },
        makeSTTClient: @escaping (TranslationConfig?, SonioxContext?, Bool) -> STTClient = {
            STTProviders.makeActiveClient(translationConfig: $0, context: $1, diarize: $2)
        },
        makeSystemCapture: (() -> SystemAudioCapturing)? = nil,
        makeFallbackSystemCapture: @escaping () -> SystemAudioCapturing = { SystemAudioCapture() },
        screenCapturePermitted: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        systemAudioEnabled: Bool = true,
        systemAudioStartupDelayNs: UInt64 = 8_000_000_000,
        micAutoReconnectDelayNs: UInt64 = 45_000_000_000,
        now: @escaping () -> Date = Date.init,
        log: @escaping (String, LogCategory) -> Void = { RTILog.log($0, category: $1) },
        recorder: PipelineRecording = MeetingRecorder()
    ) {
        self.audio = audio
        self.hasSTTKey = hasSTTKey
        self.makeSTTClient = makeSTTClient
        self.makeSystemCapture = makeSystemCapture
        self.makeFallbackSystemCapture = makeFallbackSystemCapture
        self.screenCapturePermitted = screenCapturePermitted
        self.workspaceNotifications = workspaceNotifications
        self.systemAudioEnabled = systemAudioEnabled
        self.systemAudioStartupDelayNs = systemAudioStartupDelayNs
        self.micAutoReconnectDelayNs = micAutoReconnectDelayNs
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
    var systemSpeakerLabelsEnabled = true

    /// What Soniox is told about this meeting. Set before `prepare`.
    var speechContext: SonioxContext?

    func prepare(recordingDirectory: URL) throws {
        // Fast-fail before opening a WAV on disk: a missing/empty Soniox
        // key would otherwise let the user "record" silently for 5 retries
        // before any error surfaces, leaving an orphan WAV behind.
        guard hasSTTKey() else {
            throw AudioPipelineError.missingSTTKey
        }

        cancelMicAutoReconnect()
        cancelSystemAutoReconnect()
        micAutoReconnectAttempts = 0
        systemAutoReconnectAttempts = 0
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
        degradedWriteLegs = [:]
        recorder.onWriteDegraded = { [weak self, failure] leg, message in
            Task { @MainActor [weak self] in
                guard let self, recordingFailure === failure else { return }
                writeDegradedChanged(leg: leg, message: message)
            }
        }
        captureGapLog = CaptureGapLog()
        systemLegStartMs = nil
        recorder.onGapFilled = { [weak self, failure] leg, startFrame, frames, writeFailed in
            Task { @MainActor [weak self] in
                guard let self, recordingFailure === failure else { return }
                recordFilledGap(leg: leg, startFrame: startFrame, frames: frames, writeFailed: writeFailed)
            }
        }
        try recorder.open(in: recordingDirectory)

        let client = makeSTTClient(translationConfig, speechContext, false)
        soniox = client
        bindTranscriptionCallbacks(client, system: false)
        client.connect()

        audio.onPCMBuffer = { [weak self] buffer in
            guard let self else { return }
            levelMeter.recordMic(buffer)
            guard let int16 = buffer.int16ChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let byteCount = frameLength * MemoryLayout<Int16>.size
            if suspended || audio.micMuted {
                // Paused: don't keep the audio (no WAV append) and don't
                // transcribe it. Preserve matching silence in the durable leg
                // so offline timestamps stay aligned with notes after resume.
                // Muted: the capture already sends zeros; silence here too,
                // so no mic sample can pass a mute.
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
    /// (non-fatal if it fails). `micMuted` applies before capture opens, so a
    /// muted (listening-only) call never records or sends a mic sample.
    func start(micMuted: Bool) throws {
        self.micMuted = micMuted
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
        observeSleepAndWake()

        // Don't even attempt the system-audio Soniox leg without a key.
        // The mic leg already enforces this in `prepare`; this guard
        // mirrors it so we don't silently consume Soniox credits on a
        // doomed second connection.
        guard systemAudioEnabled, hasSTTKey() else { return }

        Task { @MainActor [weak self] in
            guard let self, isCapturing else { return }
            try? await Task.sleep(nanoseconds: systemAudioStartupDelayNs)
            guard isCapturing, captureGeneration == generation else { return }
            let sysClient = makeSTTClient(translationConfig, speechContext, systemSpeakerLabelsEnabled)
            systemSoniox = sysClient
            bindTranscriptionCallbacks(sysClient, system: true)
            // Connect only once the backend proves it delivers PCM.


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
                    setSystemCaptureOutage(true, since: now())
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
                    setSystemCaptureOutage(true, since: now())
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
                setSystemCaptureOutage(true, since: now())
                onSystemAudioHealth?(.failed)
            }
        }
    }

    /// Every mic `.live` re-bases the live transcript, the first one too: a
    /// client drops audio until its config frame is sent, so stream time 0 is
    /// this `.live`. The first socket can open long after capture started
    /// (retries spent with the network down, then an automatic reconnect).
    private func micStatusChanged(_ health: TranscriptionHealth) {
        if health == .live {
            cancelMicAutoReconnect()
            micAutoReconnectAttempts = 0
            onStreamRestarted?("mic", captureElapsedMs())
        }
        onTranscriptionHealth?(health)
    }

    /// Every system `.live` re-bases the live transcript, the first one too:
    /// the socket opens only at the first system buffer, which can arrive long
    /// after the backend started. `systemAudioStartOffsetMs` (the WAV and
    /// upgrade offset) is a separate value and does not move here.
    private func systemStatusChanged(_ health: TranscriptionHealth) {
        systemTranscriptionHealth = health
        if health == .live {
            cancelSystemAutoReconnect()
            systemAutoReconnectAttempts = 0
            onStreamRestarted?("system", captureElapsedMs())
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
            ? "Live transcription stopped after repeated connection failures. \(captureState) RTI reconnects on its own."
            : failure.userMessage(didOpen: didOpen)
        onTranscriptionError?((system ? "System audio: " : "") + message, failure.isAuth, system ? "system" : "mic")
        // A spent retry budget leaves the leg's client dead until someone
        // acts. Self-heal with one fresh client after a pause; the pause
        // doubles per spent budget until the leg is live again. Never for auth
        // or a client bug: those fail the same way again (a 401 loop).
        guard failure.shouldRetry else { return }
        if system { scheduleSystemAutoReconnect() } else { scheduleMicAutoReconnect() }
    }

    private func scheduleSystemAutoReconnect() {
        guard isCapturing else { return }
        cancelSystemAutoReconnect()
        let generation = captureGeneration
        let delay = Self.micAutoReconnectDelay(baseNs: micAutoReconnectDelayNs, attempt: systemAutoReconnectAttempts)
        systemAutoReconnectAttempts += 1
        systemAutoReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, isCapturing, captureGeneration == generation else { return }
            systemAutoReconnectTask = nil
            log("system transcription retries spent — automatic reconnect", .soniox)
            reconnectSystem()
        }
    }

    private func cancelSystemAutoReconnect() {
        systemAutoReconnectTask?.cancel()
        systemAutoReconnectTask = nil
    }

    /// Replace only the system client. The new one connects at the next
    /// system buffer (`connectSystemSTTIfNeeded`), exactly like a parked leg
    /// rejoining, so a backend that delivers nothing is not dialled. Its
    /// stream re-bases itself on its `.live` (`systemStatusChanged`).
    func reconnectSystem() {
        guard isCapturing, hasSTTKey(), let old = systemSoniox else { return }
        systemSoniox = nil
        old.disconnect()
        let sys = makeSTTClient(translationConfig, speechContext, systemSpeakerLabelsEnabled)
        systemSoniox = sys
        bindTranscriptionCallbacks(sys, system: true)
        systemSTTConnected = false
        systemSTTLinkArmed = false
    }

    private func scheduleMicAutoReconnect() {
        guard isCapturing else { return }
        cancelMicAutoReconnect()
        let generation = captureGeneration
        let delay = Self.micAutoReconnectDelay(baseNs: micAutoReconnectDelayNs, attempt: micAutoReconnectAttempts)
        micAutoReconnectAttempts += 1
        micAutoReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, isCapturing, captureGeneration == generation else { return }
            micAutoReconnectTask = nil
            log("mic transcription retries spent — automatic reconnect", .soniox)
            reconnectMic()
        }
    }

    /// Pause before automatic mic reconnect `attempt` (0-based): the base,
    /// doubled per earlier attempt, capped at `micAutoReconnectMaxBackoffFactor`.
    static func micAutoReconnectDelay(baseNs: UInt64, attempt: Int) -> UInt64 {
        let factor = min(UInt64(1) << UInt64(min(max(attempt, 0), 3)), micAutoReconnectMaxBackoffFactor)
        return baseNs * factor
    }

    private func cancelMicAutoReconnect() {
        micAutoReconnectTask?.cancel()
        micAutoReconnectTask = nil
    }

    /// Replace only the mic client. The system client, its stream base and
    /// the system offset are untouched; the new mic stream re-bases itself
    /// on its `.live` (`micStatusChanged`).
    func reconnectMic() {
        guard isCapturing, hasSTTKey() else { return }
        let oldMic = soniox
        soniox = nil
        oldMic?.disconnect()
        let mic = makeSTTClient(translationConfig, speechContext, false)
        soniox = mic
        bindTranscriptionCallbacks(mic, system: false)
        mic.connect()
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
        // The writer keeps the leg's first anchor across a backend swap.
        if systemLegStartMs == nil { systemLegStartMs = captureElapsedMs() }
        setSystemCaptureOutage(false, since: nil)
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
        micOutageStartedAt = nil
        micOutageRestarts = 0
        lastMicOutageRestartAt = nil
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

    /// A mic that delivers no buffers for longer than the threshold is dead
    /// (device unplugged or switched, another app holding it, a rebind that
    /// failed). That is degraded, never terminal: the system leg keeps
    /// recording, the user sees `micLostNotice`, and the input is rebound with
    /// backoff until buffers return. The recorder pads the mic leg's gap with
    /// silence when they do, so both legs keep one timeline.
    func checkMicHealth() {
        guard !isAsleep else { return }
        let now = now()
        let since = audio.secondsSinceLastBuffer()
        if let since, since <= micOutageThreshold {
            endMicOutageIfNeeded()
            checkMicSilence()
            return
        }
        // No recent buffer. Count from the later of the last buffer and the
        // last input start (session start, rebind, wake): a rebound device
        // gets its own first-buffer grace.
        let sinceInputStart = micInputStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let silentFor = since.map { min($0, sinceInputStart) } ?? sinceInputStart
        guard silentFor > micOutageThreshold else { return }
        if micOutageStartedAt == nil {
            micOutageStartedAt = now
            micOutageRestarts = 0
            lastMicOutageRestartAt = nil
            captureGapLog.begin(.mic, .noAudio, atMs: sessionMs(now) - Int(silentFor * 1000))
            log("mic delivered no audio for \(Int(silentFor))s — rebinding the input; the session keeps recording", .audio)
            onMicNotice?(Self.micLostNotice)
        }
        let delay = Self.micOutageRestartDelay(attempt: micOutageRestarts)
        if let last = lastMicOutageRestartAt, now.timeIntervalSince(last) < delay { return }
        micOutageRestarts += 1
        lastMicOutageRestartAt = now
        do {
            try audio.restart()
            log("mic rebind attempt \(micOutageRestarts) started", .audio)
        } catch {
            log("mic rebind attempt \(micOutageRestarts) failed: \(error)", .audio)
        }
    }

    private func endMicOutageIfNeeded() {
        guard let started = micOutageStartedAt else { return }
        log("mic audio back after \(Int(now().timeIntervalSince(started)))s (\(micOutageRestarts) rebind attempts)", .audio)
        captureGapLog.end(.mic, .noAudio, atMs: sessionMs(now()))
        micOutageStartedAt = nil
        micOutageRestarts = 0
        lastMicOutageRestartAt = nil
        micZeroNoticeShown = false
        onMicNotice?(nil)
    }

    /// Exact-zero mic audio (liveness is fine, content is dead): log, rebuild
    /// the engine with backoff, and surface a non-fatal notice if that fails.
    private func checkMicSilence() {
        guard !suspended, !audio.micMuted, let zero = audio.secondsAllZero(), zero >= micZeroThreshold else {
            captureGapLog.end(.mic, .silentInput, atMs: sessionMs(now()))
            if micZeroNoticeShown {
                micZeroNoticeShown = false
                onMicNotice?(nil)
            }
            return
        }
        captureGapLog.begin(.mic, .silentInput, atMs: sessionMs(now()) - Int(zero * 1000))
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
        guard !isAsleep, let backend = systemAudio, let startedAt = systemAudioStartedAt else { return }
        let health = backend.captureHealth()
        let now = self.now()
        if let grace = systemWakeGraceUntil, now < grace { return }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= systemAudioNoBufferThreshold else { return }

        // A backend's own counters restart at every rebuild; the pipeline's
        // last buffer covers the backend's whole life.
        let lastBuffer = health.lastBufferAt ?? lastSystemBufferAt
        let secondsSinceBuffer = lastBuffer.map { now.timeIntervalSince($0) } ?? elapsed
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
            setSystemCaptureOutage(false, since: nil)
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

        // Fast attempts first, then one every `systemAudioSlowRecoveryInterval`
        // for the rest of the call: a Bluetooth output stops the tap while
        // nothing plays, and the other party can speak again at any time.
        let slowRetryDue = lastSystemAudioRecoveryAt.map {
            now.timeIntervalSince($0) >= systemAudioSlowRecoveryInterval
        } ?? true
        if systemAudioRecoveryAttempts < systemAudioMaxRecoveryAttempts || slowRetryDue {
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
    /// delivered nothing this whole session, try ScreenCaptureKit. The tap's
    /// own counters restart at every rebuild, so the pipeline's
    /// `lastSystemBufferAt` decides: a tap that worked earlier is idle (nobody
    /// playing), not dead, and is kept. The fallback runs only with Screen
    /// Recording already granted, starts before the tap stops, and on failure
    /// leaves the tap in place for the slow rebuild cadence. `systemAudio` is
    /// never nil while capturing.
    private func fallBackToSCKIfTapDead(health: SystemAudioCaptureHealth) async -> Bool {
        guard !didFallBackToSCK, isCapturing,
              lastSystemBufferAt == nil, health.duration < 0.5,
              let tap = systemAudio, tap.fallsBackToScreenCapture,
              let onPCM = systemPCMHandler, let onErr = systemCaptureErrorHandler else { return false }
        guard screenCapturePermitted() else {
            log("CoreAudio tap delivered no audio; ScreenCaptureKit fallback skipped (no Screen Recording permission) — keeping the tap and retrying it", .audio)
            didFallBackToSCK = true
            return false
        }
        didFallBackToSCK = true
        log("CoreAudio tap delivered no audio — trying ScreenCaptureKit before releasing the tap", .audio)
        // `start()` can wait a long time (a Screen Recording prompt). The user
        // may stop and start another call meanwhile, and that call's backend
        // can be the same object (an injected factory), so the identity check
        // alone is not enough: the capture generation must match too.
        let generation = captureGeneration
        let gate = FallbackGate()
        let sck = makeFallbackSystemCapture()
        sck.onPCMBuffer = { buffer in if gate.isOpen { onPCM(buffer) } }
        sck.onError = { message in if gate.isOpen { onErr(message) } }
        do {
            try await sck.start()
        } catch {
            sck.stop()
            log("ScreenCaptureKit fallback failed — keeping the CoreAudio tap: \(error)", .audio)
            return false
        }
        guard isCapturing, captureGeneration == generation, systemAudio === tap else {
            log("ScreenCaptureKit fallback finished after its session ended — released it", .audio)
            sck.stop()
            return false
        }
        tap.stop()
        gate.open()
        systemAudio = sck
        markSystemAudioStarted()
        return true
    }

    private func reportPersistentSystemAudioOutageIfNeeded(
        reason: String,
        elapsed: TimeInterval,
        health: SystemAudioCaptureHealth,
        shouldNotify: Bool
    ) {
        guard shouldNotify, elapsed >= systemAudioNoticeThreshold, !systemAudioOutageReported else { return }
        setSystemCaptureOutage(true, since: lastSystemBufferAt ?? systemAudioStartedAt ?? now())
        log(
            "system audio \(reason) for \(Int(elapsed))s (captured=\(String(format: "%.1f", health.duration))s audible=\(String(format: "%.1f", health.audibleDuration))s peakRMS=\(String(format: "%.4f", health.peakRMSLevel)))",
            .audio
        )
        onSystemAudioHealth?(.failed)
    }

    /// Stop capture and signal end-of-audio to Soniox. Call `finish()`
    /// after the 1.5 s finalize window to disconnect and close the WAV.
    func finalize() {
        closeCaptureGaps()
        isCapturing = false
        stopObservingSleepAndWake()
        cancelMicAutoReconnect()
        cancelSystemAutoReconnect()
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
        let mic = soniox
        let system = systemSoniox
        soniox = nil
        systemSoniox = nil
        mic?.disconnect()
        system?.disconnect()
        recorder.close()
        return recordingFailure.message == nil
    }

    /// Every provider callback must still belong to this leg's current client.
    /// Navigation and finalize do not retire it; replacement, finish and abort do.
    private func bindTranscriptionCallbacks(_ client: STTClient, system: Bool) {
        client.onWords = { [weak self, weak client] words in
            guard let self, let client,
                  (system ? systemSoniox : soniox) === client else { return }
            if system { onSystemWords?(words) } else { onWords?(words) }
        }
        client.onError = { [weak self, weak client] failure, didOpen in
            guard let self, let client,
                  (system ? systemSoniox : soniox) === client else { return }
            reportTranscriptionFailure(failure, didOpen: didOpen, system: system)
        }
        client.onStatus = { [weak self, weak client] health in
            guard let self, let client,
                  (system ? systemSoniox : soniox) === client else { return }
            if system { systemStatusChanged(health) } else { micStatusChanged(health) }
        }
    }

    /// Swap the live transcription clients to apply a new provider and/or
    /// translation config mid-session, without interrupting audio capture or
    /// losing the WAV file. Old clients are disconnected; new ones are created
    /// with the current `translationConfig` and immediately receive incoming
    /// PCM buffers via the existing `onPCMBuffer` closures.
    ///
    /// Returns the legs that now open a new stream: empty without a key (no
    /// client changes), else the mic and, when its socket was linked, the
    /// system leg. The caller shows "switching" only for these.
    func reconfigureStreamingClients() -> Set<String> {
        cancelMicAutoReconnect()
        cancelSystemAutoReconnect()
        micAutoReconnectAttempts = 0
        systemAutoReconnectAttempts = 0
        guard hasSTTKey() else { return [] }
        var restarted: Set<String> = []

        // Retire ownership before disconnect: a provider may report teardown
        // synchronously. Publish the replacement before connect for the same reason.
        let oldMic = soniox
        soniox = nil
        oldMic?.disconnect()
        let mic = makeSTTClient(translationConfig, speechContext, false)
        soniox = mic
        bindTranscriptionCallbacks(mic, system: false)
        mic.connect()
        restarted.insert("mic")

        if let oldSystem = systemSoniox {
            systemSoniox = nil
            oldSystem.disconnect()
            let sys = makeSTTClient(translationConfig, speechContext, systemSpeakerLabelsEnabled)
            systemSoniox = sys
            bindTranscriptionCallbacks(sys, system: true)
            if systemSTTConnected {
                sys.connect()
                restarted.insert("system")
            }
        }
        return restarted
    }

    /// Immediate teardown for failures and app termination.
    func abort() {
        closeCaptureGaps()
        isCapturing = false
        stopObservingSleepAndWake()
        cancelMicAutoReconnect()
        cancelSystemAutoReconnect()
        stopMicWatchdog()
        stopSystemAudioWatchdog()
        stopSystemIdleMonitor()
        levelMeter.reset()
        audio.stop()
        systemAudio?.stop()
        systemAudio = nil
        systemPCMHandler = nil
        systemCaptureErrorHandler = nil
        let mic = soniox
        let system = systemSoniox
        soniox = nil
        systemSoniox = nil
        mic?.disconnect()
        system?.disconnect()
        recorder.close()
    }
}

// MARK: - Sleep, wake and degraded writes

extension AudioPipeline {
    private func observeSleepAndWake() {
        stopObservingSleepAndWake()
        isAsleep = false
        systemWakeGraceUntil = nil
        let center = workspaceNotifications
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            },
        ]
    }

    private func stopObservingSleepAndWake() {
        sleepObservers.forEach { workspaceNotifications.removeObserver($0) }
        sleepObservers = []
        isAsleep = false
    }

    /// Lid close or system sleep. The watchdogs stop judging the legs until
    /// wake; the recorder's clock counts the sleep, so on wake each leg is
    /// padded with silence for it and the WAVs stay on the live timeline.
    private func systemWillSleep() {
        guard isCapturing else { return }
        isAsleep = true
        sleepStartedAt = now()
        log("system going to sleep — capture watchdogs paused", .audio)
    }

    /// Give both legs the first-buffer grace of a fresh start: devices rebind
    /// after wake. If the mic is still silent after it, the watchdog rebinds it.
    private func systemDidWake() {
        guard isCapturing else { return }
        let woke = now()
        let slept = sleepStartedAt.map { Int(woke.timeIntervalSince($0)) } ?? 0
        isAsleep = false
        sleepStartedAt = nil
        micInputStartedAt = woke
        systemWakeGraceUntil = woke.addingTimeInterval(systemAudioNoBufferThreshold)
        lastSystemAudioRecoveryAt = nil
        systemAudioRecoveryAttempts = 0
        log("system woke after \(slept)s — capture watchdogs resume after a grace period", .audio)
    }

    /// Session milliseconds of `date` on the transcript's clock.
    func sessionMs(_ date: Date) -> Int {
        Int(max(0, date.timeIntervalSince(captureStartWall ?? date) * 1000))
    }

    /// The capture gaps so far, merged; open ones still have no end.
    var captureGaps: [CaptureGap] { captureGapLog.gaps }

    /// The system capture failed (or works again). Drives the notice and
    /// the capture-gap record together, so neither can disagree.
    fileprivate func setSystemCaptureOutage(_ failed: Bool, since: Date?) {
        if failed {
            captureGapLog.begin(.system, .captureFailed, atMs: sessionMs(since ?? now()))
        } else {
            captureGapLog.end(.system, .captureFailed, atMs: sessionMs(now()))
        }
        systemAudioOutageReported = failed
    }

    fileprivate func recordFilledGap(leg: String, startFrame: Int, frames: Int, writeFailed: Bool) {
        let rate = AudioFormat.sampleRateHz
        let isSystem = leg == "system"
        let legStart = isSystem ? (systemLegStartMs ?? 0) : 0
        let startMs = legStart + startFrame * 1000 / rate
        captureGapLog.add(isSystem ? .system : .mic, writeFailed ? .writeFailed : .noAudio,
                          startMs: startMs, endMs: startMs + frames * 1000 / rate)
    }

    fileprivate func closeCaptureGaps() {
        guard isCapturing else { return }
        captureGapLog.closeAll(atMs: captureElapsedMs())
    }

    /// One notice for both legs while any leg's writes fail.
    fileprivate func writeDegradedChanged(leg: String, message: String?) {
        let wasDegraded = !degradedWriteLegs.isEmpty
        if let message {
            degradedWriteLegs[leg] = message
        } else {
            degradedWriteLegs.removeValue(forKey: leg)
        }
        let isDegraded = !degradedWriteLegs.isEmpty
        guard wasDegraded != isDegraded else { return }
        onRecordingNotice?(isDegraded ? Self.recordingWriteNotice : nil)
    }
}

/// Opened once the fallback backend replaced the tap, so the two never feed
/// the leg at once. Lock-guarded: read on the backend's queue.
private final class FallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    var isOpen: Bool { lock.withLock { opened } }
    func open() { lock.withLock { opened = true } }
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
