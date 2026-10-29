import AppKit
import Foundation

/// The alert shown after a launch that follows an unclean exit. The decision
/// lives in RTICore (`CrashNoticeDecision`). `crash.log` is extra detail: it
/// only exists for uncaught exceptions, so the button shows only when it does.
enum CrashNotice {
    @MainActor
    static func present() {
        DispatchQueue.main.async {
            let logURL = CrashLog.logURL.flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            }
            let alert = NSAlert()
            alert.messageText = "RTI quit unexpectedly last time"
            alert.informativeText = logURL == nil
                ? "The last run did not exit normally."
                : "The last run did not exit normally. A crash report was saved. You can also find it in Settings > Logs."
            if logURL != nil { alert.addButton(withTitle: "Show in Finder") }
            alert.addButton(withTitle: "Dismiss")
            if alert.runModal() == .alertFirstButtonReturn, let logURL {
                NSWorkspace.shared.activateFileViewerSelecting([logURL])
            }
        }
    }
}
