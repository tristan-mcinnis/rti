import XCTest

final class SentinelPathsTests: XCTestCase {
    func testConfigAndStateURLsHonorSentinelHomeOverride() {
        let env = ["MEETING_SENTINEL_HOME": "/tmp/sentinel-test"]

        XCTAssertEqual(SentinelPaths.configURL(environment: env).path, "/tmp/sentinel-test/config.json")
        XCTAssertEqual(SentinelPaths.stateURL(environment: env).path, "/tmp/sentinel-test/state.json")
    }

    func testRecordingsConfigDerivesVaultDirectories() {
        let recordings = URL(fileURLWithPath: "/vault/databases/meetings/recordings", isDirectory: true)

        XCTAssertEqual(
            SentinelPaths.databasesDirectory(recordingsDirectory: recordings).path,
            "/vault/databases"
        )
        XCTAssertEqual(
            SentinelPaths.rtiDirectory(configURL: writeConfig(recordings.path))?.path,
            "/vault/databases/projects/personal/rti"
        )
        XCTAssertEqual(
            SentinelPaths.meetingTranscriptsRawDirectory(configURL: writeConfig(recordings.path))?.path,
            "/vault/databases/meetings/transcripts-raw"
        )
        XCTAssertEqual(
            SentinelPaths.briefsDirectory(configURL: writeConfig(recordings.path))?.path,
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
            SentinelPaths.preferredDatabasesDirectory(configURL: config)?.path,
            activeDatabases.path
        )
        XCTAssertEqual(
            SentinelPaths.rtiDirectory(configURL: config)?.path,
            activeDatabases.appendingPathComponent("projects/personal/rti").path
        )
    }

    func testLinkedMeetingNotesURLUsesAudioSiblingTranscriptsRaw() {
        let url = SentinelPaths.linkedMeetingNotesURL(
            audioFilePath: "/vault/databases/meetings/recordings/client-sync.m4a",
            meetingName: "client-sync"
        )

        XCTAssertEqual(url.path, "/vault/databases/meetings/transcripts-raw/client-sync-rti.md")
    }

    func testVaultRootWalksUpToMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(SentinelPaths.vaultRoot(startingAt: nested)?.path, root.path)
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
