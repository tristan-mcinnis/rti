import Foundation

public enum SentinelCommandBuilder {
    public static func start(name: String, project: String?) -> [String] {
        var arguments = ["start", "--dual-channel", "--name", safeRecordingName(name)]
        if let project = nonempty(project) {
            arguments += ["--project", project]
        }
        return arguments
    }

    public static func stop() -> [String] {
        ["stop"]
    }

    public static func transcribe(file: String, project: String?) -> [String] {
        var arguments = ["transcribe", file]
        if let project = nonempty(project) {
            arguments += ["--project", project]
        }
        return arguments
    }

    public static func safeRecordingName(_ value: String) -> String {
        let folded = value
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let parts = String(folded).split(separator: "-").filter { !$0.isEmpty }
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? "meeting" : String(joined.prefix(80))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
