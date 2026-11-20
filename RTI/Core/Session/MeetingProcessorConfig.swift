import Foundation

/// Config policy for the unattended `/meeting` run that RTI can start with
/// `claude -p` after a session. Both switches default to off.
public enum MeetingProcessorConfig {
    /// The run is opt-in: `auto_process` must be `true` in the config file.
    /// Absent or any other value means off.
    public static func isEnabled(config: [String: Any]) -> Bool {
        !RTIBuildProfile.isBeta && ((config["auto_process"] as? Bool) ?? false)
    }

    /// Where the run starts: the work tree the `/meeting` skill files into.
    public static func workingDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Documents/Work", isDirectory: true)
    }

    /// The lanes whose `tasks/<lane>.md` the skill may commit, one entry each.
    public static let taskLanes = ["inner-chapter", "harness", "personal", "finance"]

    /// What the `/meeting` skill needs and nothing more: read tools, mkdir
    /// under the work tree and ls, and the memory repo's add and fixed
    /// commit per lane task file, pull and push. No scripts, no
    /// cat or cp, no bare Write or Edit: file writes come from `acceptEdits`,
    /// which covers the working directory and `--add-dir` only.
    public static func allowedTools(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let memory = home.appendingPathComponent("memory").path
        return [
            "Read", "Glob", "Grep",
            "Bash(mkdir -p \(home.appendingPathComponent("Documents/Work").path)/*)", "Bash(ls *)",
        ] + taskLanes.flatMap { lane in
            [
                "Bash(git -C \(memory) add tasks/\(lane).md)",
                "Bash(git -C \(memory) commit -m meeting-tasks -- tasks/\(lane).md)",
            ]
        } + [
            "Bash(git -C \(memory) pull --rebase)",
            "Bash(git -C \(memory) push)",
        ]
    }

    /// One log line for a finished run, or nil on a clean exit. Carries the
    /// status only, never any of the run's output.
    public static func exitLogLine(name: String, status: Int32, reason: Process.TerminationReason) -> String? {
        if reason == .uncaughtSignal { return "meeting processor killed by signal \(status) for \(name)" }
        guard status != 0 else { return nil }
        return "meeting processor exited with status \(status) for \(name)"
    }

    /// Tools denied outright, on top of the allow list. `acceptEdits` also
    /// auto-approves file commands inside the working directory and
    /// `--add-dir`; an unattended run fed third-party speech must not delete,
    /// move or rewrite client files with them. `cp` stays: the skill copies
    /// the transcript into the project.
    public static let disallowedTools = [
        "WebFetch", "WebSearch", "Bash(curl *)",
        "Bash(rm *)", "Bash(rmdir *)", "Bash(mv *)", "Bash(sed *)", "Bash(touch *)",
    ]

    /// Inline settings for the run: only the send-guard hook, no allow rules.
    public static func guardSettings(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let guardPath = home.appendingPathComponent("skills/_lib/guards/guard-send-gates.py").path
        return "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\","
            + "\"command\":\"python3 \(guardPath)\",\"timeout\":5}]}]}}"
    }

    /// Permission flags for the run. The mode is always `acceptEdits`, and
    /// the run never loads user settings (`project,local` only, from a
    /// working directory with no `.claude`), so the user's broad allow rules
    /// and MCP servers do not apply; only the send guard is added back.
    /// `auto_process_scoped_tools: true` also allows the scoped tool list
    /// above, without prompts, and lets the run edit the memory repo.
    /// Permissions are never skipped.
    public static func permissionArguments(
        config: [String: Any],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        var arguments = [
            "--permission-mode", "acceptEdits",
            "--setting-sources", "project,local",
            "--strict-mcp-config",
            "--settings", guardSettings(home: home),
            "--disallowedTools",
        ] + disallowedTools
        if (config["auto_process_scoped_tools"] as? Bool) ?? false {
            arguments += ["--allowedTools"] + allowedTools(home: home)
            arguments += ["--add-dir", home.appendingPathComponent("memory").path]
        }
        for target in linkedWorkFolders(home: home) {
            arguments += ["--add-dir", target]
        }
        return arguments
    }

    /// Where the work tree's linked folders really live. Claude Code checks a
    /// write against the resolved path, so a client folder or the meetings
    /// inbox that links into Google Drive is outside the working directory
    /// and every write there was refused (2026-11-18 and 11-19: two meeting
    /// notes left in a temporary folder). Links two levels deep count
    /// (`<client>`, `<client>/<folder>`); each target is named once.
    public static func linkedWorkFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let fm = FileManager.default
        let work = workingDirectory(home: home)
        let workPath = work.resolvingSymlinksInPath().path
        var targets: [String] = []
        func visit(_ dir: URL, depth: Int) {
            guard let children = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return }
            for child in children.sorted(by: { $0.path < $1.path }) {
                let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true {
                    let target = child.resolvingSymlinksInPath()
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue,
                          !target.path.hasPrefix(workPath + "/"), !targets.contains(target.path) else { continue }
                    targets.append(target.path)
                } else if values?.isDirectory == true, depth < 2 {
                    visit(child, depth: depth + 1)
                }
            }
        }
        visit(work, depth: 1)
        return targets
    }
}
