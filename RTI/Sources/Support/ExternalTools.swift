import Foundation

/// One place that knows where the external binaries RTI shells out to live,
/// and one way to fire a detached child. Every `Process()` site in the app
/// resolves its executable through here so the candidate lists stay in one
/// file and the same lookup rules apply everywhere.
///
/// Rules: probe a fixed candidate list, take the first executable, never
/// consult `PATH` (the app is launched from Finder/launchd with a minimal
/// environment), never route through a shell.
enum ExternalTools {
    /// Apple's system Python. Used for vault tools that need only the
    /// standard library and must not depend on a user-installed stack.
    static let systemPython = URL(fileURLWithPath: "/usr/bin/python3")

    /// The user's Python with the vault's third-party stack (sherpa-onnx and
    /// friends): python.org first, then Homebrew, then the system one as a
    /// last resort. A tool that needs a missing package dies cleanly, so a
    /// wrong pick degrades to a silent no-op.
    static func stackPython() -> URL? {
        firstExecutable([
            URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            systemPython,
        ])
    }

    /// The Claude Code CLI, for the headless `/meeting` processor.
    static func claude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return firstExecutable([
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ])
    }

    /// Bun, for the hermes vault-search CLI.
    static func bun() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return firstExecutable([
            home.appendingPathComponent(".bun/bin/bun"),
            URL(fileURLWithPath: "/opt/homebrew/bin/bun"),
            URL(fileURLWithPath: "/usr/local/bin/bun"),
        ])
    }

    static func firstExecutable(_ candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Fire-and-forget child: no pipes, no wait, no result. The caller has
    /// already decided the outcome does not matter to the app (vault-side
    /// routing, enrollment). Launch failure is swallowed by design.
    static func launchDetached(_ executable: URL, arguments: [String], currentDirectory: URL? = nil) {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        if let currentDirectory { proc.currentDirectoryURL = currentDirectory }
        try? proc.run()
    }
}
