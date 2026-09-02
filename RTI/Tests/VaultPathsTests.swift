import XCTest

final class VaultPathsTests: XCTestCase {
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

    func testPrefersCompleteNearbyKnowledgeBaseWhenConfiguredRecordingsMoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let retiredRecordings = root.appendingPathComponent("vault/databases/meetings/recordings", isDirectory: true)
        let activeDatabases = root.appendingPathComponent("kb/databases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: retiredRecordings.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: activeDatabases.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activeDatabases.appendingPathComponent("meetings/recordings"), withIntermediateDirectories: true)

        let config = writeConfig(retiredRecordings.path)

        XCTAssertEqual(
            VaultPaths.preferredDatabasesDirectory(configURL: config)?.path,
            activeDatabases.path
        )
        XCTAssertEqual(
            VaultPaths.rtiDirectory(configURL: config)?.path,
            activeDatabases.appendingPathComponent("projects/personal/rti").path
        )
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

    func testVaultToolResolvesFromGitRootAndRequiresFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recordings = root.appendingPathComponent("vault/databases/meetings/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("vault/databases/projects"), withIntermediateDirectories: true)
        let tool = root.appendingPathComponent(".claude/tools/triage/route-rti-session.py")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "print()".write(to: tool, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = writeConfig(recordings.path)

        XCTAssertEqual(VaultPaths.gitRootDirectory(configURL: config)?.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertEqual(
            VaultPaths.vaultToolURL(".claude/tools/triage/route-rti-session.py", configURL: config)?.standardizedFileURL.path,
            tool.standardizedFileURL.path
        )
        XCTAssertNil(VaultPaths.vaultToolURL(".claude/tools/missing.py", configURL: config))
    }

    func testVaultRootWalksUpToMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(VaultPaths.vaultRoot(startingAt: nested)?.path, root.path)
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
