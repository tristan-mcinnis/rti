import XCTest
import RTICore

final class VaultPathsTests: XCTestCase {
    func testBetaStorageKeepsAllWritableRootsInItsOwnProfile() throws {
        let fm = FileManager.default
        let profile = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: profile) }
        try RTIBuildProfile.prepareBetaStorage(at: profile)
        let config = RTIBuildProfile.betaStorageConfig(at: profile)
        for key in ["sessions_dir", "recordings_dir", "knowledge_base_dir", "transcripts_dir"] {
            let path = try XCTUnwrap(config[key] as? String)
            XCTAssertTrue(path.hasPrefix(profile.path + "/") && fm.fileExists(atPath: path))
        }
        XCTAssertEqual(config["project_roots"] as? [String], [profile.appendingPathComponent("Projects").path])
        XCTAssertEqual(config["auto_process"] as? Bool, false)
        try RTIBuildProfile.prepareBetaStorage(at: profile)
    }

    func testBetaRejectsLinksOutsideItsProfileBeforeRecovery() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let profile = temporary.appendingPathComponent("Beta")
        let stable = temporary.appendingPathComponent("Stable")
        try fm.createDirectory(at: stable, withIntermediateDirectories: true)
        try RTIBuildProfile.prepareBetaStorage(at: profile)
        try fm.createSymbolicLink(at: profile.appendingPathComponent("Sessions/linked-session"), withDestinationURL: stable)
        XCTAssertThrowsError(try RTIBuildProfile.prepareBetaStorage(at: profile))
        let link = temporary.appendingPathComponent("Linked Beta")
        try fm.createSymbolicLink(at: link, withDestinationURL: stable)
        XCTAssertThrowsError(try RTIBuildProfile.prepareBetaStorage(at: link))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: stable.path), [])
    }

    /// F5 (batch 6): a broken config.json reads as empty settings; the
    /// hand-off to /meeting asks why, so it never mistakes it for "no folder".
    func testConfigReadProblemNamesABrokenFileOnly() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        XCTAssertNil(VaultPaths.configReadProblem(configURL: url), "no file is not a broken file")
        try Data(#"{"recordings_dir": "/invented/rec","#.utf8).write(to: url)
        XCTAssertEqual(VaultPaths.configDictionary(configURL: url).count, 0)
        XCTAssertNil(VaultPaths.meetingTranscriptsRawDirectory(configURL: url))
        XCTAssertEqual(VaultPaths.configReadProblem(configURL: url), url.path + " is not valid JSON. Fix the typo in it.")
        try Data("[1, 2]".utf8).write(to: url)
        XCTAssertNotNil(VaultPaths.configReadProblem(configURL: url), "JSON that is not an object is broken too")
        try Data(#"{"transcripts_dir": "/invented/raw"}"#.utf8).write(to: url)
        XCTAssertNil(VaultPaths.configReadProblem(configURL: url))
    }

    func testConfigURLHonorsHomeOverride() {
        let env = ["RTI_CONFIG_HOME": "/tmp/rti-config-test"]

        XCTAssertEqual(VaultPaths.configURL(environment: env).path, "/tmp/rti-config-test/config.json")
    }

    func testRecordingsConfigDerivesVaultDirectories() {
        let recordings = URL(fileURLWithPath: "/vault/databases/meetings/recordings", isDirectory: true)

        XCTAssertEqual(
            VaultPaths.databasesDirectory(recordingsDirectory: recordings).path,
            "/vault/databases"
        )
        XCTAssertEqual(
            VaultPaths.rtiDirectory(configURL: writeConfig(recordings.path))?.path,
            "/vault/databases/projects/personal/rti"
        )
        XCTAssertEqual(
            VaultPaths.meetingTranscriptsRawDirectory(configURL: writeConfig(recordings.path))?.path,
            "/vault/databases/meetings/transcripts-raw"
        )
        XCTAssertEqual(
            VaultPaths.briefsDirectory(configURL: writeConfig(recordings.path))?.path,
            "/vault/databases/meetings/briefs"
        )
    }

    func testTranscriptsDirOverridesTheDerivedTranscriptsFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try #"{"recordings_dir":"/m/recordings","transcripts_dir":"/m/raw"}"#.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(VaultPaths.meetingTranscriptsRawDirectory(configURL: url)?.path, "/m/raw")
    }

    func testRecordedMeetingsIncludesOnlyTranscribedSidecarsWithExistingTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recordings = root.appendingPathComponent("databases/meetings/recordings", isDirectory: true)
        let transcripts = root.appendingPathComponent("databases/meetings/transcripts-raw", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let transcript = transcripts.appendingPathComponent("client-sync-transcript.txt")
        try "hello".write(to: transcript, atomically: true, encoding: .utf8)
        let completed = recordings.appendingPathComponent("client-sync.meeting.json")
        try """
        {"name":"Client sync","started_at":"2026-07-31T11:40:53.562270","status":"transcribed","transcript_file":"\(transcript.path)"}
        """.write(to: completed, atomically: true, encoding: .utf8)
        try """
        {"name":"Still processing","started_at":"2026-07-31T12:00:00.000000","status":"processing"}
        """.write(to: recordings.appendingPathComponent("processing.meeting.json"), atomically: true, encoding: .utf8)

        let meetings = VaultPaths.recordedMeetings(configURL: writeConfig(recordings.path))

        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings.first?.name, "Client sync")
        XCTAssertEqual(meetings.first?.transcriptURL, transcript)
        XCTAssertNotNil(meetings.first?.startedAt)
    }

    func testSessionsDirectoryDefaultsToTheMeetingsFolderAndHonorsTheConfigKey() {
        XCTAssertEqual(
            VaultPaths.sessionsDirectory(config: [:]).path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Work/Inner-Chapter/meetings/sessions").path
        )
        XCTAssertEqual(
            VaultPaths.sessionsDirectory(config: ["sessions_dir": "/tmp/rti-sessions"]).path,
            "/tmp/rti-sessions"
        )
        XCTAssertEqual(VaultPaths.sessionsDirectory(config: ["sessions_dir": ""]).lastPathComponent, "sessions")
    }

    private func writeConfig(_ recordingsDir: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let escaped = recordingsDir.replacingOccurrences(of: "/", with: "\\/")
        try? #"{"recordings_dir":"\#(escaped)"}"#.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
