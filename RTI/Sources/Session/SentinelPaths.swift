import Foundation

enum SentinelPaths {
    static func homeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["MEETING_SENTINEL_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-sentinel", isDirectory: true)
    }

    static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        homeDirectory(environment: environment).appendingPathComponent("config.json")
    }

    static func stateURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        homeDirectory(environment: environment).appendingPathComponent("state.json")
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

    static func rtiDirectory(configURL: URL = configURL()) -> URL? {
        databasesDirectory(configURL: configURL)?
            .appendingPathComponent("projects/personal/rti", isDirectory: true)
    }

    static func meetingTranscriptsRawDirectory(configURL: URL = configURL()) -> URL? {
        recordingsDirectory(configURL: configURL)?
            .deletingLastPathComponent()
            .appendingPathComponent("transcripts-raw", isDirectory: true)
    }

    static func briefsDirectory(configURL: URL = configURL()) -> URL? {
        recordingsDirectory(configURL: configURL)?
            .deletingLastPathComponent()
            .appendingPathComponent("briefs", isDirectory: true)
    }

    static func linkedMeetingNotesURL(audioFilePath: String, meetingName: String) -> URL {
        let recordingsDir = URL(fileURLWithPath: audioFilePath).deletingLastPathComponent()
        return recordingsDir.deletingLastPathComponent()
            .appendingPathComponent("transcripts-raw", isDirectory: true)
            .appendingPathComponent("\(meetingName)-rti.md")
    }

    static func vaultRoot(startingAt dir: URL, fileManager: FileManager = .default) -> URL? {
        var current = dir
        while true {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".claude").path)
                || fileManager.fileExists(atPath: current.appendingPathComponent("CLAUDE.md").path)
                || fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }
}
