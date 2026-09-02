import Foundation
import Observation

/// Lightweight in-app logger. Writes to NSLog (so messages still land in the
/// system log / Xcode console) AND to an in-memory ring buffer that the
/// Settings → Logs window observes. Mostly useful when something goes wrong
/// in the field and the user can't conveniently run `log show` in Terminal.
@Observable @MainActor
final class AppLog {
    static let shared = AppLog()

    /// Tunable; 500 lines is plenty for a single session and keeps the UI
    /// responsive even when the audio path logs aggressively.
    private let maxEntries = 500

    private(set) var entries: [Entry] = []

    struct Entry: Identifiable, Equatable {
        let id: UUID = UUID()
        let timestamp: Date
        let level: LogLevel
        let category: String
        let message: String
    }

    /// On-disk log home: ~/Library/Logs/RTI/rti-YYYY-MM-DD.log, one file per
    /// day, pruned past `retentionDays`. The in-memory ring buffer stays the
    /// "Live" view; these files are the "Past" view — so a crash or quit no
    /// longer erases the evidence.
    nonisolated static let logsDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RTI", isDirectory: true)
    private static let retentionDays = 14
    private static let fileQueue = DispatchQueue(label: "rti.applog.file", qos: .utility)
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

    func log(_ message: String, level: LogLevel = .info, category: String = LogCategory.general.rawValue) {
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
        Self.fileQueue.async { Self.append(line, day: day) }
    }

    private static func append(_ line: String, day: String) {
        let url = logsDirectory.appendingPathComponent("rti-\(day).log")
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func pruneOldFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        for f in files where f.lastPathComponent.hasPrefix("rti-") {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Daily log files on disk, newest first — the "Past" view's source.
    nonisolated static func pastLogFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("rti-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    func renderForCopy() -> String {
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
enum LogLevel: Int, Comparable, Sendable {
    case debug
    case info
    case warning
    case error

    var tag: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The subsystem a log line belongs to. Raw values are the strings shown in
/// the Logs window and written to disk; they predate the enum, so keep them.
enum LogCategory: String, Sendable {
    case general = "RTI"
    case analysis
    case archive
    case audio
    case credentials
    case discussionGuide
    case findings
    case guide
    case hotkey
    case latency
    case launchAtLogin = "launch-at-login"
    case llm
    case modes
    case notes
    case screenshot
    case soniox
    case summary
    case systemAudio = "system-audio"
    case vault
    case vision
}

/// `RTILog.log("…")` is the call-site form so existing NSLog locations are
/// trivially upgradable. `RTILog.log(...)` always lands on the main actor.
enum RTILog {
    static func log(_ message: String, level: LogLevel = .info, category: LogCategory = .general) {
        log(message, level: level, category: category.rawValue)
    }

    /// String-category form, for messages that arrive from RTICore's
    /// `CoreLog` sink with a category the app does not model.
    static func log(_ message: String, level: LogLevel = .info, category: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { AppLog.shared.log(message, level: level, category: category) }
        } else {
            DispatchQueue.main.async { AppLog.shared.log(message, level: level, category: category) }
        }
    }
}
