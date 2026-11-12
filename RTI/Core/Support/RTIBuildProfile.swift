import Foundation

/// The bundle identity selects the profile even on a normal Finder launch.
public enum RTIBuildProfile {
    public static let stableID = "com.tristan.rti.personal"
    public static let betaID = stableID + ".beta"
    public static let isBeta = Bundle.main.bundleIdentifier == betaID
    public static let displayName = isBeta ? "RTI Beta" : "RTI"

    public static var betaHome: URL {
        let base = AppSupportPaths.applicationSupportBase()
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("RTI Beta", isDirectory: true)
    }

    /// A malformed/missing config can never select the regular recorder's fallback directories.
    public static func betaStorageConfig(at root: URL) -> [String: Any] {
        let database = root.appendingPathComponent("Library/databases", isDirectory: true)
        return [
            "knowledge_base_dir": database.path,
            "recordings_dir": database.appendingPathComponent("meetings/recordings").path,
            "sessions_dir": root.appendingPathComponent("Sessions").path,
            "transcripts_dir": root.appendingPathComponent("Exports").path,
            "project_roots": [root.appendingPathComponent("Projects").path],
            "auto_process": false,
        ]
    }

    public static func prepareBetaStorage(at root: URL) throws {
        let fm = FileManager.default
        let directories = ["Config", "Sessions", "Exports", "Projects", "Library/databases/meetings/recordings"]
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        guard (try? fm.destinationOfSymbolicLink(atPath: root.path)) == nil else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: permissions)
        // A test copy can contain symbolic links into the regular recorder's archive.
        // Reject escaping links before running recovery, migrations or housekeeping.
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var traversalError: Error?
        guard let contents = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                           errorHandler: { _, error in
                                               traversalError = error
                                               return false
                                           }) else { throw CocoaError(.fileReadNoPermission) }
        for case let file as URL in contents {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let destination = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard destination.hasPrefix(base + "/") else { throw CocoaError(.fileWriteNoPermission) }
            }
        }
        if let traversalError {
            throw traversalError
        }
        for name in directories {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true, attributes: permissions)
        }
    }
}
