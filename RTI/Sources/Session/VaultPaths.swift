import Foundation

struct RecordedMeeting: Equatable {
    let name: String
    let startedAt: Date?
    let transcriptURL: URL
}

/// Single path authority for everything RTI writes into or reads from the
/// vault. Config lives at `~/.config/rti/config.json` (override the directory
/// with `RTI_CONFIG_HOME` for tests); `recordings_dir` inside it anchors the
/// whole tree — change the vault location by editing that one file.
enum VaultPaths {
    static func homeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["RTI_CONFIG_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rti", isDirectory: true)
    }

    static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        homeDirectory(environment: environment).appendingPathComponent("config.json")
    }

    static func configDictionary(configURL: URL = configURL()) -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    static func recordingsDirectory(configURL: URL = configURL()) -> URL? {
        recordingsDirectory(config: configDictionary(configURL: configURL))
    }

    static func recordingsDirectory(config: [String: Any]) -> URL? {
        guard let recordings = config["recordings_dir"] as? String, !recordings.isEmpty else { return nil }
        return URL(fileURLWithPath: (recordings as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func databasesDirectory(recordingsDirectory: URL) -> URL {
        recordingsDirectory
            .deletingLastPathComponent() // recordings -> meetings
            .deletingLastPathComponent() // meetings -> databases
    }

    static func databasesDirectory(configURL: URL = configURL()) -> URL? {
        recordingsDirectory(configURL: configURL).map(databasesDirectory(recordingsDirectory:))
    }

    /// The databases directory RTI uses: `knowledge_base_dir` when set,
    /// otherwise the tree `recordings_dir` sits in.
    static func preferredDatabasesDirectory(configURL: URL = configURL()) -> URL? {
        let config = configDictionary(configURL: configURL)
        return explicitKnowledgeBaseDirectory(config: config)
            ?? recordingsDirectory(config: config).map(databasesDirectory(recordingsDirectory:))
    }

    static func rtiDirectory(configURL: URL = configURL()) -> URL? {
        preferredDatabasesDirectory(configURL: configURL)?
            .appendingPathComponent("projects/personal/rti", isDirectory: true)
    }

    /// Where finished session folders are archived. `sessions_dir` in the
    /// config overrides the default.
    static func sessionsDirectory(configURL: URL = configURL()) -> URL {
        sessionsDirectory(config: configDictionary(configURL: configURL))
    }

    static func sessionsDirectory(config: [String: Any]) -> URL {
        if let configured = config["sessions_dir"] as? String, !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Work/Inner-Chapter/meetings/sessions", isDirectory: true)
    }

    static func meetingTranscriptsRawDirectory(configURL: URL = configURL()) -> URL? {
        let config = configDictionary(configURL: configURL)
        if let transcripts = config["transcripts_dir"] as? String, !transcripts.isEmpty {
            return URL(fileURLWithPath: (transcripts as NSString).expandingTildeInPath, isDirectory: true)
        }
        return preferredDatabasesDirectory(configURL: configURL)?
            .appendingPathComponent("meetings/transcripts-raw", isDirectory: true)
    }

    static func briefsDirectory(configURL: URL = configURL()) -> URL? {
        preferredDatabasesDirectory(configURL: configURL)?
            .appendingPathComponent("meetings/briefs", isDirectory: true)
    }

    /// Discover completed keeper-of-record meeting recordings from their
    /// `.meeting.json` sidecars in the recordings directory. Sidecars are
    /// authoritative; loose transcript files may be partial, imported from an
    /// older install, or already represented by an RTI archive.
    static func recordedMeetings(
        configURL: URL = configURL(),
        fileManager: FileManager = .default
    ) -> [RecordedMeeting] {
        guard let recordings = recordingsDirectory(configURL: configURL),
              let sidecars = try? fileManager.contentsOfDirectory(
                  at: recordings,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        return sidecars.compactMap { sidecar in
            guard sidecar.lastPathComponent.hasSuffix(".meeting.json"),
                  let data = try? Data(contentsOf: sidecar),
                  let record = try? JSONDecoder().decode(RecordedMeetingRecord.self, from: data),
                  record.status == "transcribed",
                  let transcriptPath = record.transcriptFile
            else { return nil }
            let transcript = URL(fileURLWithPath: (transcriptPath as NSString).expandingTildeInPath)
            guard fileManager.fileExists(atPath: transcript.path) else { return nil }
            return RecordedMeeting(
                name: record.name,
                startedAt: parseTimestamp(record.startedAt),
                transcriptURL: transcript
            )
        }
    }

    private static func explicitKnowledgeBaseDirectory(config: [String: Any]) -> URL? {
        for key in ["knowledge_base_dir"] {
            guard let value = config[key] as? String, !value.isEmpty else { continue }
            let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
            return url.lastPathComponent == "databases"
                ? url
                : url.appendingPathComponent("databases", isDirectory: true)
        }
        return nil
    }

    private struct RecordedMeetingRecord: Decodable {
        let name: String
        let startedAt: String
        let status: String
        let transcriptFile: String?

        enum CodingKeys: String, CodingKey {
            case name, status
            case startedAt = "started_at"
            case transcriptFile = "transcript_file"
        }
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter.date(from: raw)
    }
}
