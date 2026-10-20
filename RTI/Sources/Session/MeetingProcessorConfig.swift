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

    /// What the `/meeting` skill needs and nothing more: read tools, mkdir and
    /// ls, and the memory repo's add, commit, pull and push. No scripts, no
    /// cat or cp, no bare Write or Edit: file writes come from `acceptEdits`,
    /// which covers the working directory and `--add-dir` only.
    static func allowedTools(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let memory = home.appendingPathComponent("memory").path
        return [
            "Read", "Glob", "Grep",
            "Bash(mkdir *)", "Bash(ls *)",
            "Bash(git -C \(memory) add tasks.md)",
            "Bash(git -C \(memory) commit -m *)",
            "Bash(git -C \(memory) pull --rebase)",
            "Bash(git -C \(memory) push)",
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
