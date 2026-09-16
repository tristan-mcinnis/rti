import Foundation

public enum SessionArchiveActionRules {
    /// Only a timestamped direct child of RTI's archive root is a session
    /// folder. A vault meeting note, the root, or a nested path is not.
    public static func canTrash(sessionDirectory: URL, archiveRoot: URL) -> Bool {
        let directory = sessionDirectory.standardizedFileURL
        let root = archiveRoot.standardizedFileURL
        return directory.isFileURL && root.isFileURL
            && directory.deletingLastPathComponent() == root
            && directory.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2} \d{6}$"#, options: .regularExpression) != nil
    }
}
