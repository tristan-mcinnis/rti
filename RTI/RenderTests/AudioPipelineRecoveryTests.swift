import AVFoundation
import RTICore
import XCTest

/// Synthetic PCM enters the production capture callback and real WAV writer.
/// No audio device, provider, keychain, application window, or live vault is used.
@MainActor
final class AudioPipelineRecoveryTests: XCTestCase {
    func testFinishSynchronouslyReportsCloseFailureBeforeUICallback() throws {
        let recorder = CloseFailureRecorder()
        let fixture = try Fixture(recorder: recorder)
        defer { fixture.cleanUp() }
        var errors: [String] = []
        fixture.pipeline.onError = { message, _ in errors.append(message) }
        try fixture.start()
        fixture.audio.emit(try pcm(value: 321))
        recorder.failNextClose = true
        fixture.pipeline.finalize()

        XCTAssertFalse(fixture.pipeline.finish(), "A queued UI error must not permit a successful save result")
        XCTAssertEqual(fixture.pipeline.recordingFailureMessage, CloseFailureRecorder.message)
        XCTAssertTrue(errors.isEmpty, "The MainActor callback is still queued, so the latch must carry the failure")
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL), Array(repeating: 321, count: 320))
        XCTAssertFalse(fixture.pipeline.finish(), "A later clean close must not erase the session's failure")
    }

    func testNewPrepareResetsRecordingFailureLatch() throws {
        let recorder = CloseFailureRecorder()
        let fixture = try Fixture(recorder: recorder)
        defer { fixture.cleanUp() }
        try fixture.start()
        fixture.audio.emit(try pcm(value: 111))
        recorder.failNextClose = true
        fixture.pipeline.finalize()
        XCTAssertFalse(fixture.pipeline.finish())

        try fixture.pipeline.prepare(recordingDirectory: fixture.directory.appendingPathComponent("next-session"))
        try fixture.pipeline.start()
        fixture.audio.emit(try pcm(value: 222))
        fixture.pipeline.finalize()
        XCTAssertTrue(fixture.pipeline.finish())
        XCTAssertNil(fixture.pipeline.recordingFailureMessage)
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL), Array(repeating: 222, count: 320))
    }

    func testProviderOutageRetainsEverySampleAndRebasesReconnect() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var fatalErrors: [String] = []
        var providerErrors: [String] = []
        var health: [TranscriptionHealth] = []
        var restarts: [Int] = []
        fixture.pipeline.onError = { message, _ in fatalErrors.append(message) }
        fixture.pipeline.onTranscriptionError = { message, _, channel in
            XCTAssertEqual(channel, "mic")
            providerErrors.append(message)
        }
        fixture.pipeline.onTranscriptionHealth = { health.append($0) }
        fixture.pipeline.onStreamRestarted = { channel, offset in
            XCTAssertEqual(channel, "mic")
            restarts.append(offset)
        }
        try fixture.start()
        fixture.clients[0].onStatus?(.live)
        fixture.audio.emit(try pcm(value: 1_000))
        fixture.clients[0].onStatus?(.reconnecting)
        fixture.clients[0].onError?(.transient(reason: "injected offline"), true)
        fixture.audio.emit(try pcm(value: 2_000))
        fixture.date = fixture.date.addingTimeInterval(12)
        // Exhausted retries require a new stream, as when the user applies
        // changed provider settings. Drive that production path too.
        fixture.pipeline.reconfigureStreamingClients()
        XCTAssertEqual(fixture.clients.count, 2)
        fixture.clients[1].onStatus?(.live)
        fixture.audio.emit(try pcm(value: 3_000))
        fixture.pipeline.finalize()
        fixture.pipeline.finish()

        XCTAssertTrue(fatalErrors.isEmpty, "Provider failures must not stop recording")
        XCTAssertEqual(providerErrors.count, 1)
        XCTAssertTrue(providerErrors[0].contains("Audio is still recording"))
        XCTAssertFalse(providerErrors[0].contains("reconnecting"))
        XCTAssertEqual(health, [.connecting, .live, .reconnecting, .failed, .connecting, .live])
        XCTAssertEqual(restarts, [12_000])
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL),
                       Array(repeating: 1_000, count: 320) + Array(repeating: 2_000, count: 320) + Array(repeating: 3_000, count: 320))
    }

    func testProviderRetryWhilePausedRetainsSilenceAndTruthfulStatus() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var message = ""
        fixture.pipeline.onTranscriptionError = { value, _, _ in message = value }
        try fixture.start()
        fixture.pipeline.suspended = true
        fixture.clients[0].onError?(.transient(reason: "injected while paused"), true)
        fixture.audio.emit(try pcm(value: 1_234))
        fixture.pipeline.reconfigureStreamingClients()
        XCTAssertTrue(fixture.pipeline.suspended, "Retry must not resume a paused recording")
        fixture.audio.emit(try pcm(value: 5_678))
        fixture.pipeline.finalize()
        XCTAssertTrue(fixture.pipeline.finish())
        XCTAssertTrue(message.contains("Recording remains paused"))
        XCTAssertFalse(message.contains("Audio is still recording"))
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL), Array(repeating: 0, count: 640))
    }

    func testAuthenticationFailureKeepsCaptureAndShowsFailedHealth() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var fatalErrors = 0
        var authError = false
        var health: TranscriptionHealth = .idle
        fixture.pipeline.onError = { _, _ in fatalErrors += 1 }
        fixture.pipeline.onTranscriptionError = { _, isAuth, channel in
            XCTAssertEqual(channel, "mic")
            authError = isAuth
        }
        fixture.pipeline.onTranscriptionHealth = { health = $0 }
        try fixture.start()
        fixture.audio.emit(try pcm(value: 10))
        fixture.clients[0].onError?(.auth, false)
        fixture.audio.emit(try pcm(value: 20))
        XCTAssertEqual(fixture.audio.stopCount, 0)
        XCTAssertEqual(fatalErrors, 0)
        XCTAssertTrue(authError)
        XCTAssertEqual(health, .failed)
        fixture.pipeline.finalize()
        fixture.pipeline.finish()
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL).count, 640)
    }

    func testDeviceRebindGetsFirstBufferGraceWithoutMovingSessionClock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var errors: [String] = []
        fixture.pipeline.onError = { message, _ in errors.append(message) }
        try fixture.start()
        fixture.audio.emit(try pcm(value: 123))
        fixture.date = fixture.date.addingTimeInterval(60)
        fixture.audio.lastBufferAge = nil
        fixture.audio.onRestarted?() // Same callback as AVAudioEngine device rebind.
        fixture.pipeline.checkMicHealth()
        XCTAssertTrue(errors.isEmpty, "A rebound input must be allowed to deliver its first buffer")
        fixture.audio.emit(try pcm(value: 456))
        fixture.pipeline.checkMicHealth()
        XCTAssertTrue(errors.isEmpty)
        fixture.pipeline.finalize()
        fixture.pipeline.finish()
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL),
                       Array(repeating: 123, count: 320) + Array(repeating: 456, count: 320))
    }

    func testDeviceStillMissingAfterGraceReportsOneFatalOutageAndKeepsPrefix() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var errors: [String] = []
        fixture.pipeline.onError = { message, _ in errors.append(message) }
        try fixture.start()
        fixture.audio.emit(try pcm(value: 789))
        fixture.date = fixture.date.addingTimeInterval(60)
        fixture.audio.lastBufferAge = nil
        fixture.audio.onRestarted?()
        fixture.date = fixture.date.addingTimeInterval(9)
        fixture.pipeline.checkMicHealth()
        fixture.pipeline.checkMicHealth()
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.contains("never delivered audio") == true)
        fixture.pipeline.finalize()
        fixture.pipeline.finish()
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL), Array(repeating: 789, count: 320))
    }

    func testSystemInterruptionRetainsBothLegsAndDoesNotClaimPrematureRecovery() async throws {
        let backend = InjectedSystemCapture()
        let fixture = try Fixture(system: backend)
        defer { fixture.cleanUp() }
        let started = expectation(description: "Injected system backend started")
        let connected = expectation(description: "System PCM opens its transcription client")
        let interrupted = expectation(description: "Backend error reaches MainActor health")
        fixture.pipeline.onSystemAudioStarted = { _ in started.fulfill() }
        var health: [TranscriptionHealth] = []
        fixture.pipeline.onSystemAudioHealth = {
            health.append($0)
            if $0 == .connecting { connected.fulfill() }
            if $0 == .failed, health.filter({ $0 == .failed }).count == 1 { interrupted.fulfill() }
        }
        var fatalErrors = 0
        fixture.pipeline.onError = { _, _ in fatalErrors += 1 }
        var providerFaultChannels: [String] = []
        fixture.pipeline.onTranscriptionError = { _, isAuth, channel in
            XCTAssertTrue(isAuth)
            providerFaultChannels.append(channel)
        }
        try fixture.start()
        await fulfillment(of: [started], timeout: 2)
        fixture.audio.emit(try pcm(value: 100))
        backend.onPCMBuffer?(try pcm(value: 200))
        await fulfillment(of: [connected], timeout: 2)
        fixture.clients[1].onStatus?(.live)
        await Self.emitBackendInterruption(backend)
        await fulfillment(of: [interrupted], timeout: 2)
        XCTAssertEqual(health.last, .failed)

        fixture.date = fixture.date.addingTimeInterval(35)
        backend.health = .init(duration: 1, audibleDuration: 1,
                               lastBufferAt: fixture.date.addingTimeInterval(-20),
                               lastAudibleBufferAt: fixture.date.addingTimeInterval(-20),
                               lastRMSLevel: 0.1, peakRMSLevel: 0.1)
        backend.recovers = true
        await fixture.pipeline.checkSystemAudioHealth()
        XCTAssertEqual(backend.recoveryCount, 1)
        XCTAssertEqual(health.last, .failed, "Reattaching a device is not proof that it delivers audio")
        fixture.clients[1].onStatus?(.reconnecting)
        XCTAssertEqual(health.last, .failed)
        backend.health = .init(duration: 2, audibleDuration: 2,
                               lastBufferAt: fixture.date, lastAudibleBufferAt: fixture.date,
                               lastRMSLevel: 0.1, peakRMSLevel: 0.1)
        await fixture.pipeline.checkSystemAudioHealth()
        XCTAssertEqual(health.last, .reconnecting, "Capture recovery must not mask an offline STT socket")
        fixture.clients[1].onStatus?(.live)
        XCTAssertEqual(health.last, .live)
        fixture.clients[1].onError?(.auth, true)
        XCTAssertEqual(providerFaultChannels, ["system"])
        XCTAssertEqual(health.last, .failed)
        fixture.audio.emit(try pcm(value: 300))
        backend.onPCMBuffer?(try pcm(value: 400))
        fixture.pipeline.finalize()
        fixture.pipeline.finish()
        XCTAssertEqual(fatalErrors, 0)
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL),
                       Array(repeating: 100, count: 320) + Array(repeating: 300, count: 320))
        XCTAssertEqual(try samples(fixture.pipeline.systemRecordingURL),
                       Array(repeating: 200, count: 320) + Array(repeating: 400, count: 320))
    }

    private func pcm(value: Int16) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AudioCaptureManager.targetFormat, frameCapacity: 320))
        buffer.frameLength = 320
        buffer.int16ChannelData![0].initialize(repeating: value, count: 320)
        return buffer
    }

    /// A nonisolated async function executes on the generic executor under
    /// Swift 6, as the real system-capture backend callback can.
    private nonisolated static func emitBackendInterruption(_ backend: InjectedSystemCapture) async {
        backend.onError?("injected device removed")
    }

    private func samples(_ url: URL?) throws -> [Int16] {
        let file = try AVAudioFile(forReading: XCTUnwrap(url), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let audio = InjectedMicrophoneCapture()
        var clients: [InjectedSTTClient] = []
        var date = Date(timeIntervalSinceReferenceDate: 1_000)
        var pipeline: AudioPipeline!

        init(system: InjectedSystemCapture? = nil, recorder: PipelineRecording = MeetingRecorder()) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("rti-pipeline-recovery-\(UUID().uuidString)")
            pipeline = AudioPipeline(audio: audio, hasSTTKey: { true }, makeSTTClient: { [unowned self] _, _ in
                let client = InjectedSTTClient()
                clients.append(client)
                return client
            }, makeSystemCapture: system.map { backend in { backend } },
               systemAudioEnabled: system != nil, systemAudioStartupDelayNs: 0,
               now: { [unowned self] in date }, log: { _, _ in }, recorder: recorder)
        }

        func start() throws {
            try pipeline.prepare(recordingDirectory: directory)
            try pipeline.start()
        }

        func cleanUp() {
            pipeline.abort()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Uses the production writer for real retained PCM. The injected failure is
/// delivered from close, exactly where a real fsync/header/close error surfaces.
private final class CloseFailureRecorder: PipelineRecording {
    static let message = "Injected durable audio close failure"
    private let writer = MeetingRecorder()
    var failNextClose = false
    var onWriteFailure: ((String) -> Void)? {
        didSet { writer.onWriteFailure = onWriteFailure }
    }
    var micURL: URL? { writer.micURL }
    var systemURL: URL? { writer.systemURL }
    func open(in directory: URL) throws { try writer.open(in: directory) }
    func appendMic(_ buffer: AVAudioPCMBuffer) { writer.appendMic(buffer) }
    func appendSystem(_ buffer: AVAudioPCMBuffer) { writer.appendSystem(buffer) }
    func appendMicSilence(matching buffer: AVAudioPCMBuffer) { writer.appendMicSilence(matching: buffer) }
    func appendSystemSilence(matching buffer: AVAudioPCMBuffer) { writer.appendSystemSilence(matching: buffer) }
    func close() {
        writer.close()
        if failNextClose {
            failNextClose = false
            onWriteFailure?(Self.message)
        }
    }
}

/// Lock guards callback storage and every mutable field. Tests invoke callbacks
/// on MainActor, matching the pipeline's existing callback isolation contract.
final class InjectedMicrophoneCapture: MicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var pcm: ((AVAudioPCMBuffer) -> Void)?
    private var restarted: (() -> Void)?
    private var muted = false
    private var age: TimeInterval?
    private var stops = 0
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { pcm } }
        set { lock.withLock { pcm = newValue } }
    }
    var onRestarted: (() -> Void)? {
        get { lock.withLock { restarted } }
        set { lock.withLock { restarted = newValue } }
    }
    var micMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }
    var lastBufferAge: TimeInterval? {
        get { lock.withLock { age } }
        set { lock.withLock { age = newValue } }
    }
    var stopCount: Int { lock.withLock { stops } }
    func start() throws {}
    func stop() { lock.withLock { stops += 1 } }
    func restart() throws { onRestarted?() }
    func secondsSinceLastBuffer() -> TimeInterval? { lastBufferAge }
    func secondsAllZero() -> TimeInterval? { nil }
    func emit(_ buffer: AVAudioPCMBuffer) {
        lastBufferAge = 0
        onPCMBuffer?(buffer)
    }
}

