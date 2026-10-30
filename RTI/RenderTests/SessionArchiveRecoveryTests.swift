import Foundation
import RTICore
import XCTest

/// Exercises the real finalizer/archive and restart-discovery path using only
/// invented text and PCM in a private temporary vault. No capture or provider.
@MainActor
final class SessionArchiveRecoveryTests: XCTestCase {
    private var root: URL!
    private var savedConfigHome: String?
    private let startedAt = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() async throws {
        try await super.setUp()
        savedConfigHome = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-archive-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [
            "sessions_dir": root.appendingPathComponent("sessions").path,
            "recordings_dir": root.appendingPathComponent("databases/meetings/recordings").path,
            "transcripts_dir": root.appendingPathComponent("transcripts-raw").path,
        ])
        try data.write(to: config.appendingPathComponent("config.json"))
        setenv("RTI_CONFIG_HOME", config.path, 1)
    }

    override func tearDown() async throws {
        if let savedConfigHome {
            setenv("RTI_CONFIG_HOME", savedConfigHome, 1)
        } else {
            unsetenv("RTI_CONFIG_HOME")
        }
        if let root { try FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    func testFinalizerWritesReadableTranscriptAndExactRetainedAudio() throws {
        let source = root.appendingPathComponent("mic.wav")
        let audio = pcmWAV(sample: 127)
        try audio.write(to: source)
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Invented checkpoint words")], chat: [], visualContext: [], notes: [],
            sessionId: "invented-session", micRecordingURL: source, systemRecordingURL: nil,
            systemAudioStartOffsetMs: nil, workstreamItem: nil, modeName: nil
        )
        let directory = try XCTUnwrap(SessionFinalizer(snapshot: snapshot).archive())
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8).contains("Invented checkpoint words"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("audio-mic.wav")), audio)
        let metadata = try JSONDecoder().decode(SessionArchiveMetadata.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        XCTAssertEqual(metadata.sessionId, "invented-session")
        XCTAssertEqual(metadata.micAudioFile, "audio-mic.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testBlockedTranscriptWriteReportsFailureAndKeepsRetainedAudio() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("transcript.md"), withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("audio-mic.wav")
        let audio = pcmWAV(sample: 39)
        try audio.write(to: audioURL)
        XCTAssertNil(archive(transcript: [entry("Cannot be saved")], mic: audioURL))
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
    }

    func testFailedMetadataWriteKeepsReadableCheckpoint() throws {
        let directory = try XCTUnwrap(archive(transcript: [entry("Durable earlier checkpoint")]))
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        // A destination collision fails deterministically without filling a disk
        // or relying on permissions (which privileged test runners may bypass).
        let metadata = directory.appendingPathComponent("session.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        XCTAssertNil(archive(transcript: [entry("Durable earlier checkpoint plus later words")]))
        XCTAssertTrue(try String(contentsOf: transcriptURL, encoding: .utf8).contains("Durable earlier checkpoint"))
    }

    func testAudioCollisionPreservesBothEarlierArtifactAndNewSource() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        let destination = directory.appendingPathComponent("audio-mic.wav")
        let source = root.appendingPathComponent("different-mic.wav")
        let earlier = pcmWAV(sample: 12)
        let incoming = pcmWAV(sample: 76)
        try earlier.write(to: destination)
        try incoming.write(to: source)
        XCTAssertNil(archive(transcript: [entry("Collision")], mic: source))
        XCTAssertEqual(try Data(contentsOf: destination), earlier)
        XCTAssertEqual(try Data(contentsOf: source), incoming)
    }

    func testMissingExpectedAudioReportsFailure() throws {
        XCTAssertNil(archive(transcript: [entry("Audio missing")], mic: root.appendingPathComponent("missing.wav")))
    }

    func testRecoverySeedAndMarkerReportBlockedWrites() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        let transcript = directory.appendingPathComponent("transcript.md")
        let marker = directory.appendingPathComponent("automatic-upgrade.pending")
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        XCTAssertFalse(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        XCTAssertFalse(SessionArchive.markAutomaticUpgradePending(in: directory))
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.removeItem(at: marker)
        XCTAssertTrue(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        XCTAssertTrue(SessionArchive.markAutomaticUpgradePending(in: directory))
    }

    func testAUserNoteBeforeSpeechIsKeptRatherThanReportingAnEmptySave() throws {
        let note = LiveEntry(speakerId: "note", text: "Invented note before speech", startMs: 0, confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)
        let directory = try XCTUnwrap(archive(transcript: [note]))
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8).contains(note.text))
    }

    func testFailedCanonicalWritesReturnNoSuccessURL() throws {
        let earlier = try XCTUnwrap(SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt, transcript: [entry("Earlier export")], chat: [], visualContext: [], notes: [], archiveDir: nil
        ))
        try FileManager.default.removeItem(at: earlier.transcriptURL)
        try FileManager.default.createDirectory(at: earlier.transcriptURL, withIntermediateDirectories: true)
        XCTAssertNil(SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt, transcript: [entry("Blocked export")], chat: [], visualContext: [], notes: [], archiveDir: nil
        ))
        let sidecar = try XCTUnwrap(earlier.sidecarURL)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        XCTAssertNil(SessionArchive.writeCanonicalMeetingSidecar(
            startedAt: startedAt, chat: [], visualContext: [], notes: [], archiveDir: nil
        ))
    }

    func testCanonicalExportReportsFailureWhenItsSidecarCannotBeSaved() throws {
        let earlier = try XCTUnwrap(SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt, transcript: [entry("Earlier export")], chat: [], visualContext: [], notes: [], archiveDir: nil
        ))
        let sidecar = try XCTUnwrap(earlier.sidecarURL)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        XCTAssertNil(SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt, transcript: [entry("New export")], chat: [], visualContext: [], notes: [], archiveDir: nil
        ))
        XCTAssertTrue(try String(contentsOf: earlier.transcriptURL, encoding: .utf8).contains("New export"), "A partial archive failure does not delete the successfully written transcript")
    }

    func testAbruptCheckpointIsDiscoveredFromDiskAndRetryMarkerPersists() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt)
        SessionArchive.markAutomaticUpgradePending(in: directory)
        let audioURL = directory.appendingPathComponent("audio-mic.wav")
        let audio = pcmWAV(sample: 54)
        try audio.write(to: audioURL)
        let systemURL = directory.appendingPathComponent("audio-system.wav")
        let systemAudio = pcmWAV(sample: 83)
        try systemAudio.write(to: systemURL)
        // The running recorder owns the audio; the five-minute checkpoint
        // intentionally passes no audio URL. No clean shutdown follows it.
        XCTAssertNotNil(SessionArchive.write(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Words before abrupt termination")], chat: [],
            sessionId: "invented-session", systemAudioStartOffsetMs: 2_500
        ))
        let listed = SessionArchive.recentSessions(limit: .max)
        XCTAssertEqual(listed.count, 1)
        let listedSession = try XCTUnwrap(listed.first)
        XCTAssertEqual(identity(listedSession.url), identity(directory))
        XCTAssertNotNil(listedSession.date, "The written folder stamp must parse on restart: \(listedSession.url.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: listedSession.url.appendingPathComponent("automatic-upgrade.pending").path))
        XCTAssertEqual(TranscriptUpgradeAudioDiscovery.inputs(in: listedSession.url).count, 2)
        let pending = SessionArchive.pendingAutomaticUpgrades()
        XCTAssertEqual(pending.count, 1, "A seeded checkpoint with retained audio must be queued on restart")
        let recovered = try XCTUnwrap(pending.first)
        XCTAssertEqual(identity(recovered.url), identity(directory))
        XCTAssertTrue(try String(contentsOf: recovered.transcriptURL, encoding: .utf8).contains("Words before abrupt termination"))
        let inputs = TranscriptUpgradeAudioDiscovery.inputs(in: recovered.url)
        XCTAssertEqual(inputs.map { identity($0.url) }, [identity(audioURL), identity(systemURL)])
        XCTAssertEqual(inputs.map(\.offsetMs), [0, 2_500])
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        XCTAssertEqual(try Data(contentsOf: systemURL), systemAudio)
        XCTAssertTrue(SessionArchive.pendingAutomaticUpgrades().contains { identity($0.url) == identity(directory) }, "A failed or interrupted retry must remain discoverable")
        SessionArchive.clearAutomaticUpgradePending(in: directory)
        XCTAssertFalse(SessionArchive.pendingAutomaticUpgrades().contains { identity($0.url) == identity(directory) })
    }

    func testRecoveryDoesNotDropPendingSessionsBehindRecentTwoHundred() throws {
        let old = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        SessionArchive.seedTranscriptForAutomaticUpgrade(in: old, startedAt: startedAt)
        SessionArchive.markAutomaticUpgradePending(in: old)
        try pcmWAV(sample: 21).write(to: old.appendingPathComponent("audio-mic.wav"))
        for index in 1...201 {
            _ = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt.addingTimeInterval(Double(index * 60))))
        }
        XCTAssertEqual(SessionArchive.recentSessions(limit: 200).count, 200)
        let listed = SessionArchive.recentSessions(limit: .max)
        XCTAssertEqual(listed.count, 202)
        let oldSession = try XCTUnwrap(listed.first { identity($0.url) == identity(old) }, "The full archive scan must contain the older session")
        XCTAssertNotNil(oldSession.date, "The older folder stamp must parse on restart")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSession.url.appendingPathComponent("automatic-upgrade.pending").path))
        XCTAssertEqual(TranscriptUpgradeAudioDiscovery.inputs(in: oldSession.url).count, 1)
        XCTAssertTrue(SessionArchive.pendingAutomaticUpgrades().contains { identity($0.url) == identity(old) })
    }

    func testKnownRecordingFailurePersistsAndBlocksAutomaticProcessing() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        XCTAssertTrue(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        XCTAssertTrue(SessionArchive.markAutomaticUpgradePending(in: directory))
        let audioURL = directory.appendingPathComponent("audio-mic.wav")
        let audio = pcmWAV(sample: 31)
        try audio.write(to: audioURL)
        let saved = SessionArchive.write(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Known incomplete capture")], chat: [], sessionId: "needs-review",
            micRecordingURL: audioURL, recordingError: "Injected synchronize failure"
        )
        XCTAssertNotNil(saved)
        XCTAssertEqual(SessionArchive.recordingError(in: directory), "Injected synchronize failure")
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        let session = try XCTUnwrap(SessionArchive.recentSessions().first {
            $0.url.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
        })
        let row = SessionsWindowModel.makeRow(session, titleMap: .empty, databases: nil)
        XCTAssertEqual(row.recordingError, "Injected synchronize failure")
        XCTAssertEqual(row.transcriptStatus, "Recording needs review")
        XCTAssertFalse(SessionArchive.pendingAutomaticUpgrades().contains {
            $0.url.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("automatic-upgrade.pending").path))
    }

    func testRecordingFailureUnqueuesAutomaticWorkEvenWhenArchiveWriteAlsoFails() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        XCTAssertTrue(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        XCTAssertTrue(SessionArchive.markAutomaticUpgradePending(in: directory))
        let audioURL = directory.appendingPathComponent("audio-mic.wav")
        let audio = pcmWAV(sample: 47)
        try audio.write(to: audioURL)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("transcript.md"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("transcript.md"), withIntermediateDirectories: true)
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Incomplete recording")], chat: [], visualContext: [], notes: [],
            sessionId: "manual-review", micRecordingURL: audioURL, systemRecordingURL: nil,
            systemAudioStartOffsetMs: nil, workstreamItem: nil, modeName: nil,
            recordingError: "Injected close failure"
        )
        XCTAssertNil(SessionFinalizer(snapshot: snapshot).archive())
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("automatic-upgrade.pending").path))
        XCTAssertFalse(SessionArchive.pendingAutomaticUpgrades().contains {
            $0.url.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
        })
    }

    private func archive(transcript: [LiveEntry], mic: URL? = nil) -> URL? {
        SessionArchive.write(startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60), transcript: transcript, chat: [], sessionId: "invented-session", micRecordingURL: mic)
    }

    private func entry(_ text: String) -> LiveEntry {
        LiveEntry(speakerId: "self", text: text, startMs: 0, confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)
    }

    private func identity(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func pcmWAV(sample: Int16) -> Data {
        let sampleCount: UInt32 = 160
        var data = Data()
        func bytes<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); bytes(UInt32(36) + sampleCount * 2)
        data.append(Data("WAVEfmt ".utf8)); bytes(UInt32(16))
        bytes(UInt16(1)); bytes(UInt16(1)); bytes(UInt32(16_000)); bytes(UInt32(32_000))
        bytes(UInt16(2)); bytes(UInt16(16)); data.append(Data("data".utf8)); bytes(sampleCount * 2)
        for _ in 0..<sampleCount { bytes(sample) }
        return data
    }
}
