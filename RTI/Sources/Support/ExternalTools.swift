import Foundation

/// One place that knows where the external binaries RTI shells out to live.
/// Every `Process()` site in the app resolves its executable through here so the candidate lists stay in one
/// file and the same lookup rules apply everywhere.
///
/// Rules: probe a fixed candidate list, take the first executable, never
/// consult `PATH` (the app is launched from Finder/launchd with a minimal
/// environment), never route through a shell.
enum ExternalTools {
    /// Apple's system Python, for tools that need only the standard library.
    static let systemPython = URL(fileURLWithPath: "/usr/bin/python3")

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

    static func firstExecutable(_ candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Reads a child's stdout and stderr at the same time, each on its own
/// thread, so neither pipe can fill and block the child. Reading one pipe to
/// the end before the other deadlocks as soon as the unread pipe passes its
/// 64 KB buffer: the child waits for a reader, and the reader waits for the
/// child to close the other pipe. Start it right after `Process.run()`.
final class ProcessOutputCollector: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    init(stdout: Pipe, stderr: Pipe) {
        read(stdout) { data in self.stdoutData = data }
        read(stderr) { data in self.stderrData = data }
    }

    /// Blocks until both pipes reach end of file, which happens when the
    /// child (and anything it spawned with the same pipes) exits.
    func wait() -> (stdout: Data, stderr: Data) {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData)
    }

    private func read(_ pipe: Pipe, into store: @escaping @Sendable (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [lock, group] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            store(data)
            lock.unlock()
            group.leave()
        }
    }
}
