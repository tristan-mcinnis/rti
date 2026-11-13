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
        try fixture.pipeline.start(micMuted: false)
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
        XCTAssertEqual(fixture.pipeline.reconfigureStreamingClients(), ["mic"])
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
        XCTAssertEqual(restarts, [0, 12_000], "Every mic .live re-bases, the first one too")
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
        XCTAssertEqual(fixture.pipeline.reconfigureStreamingClients(), ["mic"])
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

    /// A device still missing after its grace is degraded, not terminal: one
    /// notice, a rebind attempt, no session stop (AUD-1).
    func testDeviceStillMissingAfterGraceShowsOneNoticeRebindsAndKeepsPrefix() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var errors: [String] = []
        var notices: [String?] = []
        fixture.pipeline.onError = { message, _ in errors.append(message) }
        fixture.pipeline.onMicNotice = { notices.append($0) }
        try fixture.start()
        fixture.audio.emit(try pcm(value: 789))
        fixture.date = fixture.date.addingTimeInterval(60)
        fixture.audio.lastBufferAge = nil
        fixture.audio.onRestarted?()
        fixture.date = fixture.date.addingTimeInterval(9)
        fixture.pipeline.checkMicHealth()
        fixture.pipeline.checkMicHealth()
        XCTAssertTrue(errors.isEmpty, "A missing mic must not stop the session")
        XCTAssertEqual(notices, [AudioPipeline.micLostNotice])
        XCTAssertEqual(fixture.audio.restartCount, 1)
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

    func testGuideFinishFreezesTheGracePeriodTranscriptBeforeAwaitingTheProvider() async throws {
        let fixture = try Fixture(system: InjectedSystemCapture())
        defer { fixture.cleanUp() }
        let systemReady = expectation(description: "System backend ready")
        fixture.pipeline.onSystemAudioStarted = { _ in systemReady.fulfill() }
        try fixture.start()
        await fulfillment(of: [systemReady], timeout: 2)

        var transcript: [LiveEntry] = []
        fixture.pipeline.onSystemWords = { words in
            for word in words {
                transcript.append(RenderFixtures.liveEntry("remote_1", word.text, word.startMs))
            }
        }
        let client = try XCTUnwrap(fixture.clients.last)
        fixture.pipeline.finalize()
        client.onWords?([testWord])
        XCTAssertEqual(transcript.count, 1, "The final word arrived during Soniox's grace period")

        let guideURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/GuideFixtures/dg-questions.json")
        let document = try GuideDocument.parse(Data(contentsOf: guideURL))
        let admission = LLMAdmissionController()
        let request = LLMRequest(collectStream: { _, _, _, _ in
            let reply = """
            {"evidence":[],"cells":[{"qid":"S1Q1","coverage":"Answered","summary":"One answer.","turns":["remote_1@0"],
            "quotes":[{"turn":"remote_1@0","english":"Fixture word"}],"votes":[]}]}
            """
            return LLMClient.CollectedResponse(text: reply, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: admission)
        let guide = GuideSessionController(request: request)
        guide.start(sessionID: "grace", guide: document, guideURL: guideURL, group: "G1", roster: [], rosterURL: nil)
        let held = await admission.acquireForeground()
        let close = Task { @MainActor in
            await SessionCoordinator.closeCapture(fixture.pipeline, guide: guide, sessionID: "grace", transcript: { transcript })
        }
        for _ in 0..<1000 {
            if guide.isGenerating { break }
            await Task.yield()
        }
        XCTAssertTrue(guide.isGenerating)
        client.onWords?([testWord])
        XCTAssertEqual(transcript.count, 1, "A delayed packet cannot enter the archive while Guide awaits the provider")
        await admission.releaseForeground(held)
        let audioClosed = await close.value
        XCTAssertTrue(audioClosed)
        XCTAssertEqual(guide.snapshot(for: "grace")?.extraction.cells[0].quotes.map(\.original), ["Fixture word"])
        XCTAssertEqual(guide.snapshot(for: "grace")?.extraction.captureIncomplete, false)
    }

    func testReplacedAndFinishedClientsCannotDeliverButCurrentFinalsCan() async throws {
        let backend = InjectedSystemCapture()
        let fixture = try Fixture(system: backend)
        defer { fixture.cleanUp() }
        let started = expectation(description: "System backend ready")
        fixture.pipeline.onSystemAudioStarted = { _ in started.fulfill() }
        try fixture.start()
        await fulfillment(of: [started], timeout: 2)
        let old = fixture.clients
        XCTAssertEqual(old.count, 2)
        let retiredCallbacks = old.map { ($0.onWords, $0.onStatus, $0.onError) }
        old.forEach { $0.emitOnDisconnect = true }
        var replacementErrors = 0
        fixture.pipeline.onTranscriptionError = { _, _, _ in replacementErrors += 1 }
        XCTAssertEqual(fixture.pipeline.reconfigureStreamingClients(), ["mic"], "No system PCM, so no system socket to restart")
        XCTAssertEqual(replacementErrors, 0, "Replacement retires synchronous teardown errors")
        let current = Array(fixture.clients.suffix(2))
        var deliveries = 0
        var received: [String] = []
        fixture.pipeline.onWords = { words in deliveries += 1; received += words.map(\.text) }
        fixture.pipeline.onSystemWords = { words in deliveries += 1; received += words.map(\.text) }
        fixture.pipeline.onTranscriptionError = { _, _, _ in deliveries += 1 }
        fixture.pipeline.onTranscriptionHealth = { _ in deliveries += 1 }
        fixture.pipeline.onSystemAudioHealth = { _ in deliveries += 1 }
        fixture.pipeline.onStreamRestarted = { _, _ in deliveries += 1 }
        for (words, status, error) in retiredCallbacks {
            words?([testWord])
            status?(.live)
            error?(.auth, true)
        }
        XCTAssertEqual(deliveries, 0, "Retired clients cannot change transcript, health, errors or timeline")
        fixture.pipeline.finalize()
        current[0].onWords?([testWord])
        current[1].onWords?([testWord])
        XCTAssertEqual(deliveries, 2, "Current clients remain admitted during final-word flush")
        XCTAssertEqual(received, ["Fixture word", "Fixture word"])
        deliveries = 0
        current.forEach { $0.emitOnDisconnect = true }
        fixture.pipeline.finish()
        XCTAssertEqual(deliveries, 0, "Even synchronous disconnect callbacks must be retired first")
        for client in current {
            client.onWords?([testWord])
            client.onStatus?(.live)
            client.onError?(.auth, true)
        }
        XCTAssertEqual(deliveries, 0, "Finished clients cannot mutate the archived session's live projection")
    }

    func testSpentMicRetriesReconnectOncePerBudgetAfterThePause() async throws {
        let fixture = try Fixture(micAutoReconnectDelayNs: 50_000_000)
        defer { fixture.cleanUp() }
        var restarts: [String] = []
        fixture.pipeline.onStreamRestarted = { channel, _ in restarts.append(channel) }
        try fixture.start()
        fixture.clients[0].onStatus?(.live)
        fixture.clients[0].onError?(.transient(reason: "injected offline"), true)
        XCTAssertEqual(fixture.clients.count, 1, "The reconnect waits for the pause")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture.clients.count, 2, "One fresh mic client after the pause")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture.clients.count, 2, "Exactly one reconnect per spent budget")
        fixture.clients[1].onStatus?(.live)
        XCTAssertEqual(restarts, ["mic", "mic"], "The new mic stream re-bases only the mic leg")
    }

    func testMicAutoReconnectPauseDoublesUpToTheCap() {
        let base: UInt64 = 45_000_000_000
        let delays = (0 ..< 6).map { AudioPipeline.micAutoReconnectDelay(baseNs: base, attempt: $0) }
        XCTAssertEqual(delays, [base, base * 2, base * 4, base * 8, base * 8, base * 8],
                       "A long outage backs off to 6 min instead of flapping every 45 s")
    }

    func testMicThatNeverOpenedRebasesOnTheAutoReconnectLive() async throws {
        let fixture = try Fixture(micAutoReconnectDelayNs: 50_000_000)
        defer { fixture.cleanUp() }
        let transcript = TranscriptPipeline()
        fixture.pipeline.onStreamRestarted = { transcript.restartStream(channel: $0, atMs: $1) }
        fixture.pipeline.onWords = { _ = transcript.process(words: $0, channel: "mic") }
        try fixture.start()
        // The first client spends its retries with the network down and
        // never reports `.live`.
        fixture.clients[0].onError?(.transient(reason: "injected offline"), true)
        fixture.date = fixture.date.addingTimeInterval(76)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture.clients.count, 2, "The automatic reconnect opened a fresh mic client")
        fixture.clients[1].onStatus?(.live)
        fixture.clients[1].onWords?([testWord])
        let word = try XCTUnwrap(transcript.liveEntries.first)
        XCTAssertGreaterThanOrEqual(word.startMs, 76_000, "Stream time 0 is the reconnect's .live, not capture start")
    }

    func testAuthClientBugAndStopNeverAutoReconnectTheMic() async throws {
        for failure in [SonioxFailure.auth, .clientBug("injected 400")] {
            let fixture = try Fixture(micAutoReconnectDelayNs: 50_000_000)
            defer { fixture.cleanUp() }
            try fixture.start()
            fixture.clients[0].onError?(failure, true)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(fixture.clients.count, 1, "\(failure) must never auto-retry")
        }
        let stopped = try Fixture(micAutoReconnectDelayNs: 50_000_000)
        defer { stopped.cleanUp() }
        try stopped.start()
        stopped.clients[0].onError?(.transient(reason: "injected offline"), true)
        stopped.pipeline.finalize()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(stopped.clients.count, 1, "Stop cancels the pending reconnect")

        let healed = try Fixture(micAutoReconnectDelayNs: 50_000_000)
        defer { healed.cleanUp() }
        try healed.start()
        healed.clients[0].onError?(.transient(reason: "injected offline"), true)
        healed.clients[0].onStatus?(.live)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(healed.clients.count, 1, ".live cancels the pending reconnect")
    }

    func testFirstSystemStreamRebasesOnItsOwnLiveAndKeepsTheRecordingOffset() async throws {
        let backend = InjectedSystemCapture()
        let fixture = try Fixture(system: backend)
        defer { fixture.cleanUp() }
        let transcript = TranscriptPipeline()
        var recordingOffsets: [Int] = []
        let started = expectation(description: "System backend started")
        let connecting = expectation(description: "First system buffer opens the socket")
        fixture.pipeline.onSystemAudioStarted = { offset in
            recordingOffsets.append(offset)
            transcript.setSystemStartOffset(ms: offset)
            started.fulfill()
        }
        fixture.pipeline.onStreamRestarted = { transcript.restartStream(channel: $0, atMs: $1) }
        fixture.pipeline.onSystemWords = { transcript.process(words: $0, channel: "system") }
        fixture.pipeline.onSystemAudioHealth = { if $0 == .connecting { connecting.fulfill() } }
        try fixture.start()
        await fulfillment(of: [started], timeout: 2)
        fixture.date = fixture.date.addingTimeInterval(10)
        backend.onPCMBuffer?(try pcm(value: 7))
        await fulfillment(of: [connecting], timeout: 2)
        let system = try XCTUnwrap(fixture.clients.last)
        system.onStatus?(.live)
        system.onWords?([testWord])
        let word = try XCTUnwrap(transcript.liveEntries.first)
        XCTAssertGreaterThanOrEqual(word.startMs, 10_000, "Stream time 0 is the socket's .live, not the backend start")
        XCTAssertEqual(recordingOffsets, [0], "The WAV and upgrade offset does not move")
    }

    /// NET-3: the system leg spends its 5 retries while the tap keeps
    /// delivering buffers (so the idle park never re-arms it). It must come
    /// back on its own, as the mic does, and the notice must say the other
    /// side's audio is still recorded.
    func testSpentSystemRetriesReconnectWhileTheTapKeepsDelivering() async throws {
        let backend = InjectedSystemCapture()
        let fixture = try Fixture(system: backend, micAutoReconnectDelayNs: 100_000_000)
        defer { fixture.cleanUp() }
        var health: [TranscriptionHealth] = []
        var restarts: [String] = []
        var errors: [String] = []
        let started = expectation(description: "System backend started")
        fixture.pipeline.onSystemAudioStarted = { _ in started.fulfill() }
        fixture.pipeline.onSystemAudioHealth = { health.append($0) }
        fixture.pipeline.onStreamRestarted = { channel, _ in restarts.append(channel) }
        fixture.pipeline.onTranscriptionError = { message, _, channel in if channel == "system" { errors.append(message) } }
        try fixture.start()
        await fulfillment(of: [started], timeout: 2)
        try await feedSystem(backend, for: 0.1)
        XCTAssertEqual(fixture.clients.count, 2, "mic, then the system client")
        let first = fixture.clients[1]
        first.onStatus?(.live)
        // What SonioxClient reports when its retry budget is spent.
        first.onStatus?(.failed)
        first.onError?(.transient(reason: "injected network flap"), true)
        // The tap keeps delivering (silent) buffers through and past the pause.
        try await feedSystem(backend, for: 0.6)
        XCTAssertEqual(fixture.clients.count, 3, "One fresh system client after the pause")
        let second = fixture.clients[2]
        XCTAssertEqual(health.last, .connecting, "The next buffer connected the fresh client")
        second.onStatus?(.live)
        XCTAssertEqual(health.last, .live)
        XCTAssertEqual(restarts.filter { $0 == "system" }.count, 2, "The new system stream re-bases on its own .live")
        XCTAssertFalse(fixture.pipeline.systemAudioOutageReported, "Only the transcript failed; capture did not")
        XCTAssertTrue(errors.last?.contains("Audio is still recording") == true)
        XCTAssertTrue(SessionCoordinator.systemTranscriptLostNotice.contains("still being recorded"))
        XCTAssertTrue(SessionCoordinator.systemTranscriptLostNotice.contains("Do not restart"))
        XCTAssertFalse(SessionCoordinator.systemTranscriptLostNotice.contains("unavailable"))
        fixture.pipeline.finalize()
        XCTAssertTrue(fixture.pipeline.finish())
        XCTAssertGreaterThan(try samples(fixture.pipeline.systemRecordingURL).count, 320 * 20,
                             "The system WAV kept the buffers from before, during and after the outage")
    }

    func testSystemAuthFailureOrStopNeverAutoReconnectsTheSystemLeg() async throws {
        for failure in [SonioxFailure.auth, .clientBug("injected 400")] {
            let backend = InjectedSystemCapture()
            let fixture = try Fixture(system: backend, micAutoReconnectDelayNs: 50_000_000)
            defer { fixture.cleanUp() }
            let started = expectation(description: "System backend started")
            fixture.pipeline.onSystemAudioStarted = { _ in started.fulfill() }
            try fixture.start()
            await fulfillment(of: [started], timeout: 2)
            try await feedSystem(backend, for: 0.1)
            fixture.clients[1].onError?(failure, true)
            try await feedSystem(backend, for: 0.4)
            XCTAssertEqual(fixture.clients.count, 2, "\(failure) must never auto-retry (a 401 loop)")
        }
        let backend = InjectedSystemCapture()
        let stopped = try Fixture(system: backend, micAutoReconnectDelayNs: 50_000_000)
        defer { stopped.cleanUp() }
        let started = expectation(description: "System backend started")
        stopped.pipeline.onSystemAudioStarted = { _ in started.fulfill() }
        try stopped.start()
        await fulfillment(of: [started], timeout: 2)
        try await feedSystem(backend, for: 0.1)
        stopped.clients[1].onError?(.transient(reason: "injected offline"), true)
        stopped.pipeline.finalize()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(stopped.clients.count, 2, "Stop cancels the pending system reconnect")
    }

    /// Push a quiet system buffer every 20 ms, keeping the leg's last-buffer
    /// time fresh so the idle park cannot fire.
    private func feedSystem(_ backend: InjectedSystemCapture, for seconds: TimeInterval) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            backend.onPCMBuffer?(try pcm(value: 3))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A listening-only call is muted before capture opens: the first buffer,
    /// delivered while `start()` runs, and every later one reach neither the
    /// WAV nor the transcription socket as speech.
    func testListeningOnlyStartNeverDeliversAMicSample() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.audio.bufferOnStart = try pcm(value: 4_000)
        try fixture.start(micMuted: true)
        fixture.audio.emit(try pcm(value: 5_000))
        fixture.pipeline.finalize()
        XCTAssertTrue(fixture.pipeline.finish())

        let sent = try XCTUnwrap(fixture.clients.first).sentAudio
        XCTAssertEqual(sent.count, 2, "The stream keeps its cadence with silence")
        XCTAssertTrue(sent.allSatisfy { $0.allSatisfy { $0 == 0 } }, "No mic sample reaches transcription")
        XCTAssertEqual(try samples(fixture.pipeline.micRecordingURL), Array(repeating: 0, count: 640),
                       "No mic sample reaches the WAV")
    }

    func testReconfigureWithoutAKeyRestartsNoLeg() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.start()
        fixture.hasKey = false
        XCTAssertEqual(fixture.pipeline.reconfigureStreamingClients(), [], "Nothing reconnects, so nothing shows switching")
        XCTAssertEqual(fixture.clients.count, 1)
    }

    func testAbortedClientCannotMutateNextCapture() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.start()
        let old = fixture.clients[0]
        fixture.pipeline.abort()
        try fixture.pipeline.prepare(recordingDirectory: fixture.directory.appendingPathComponent("next"))
        try fixture.pipeline.start(micMuted: false)
        var deliveries = 0
        fixture.pipeline.onWords = { _ in deliveries += 1 }
        fixture.pipeline.onTranscriptionHealth = { _ in deliveries += 1 }
        fixture.pipeline.onTranscriptionError = { _, _, _ in deliveries += 1 }
        old.onWords?([testWord])
        old.onStatus?(.live)
        old.onError?(.auth, true)
        XCTAssertEqual(deliveries, 0)
        fixture.clients[1].onWords?([testWord])
        XCTAssertEqual(deliveries, 1)
    }

    private var testWord: SonioxWord {
        SonioxWord(text: "Fixture word", startMs: 0, endMs: 100, speaker: 1,
                   confidence: 1, isFinal: true, translationStatus: "none",
                   language: nil, sourceLanguage: nil)
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
        var hasKey = true
        var pipeline: AudioPipeline!

        init(system: InjectedSystemCapture? = nil, recorder: PipelineRecording = MeetingRecorder(),
             micAutoReconnectDelayNs: UInt64 = 45_000_000_000) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("rti-pipeline-recovery-\(UUID().uuidString)")
            pipeline = AudioPipeline(audio: audio, hasSTTKey: { [unowned self] in hasKey }, makeSTTClient: { [unowned self] _, _, _ in
                let client = InjectedSTTClient()
                clients.append(client)
                return client
            }, makeSystemCapture: system.map { backend in { backend } },
               systemAudioEnabled: system != nil, systemAudioStartupDelayNs: 0,
               micAutoReconnectDelayNs: micAutoReconnectDelayNs,
               now: { [unowned self] in date }, log: { _, _ in }, recorder: recorder)
        }

        func start(micMuted: Bool = false) throws {
            try pipeline.prepare(recordingDirectory: directory)
            try pipeline.start(micMuted: micMuted)
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
    var onWriteDegraded: ((String, String?) -> Void)? {
        didSet { writer.onWriteDegraded = onWriteDegraded }
    }
    var onGapFilled: ((String, Int, Int, Bool) -> Void)? {
        didSet { writer.onGapFilled = onGapFilled }
    }
    var micURL: URL? { writer.micURL }
    var systemURL: URL? { writer.systemURL }
    func open(in directory: URL) throws { try writer.open(in: directory) }
    func appendMic(_ buffer: AVAudioPCMBuffer) { writer.appendMic(buffer) }
    func appendSystem(_ buffer: AVAudioPCMBuffer) { writer.appendSystem(buffer) }
    func appendMicSilence(matching buffer: AVAudioPCMBuffer) { writer.appendMicSilence(matching: buffer) }
    func appendSystemSilence(matching buffer: AVAudioPCMBuffer) { writer.appendSystemSilence(matching: buffer) }
    func markMicStarted() { writer.markMicStarted() }
    func markSystemStarted() { writer.markSystemStarted() }
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
    /// Delivered from inside `start()`, as a real tap can deliver its first
    /// buffer before `start()` returns.
    var bufferOnStart: AVAudioPCMBuffer? {
        get { lock.withLock { startBuffer } }
        set { lock.withLock { startBuffer = newValue } }
    }
    private var startBuffer: AVAudioPCMBuffer?
    func start() throws {
        if let buffer = bufferOnStart { emit(buffer) }
    }
    func stop() { lock.withLock { stops += 1 } }
    private var restarts = 0
    private var failure: Error?
    var restartCount: Int { lock.withLock { restarts } }
    /// When set, `restart()` fails as AVAudioEngine does mid-switch.
    var restartError: Error? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    /// Like the real engine: a restart clears the last-buffer time, and only
    /// a successful one reports `onRestarted`.
    func restart() throws {
        lock.withLock { restarts += 1 }
        lastBufferAge = nil
        if let restartError { throw restartError }
        onRestarted?()
    }
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
    private var disconnectEmits = false
    var emitOnDisconnect: Bool {
        get { lock.withLock { disconnectEmits } }
        set { lock.withLock { disconnectEmits = newValue } }
    }
    func disconnect() {
        if emitOnDisconnect {
            onStatus?(.failed)
            onError?(.auth, true)
        }
    }
    private var sent: [Data] = []
    var sentAudio: [Data] { lock.withLock { sent } }
    func sendAudio(_ data: Data) { lock.withLock { sent.append(data) } }
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
    private var stops = 0
    private var starts = 0
    private var startFailure: Error?
    private var isTap = false
    var stopCount: Int { lock.withLock { stops } }
    var startCount: Int { lock.withLock { starts } }
    var startError: Error? {
        get { lock.withLock { startFailure } }
        set { lock.withLock { startFailure = newValue } }
    }
    /// Plays the CoreAudio process tap, which may fall back to ScreenCaptureKit.
    var fallsBackToScreenCapture: Bool {
        get { lock.withLock { isTap } }
        set { lock.withLock { isTap = newValue } }
    }
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
    func start() async throws {
        lock.withLock { starts += 1 }
        if let startError { throw startError }
    }
    func stop() { lock.withLock { stops += 1 } }
    func captureHealth() -> SystemAudioCaptureHealth { health }
    func recoverFromSilentAudio() async -> Bool {
        lock.withLock { recoveries += 1; return canRecover }
    }
}
