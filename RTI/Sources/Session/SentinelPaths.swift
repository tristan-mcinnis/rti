import Foundation

enum SentinelPaths {
    static func executableURL(fileManager: FileManager = .default) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/meet"),
            URL(fileURLWithPath: "/opt/homebrew/bin/meet"),
            URL(fileURLWithPath: "/usr/local/bin/meet"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

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

    /// Resolve the knowledge-base database directory RTI should use. Sentinel
    /// historically pointed at `<vault>/vault/databases`; a moved vault may
    /// leave that path behind while the live knowledge base is now at a nearby
    /// `<vault>/kb/databases`. Prefer a complete tree (projects + meeting
    /// recordings) so a stale, partial legacy directory cannot hide projects.
    static func preferredDatabasesDirectory(
        configURL: URL = configURL(),
        fileManager: FileManager = .default
    ) -> URL? {
        let config = configDictionary(configURL: configURL)
        guard let configured = recordingsDirectory(config: config).map(databasesDirectory(recordingsDirectory:)) else {
            return explicitKnowledgeBaseDirectory(config: config)
        }

        let explicit = explicitKnowledgeBaseDirectory(config: config)
        let candidates = ([explicit, configured] + nearbyKnowledgeBaseDirectories(from: configured))
            .compactMap { $0 }
            .reduce(into: [URL]()) { unique, candidate in
                if !unique.contains(where: { $0.standardizedFileURL == candidate.standardizedFileURL }) {
                    unique.append(candidate)
                }
            }

        if let complete = candidates.first(where: { isCompleteDatabasesDirectory($0, fileManager: fileManager) }) {
            return complete
        }
        if let projects = candidates.first(where: {
            fileManager.fileExists(atPath: $0.appendingPathComponent("projects", isDirectory: true).path)
        }) {
            return projects
        }
        return configured
    }

    static func rtiDirectory(configURL: URL = configURL()) -> URL? {
        preferredDatabasesDirectory(configURL: configURL)?
            .appendingPathComponent("projects/personal/rti", isDirectory: true)
    }

    static func meetingTranscriptsRawDirectory(configURL: URL = configURL()) -> URL? {
        preferredDatabasesDirectory(configURL: configURL)?
            .appendingPathComponent("meetings/transcripts-raw", isDirectory: true)
    }

    static func briefsDirectory(configURL: URL = configURL()) -> URL? {
        preferredDatabasesDirectory(configURL: configURL)?
            .appendingPathComponent("meetings/briefs", isDirectory: true)
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

    private static func explicitKnowledgeBaseDirectory(config: [String: Any]) -> URL? {
        for key in ["knowledge_base_dir", "kb_dir", "vault_dir"] {
            guard let value = config[key] as? String, !value.isEmpty else { continue }
            let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
            return url.lastPathComponent == "databases"
                ? url
                : url.appendingPathComponent("databases", isDirectory: true)
        }
        return nil
    }

    private static func nearbyKnowledgeBaseDirectories(from configured: URL) -> [URL] {
        var candidates: [URL] = []
        var current = configured.deletingLastPathComponent()
        while current.deletingLastPathComponent().path != current.path {
            candidates.append(current.appendingPathComponent("kb/databases", isDirectory: true))
            current = current.deletingLastPathComponent()
        }
        return candidates
    }

    private static func isCompleteDatabasesDirectory(_ directory: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent("projects", isDirectory: true).path)
            && fileManager.fileExists(atPath: directory.appendingPathComponent("meetings/recordings", isDirectory: true).path)
    }
}