/// Lock guards all callback storage. No network request is made.
final class InjectedSTTClient: STTClient, @unchecked Sendable {
    private let lock = NSLock()
    private var words: (([SonioxWord]) -> Void)?
    private var error: ((SonioxFailure, Bool) -> Void)?
    private var status: ((TranscriptionHealth) -> Void)?
    var onWords: (([SonioxWord]) -> Void)? {
        get { lock.withLock { words } }
        set { lock.withLock { words = newValue } }
    }
    var onError: ((SonioxFailure, Bool) -> Void)? {
        get { lock.withLock { error } }
        set { lock.withLock { error = newValue } }
    }
    var onStatus: ((TranscriptionHealth) -> Void)? {
        get { lock.withLock { status } }
        set { lock.withLock { status = newValue } }
    }
    func connect() { onStatus?(.connecting) }
    func disconnect() {}
    func sendAudio(_ data: Data) {}
    func finalize() {}
}

/// Lock guards callbacks, health, and recovery counters. No system tap is opened.
final class InjectedSystemCapture: SystemAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var pcm: ((AVAudioPCMBuffer) -> Void)?
    private var error: ((String) -> Void)?
    private var currentHealth = SystemAudioCaptureHealth(duration: 0, audibleDuration: 0, lastBufferAt: nil,
                                                        lastAudibleBufferAt: nil, lastRMSLevel: 0, peakRMSLevel: 0)
    private var canRecover = false
    private var recoveries = 0
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { pcm } }
        set { lock.withLock { pcm = newValue } }
    }
    var onError: ((String) -> Void)? {
        get { lock.withLock { error } }
        set { lock.withLock { error = newValue } }
    }
    var health: SystemAudioCaptureHealth {
        get { lock.withLock { currentHealth } }
        set { lock.withLock { currentHealth = newValue } }
    }
    var recovers: Bool {
        get { lock.withLock { canRecover } }
        set { lock.withLock { canRecover = newValue } }
    }
    var recoveryCount: Int { lock.withLock { recoveries } }
    func start() async throws {}
    func stop() {}
    func captureHealth() -> SystemAudioCaptureHealth { health }
    func recoverFromSilentAudio() async -> Bool {
        lock.withLock { recoveries += 1; return canRecover }
    }
}
