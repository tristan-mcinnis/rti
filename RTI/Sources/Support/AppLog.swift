import Foundation

/// Lightweight in-app logger. Writes to NSLog (so messages still land in the
/// system log / Xcode console) AND to an in-memory ring buffer that the
/// Settings → Logs window observes. Mostly useful when something goes wrong
/// in the field and the user can't conveniently run `log show` in Terminal.
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    /// Tunable; 500 lines is plenty for a single session and keeps the UI
    /// responsive even when the audio path logs aggressively.
    private let maxEntries = 500

    @Published private(set) var entries: [Entry] = []

    struct Entry: Identifiable, Equatable {
        let id: UUID = UUID()
        let timestamp: Date
        let category: String
        let message: String
    }

    private init() {
        entries.reserveCapacity(maxEntries)
    }

    func log(_ message: String, category: String = "RTI") {
        let entry = Entry(timestamp: Date(), category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        NSLog("[%@] %@", category, message)
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    func renderForCopy() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries.map { e in
            "\(formatter.string(from: e.timestamp)) [\(e.category)] \(e.message)"
        }.joined(separator: "\n")
    }
}

/// `RTILog.log("…")` is the call-site form so existing NSLog locations are
/// trivially upgradable. `RTILog.log(...)` always lands on the main actor.
enum RTILog {
    static func log(_ message: String, category: String = "RTI") {
        if Thread.isMainThread {
            MainActor.assumeIsolated { AppLog.shared.log(message, category: category) }
        } else {
            DispatchQueue.main.async { AppLog.shared.log(message, category: category) }
        }
    }
}
