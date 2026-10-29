import AppKit
import Foundation

/// One-time notice after a launch that follows a recorded crash. The crash log
/// file's modification time says when the last crash was written; one
/// UserDefaults timestamp says which crash the user has already seen.
enum CrashNotice {
    static let acknowledgedKey = "crashNoticeLastAcknowledged"

    /// Show only when a crash was written after the last one the user saw.
    static func shouldShow(crashLogModified: Date?, lastAcknowledged: Date?) -> Bool {
        guard let crashLogModified else { return false }
        guard let lastAcknowledged else { return true }
        return crashLogModified > lastAcknowledged
    }

    /// Defers to the next run-loop turn so launch finishes before the alert.
    @MainActor
    static func presentIfNeeded() {
        DispatchQueue.main.async {
            guard let url = CrashLog.logURL,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date else { return }
            let defaults = UserDefaults.standard
            let acknowledged = defaults.object(forKey: acknowledgedKey) as? Date
            guard shouldShow(crashLogModified: modified, lastAcknowledged: acknowledged) else { return }

            // Record first, so a crash inside the alert cannot loop the notice.
            defaults.set(modified, forKey: acknowledgedKey)

            let alert = NSAlert()
            alert.messageText = "RTI crashed last time"
            alert.informativeText = "A crash report was saved. You can find it in Settings > Logs."
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "Dismiss")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
