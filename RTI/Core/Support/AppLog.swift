import Foundation
import Observation

/// Lightweight in-app logger. Writes to NSLog (so messages still land in the
/// system log / Xcode console) AND to an in-memory ring buffer that the
/// Settings → Logs window observes. Mostly useful when something goes wrong
/// in the field and the user can't conveniently run `log show` in Terminal.
@Observable @MainActor
public final class AppLog {
    public static let shared = AppLog()

    /// Tunable; 500 lines is plenty for a single session and keeps the UI
    /// responsive even when the audio path logs aggressively.
    private let maxEntries = 500

    public private(set) var entries: [Entry] = []

    public struct Entry: Identifiable, Equatable {
        public let id: UUID = UUID()
        public let timestamp: Date
        public let level: LogLevel
        public let category: String
        public let message: String

        public init(
            timestamp: Date,
            level: LogLevel,
            category: String,
            message: String
        ) {
            self.timestamp = timestamp
            self.level = level
            self.category = category
            self.message = message
        }
    }

    /// On-disk log home: ~/Library/Logs/RTI/rti-YYYY-MM-DD.log, one file per
    /// day, pruned past `retentionDays`. The in-memory ring buffer stays the
    /// "Live" view; these files are the "Past" view — so a crash or quit no
    /// longer erases the evidence.
    public nonisolated static let logsDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment
        if RTIBuildProfile.isBeta { return RTIBuildProfile.betaHome.appendingPathComponent("Logs", isDirectory: true) }
        if let path = environment["RTI_LOG_DIRECTORY"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // Hostless acceptance tests must not append to or prune the user's logs.
        if ProcessInfo.processInfo.processName == "xctest" || environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("RTI-test-logs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RTI", isDirectory: true)
    }()
    private nonisolated static let retentionDays = 14
    private nonisolated static let fileQueue = DispatchQueue(label: "rti.applog.file", qos: .utility)
    private static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let lineStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        entries.reserveCapacity(maxEntries)
        Self.fileQueue.async { Self.pruneOldFiles() }
    }

    public func log(_ message: String, level: LogLevel = .info, category: String = LogCategory.general.rawValue) {
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        // `.info` is the historical default and keeps the line shape unchanged;
        // other levels gain a tag so they stand out in the file and console.
        let tagged = level == .info ? message : "\(level.tag) \(message)"
        NSLog("[%@] %@", category, tagged)
        let line = "\(Self.lineStamp.string(from: entry.timestamp)) [\(category)] \(tagged)\n"
        let day = Self.dayStamp.string(from: entry.timestamp)
        Self.fileBatch.enqueue(line, day: day, urgent: level == .error)
    }

    /// Lines wait up to `LogFileBatch.delay` and go to disk in one write per
    /// day file, instead of one open, seek, write and close per line.
    private nonisolated static let fileBatch = LogFileBatch(queue: fileQueue) { day in
        logsDirectory.appendingPathComponent("rti-\(day).log")
    }

    /// Write every waiting line now. Tests and app termination call this.
    public nonisolated static func flushFile() {
        fileBatch.flushNow()
    }

    private nonisolated static func pruneOldFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        for f in files where f.lastPathComponent.hasPrefix("rti-") {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Daily log files on disk, newest first — the "Past" view's source.
    public nonisolated static func pastLogFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("rti-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    public func renderForCopy() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries.map { e in
            let tagged = e.level == .info ? e.message : "\(e.level.tag) \(e.message)"
            return "\(formatter.string(from: e.timestamp)) [\(e.category)] \(tagged)"
        }.joined(separator: "\n")
    }
}

/// Severity of a log line. `.info` is the default and matches what every
/// pre-level call site produced; the others add a tag to the rendered line.
public enum LogLevel: Int, Comparable, Sendable {
    case info
    case warning
    case error

    public var tag: String {
        switch self {
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The subsystem a log line belongs to. Raw values are the strings shown in
/// the Logs window and written to disk; they predate the enum, so keep them.
public enum LogCategory: String, Sendable {
    case general = "RTI"
    case archive
    case audio
    case credentials
    case hotkey
    case latency
    case launchAtLogin = "launch-at-login"
    case llm
    case notes
    case screenshot
    case soniox
    case systemAudio = "system-audio"
    case vault
}

/// `RTILog.log("…")` is the call-site form so existing NSLog locations are
/// trivially upgradable. `RTILog.log(...)` always lands on the main actor.
public enum RTILog {
    public static func log(_ message: String, level: LogLevel = .info, category: LogCategory = .general) {
        log(message, level: level, category: category.rawValue)
    }

    /// String-category form, for messages that arrive from RTICore's
    /// `CoreLog` sink with a category the app does not model.
    public static func log(_ message: String, level: LogLevel = .info, category: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { AppLog.shared.log(message, level: level, category: category) }
        } else {
            DispatchQueue.main.async { AppLog.shared.log(message, level: level, category: category) }
        }
    }
}

/// Batches log lines for the daily files. `enqueue` is cheap from any
/// thread; the first line of a batch schedules one flush on `queue` after
/// `delay`, and an error line flushes at once. `@unchecked Sendable`:
/// `lock` guards `pending` and `scheduled`.
public final class LogFileBatch: @unchecked Sendable {
    public static let delay: TimeInterval = 0.5
    private let queue: DispatchQueue
    private let url: @Sendable (String) -> URL
    private let lock = NSLock()
    private var pending: [(day: String, line: String)] = []
    private var scheduled = false
    private var writeCount = 0

    public init(queue: DispatchQueue, url: @escaping @Sendable (String) -> URL) {
        self.queue = queue
        self.url = url
    }

    /// File writes so far, one per day file per flush. For tests.
    public var writes: Int {
        lock.withLock { writeCount }
    }

    public func enqueue(_ line: String, day: String, urgent: Bool = false) {
        let schedule = lock.withLock { () -> Bool in
            pending.append((day, line))
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if urgent {
            queue.async { self.flush() }
        } else if schedule {
            queue.asyncAfter(deadline: .now() + Self.delay) { self.flush() }
        }
    }

    /// Write every waiting line before returning.
    public func flushNow() {
        queue.sync { flush() }
    }

    private func flush() {
        let lines = lock.withLock { () -> [(day: String, line: String)] in
            defer {
                pending = []
                scheduled = false
            }
            return pending
        }
        guard !lines.isEmpty else { return }
        var days: [String] = []
        var text: [String: String] = [:]
        for item in lines {
            if text[item.day] == nil { days.append(item.day) }
            text[item.day, default: ""] += item.line
        }
        for day in days {
            append(text[day] ?? "", to: url(day))
        }
        lock.withLock { writeCount += days.count }
    }

    private func append(_ chunk: String, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(chunk.utf8))
        } else {
            try? chunk.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
