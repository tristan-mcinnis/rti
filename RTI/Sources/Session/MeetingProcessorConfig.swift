import Foundation

/// Config policy for the unattended `/meeting` run that RTI can start with
/// `claude -p` after a session. Both switches default to off.
enum MeetingProcessorConfig {
    /// The run is opt-in: `auto_process` must be `true` in the config file.
    /// Absent or any other value means off.
    static func isEnabled(config: [String: Any]) -> Bool {
        (config["auto_process"] as? Bool) ?? false
    }

    /// Where the run starts: the work tree the `/meeting` skill files into.
    static func workingDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Documents/Work", isDirectory: true)
    }

    /// What the `/meeting` skill needs and nothing more: file tools, a few
    /// read and copy commands, its own helper scripts, and the memory repo's
    /// add, commit, pull and push. Nothing else runs in an unattended session.
    static func allowedTools(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let memory = home.appendingPathComponent("memory").path
        let skills = home.appendingPathComponent("skills").path
        return [
            "Read", "Write", "Edit", "Glob", "Grep",
            "Bash(cp *)", "Bash(mkdir *)", "Bash(ls *)", "Bash(head *)", "Bash(cat *)",
            "Bash(python3 -I \(skills)/*)",
            "Bash(git -C \(memory) add *)",
            "Bash(git -C \(memory) commit *)",
            "Bash(git -C \(memory) push *)",
            "Bash(git -C \(memory) pull *)",
        ]
    }

    /// Permission flags for the run. The mode is always `acceptEdits`;
    /// `auto_process_scoped_tools: true` also allows the scoped tool list
    /// above, without prompts, and lets the run edit the memory repo.
    /// Permissions are never skipped.
    static func permissionArguments(
        config: [String: Any],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        var arguments = ["--permission-mode", "acceptEdits"]
        if (config["auto_process_scoped_tools"] as? Bool) ?? false {
            arguments += ["--allowedTools"] + allowedTools(home: home)
            arguments += ["--add-dir", home.appendingPathComponent("memory").path]
        }
        return arguments
    }
}
