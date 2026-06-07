import Foundation

/// Logging seam for RTICore. Core code calls `CoreLog.log(...)`; the app
/// installs a sink at startup that forwards into its UI log buffer (AppLog via
/// RTILog). Until a sink is installed — and in unit tests — messages fall back
/// to NSLog so nothing is silently dropped.
public enum CoreLog {
    private nonisolated(unsafe) static var sink: (@Sendable (String, String) -> Void)?
    private static let lock = NSLock()

    /// Install the forwarder. Called once at app startup.
    public static func installSink(_ handler: @escaping @Sendable (String, String) -> Void) {
        lock.lock()
        sink = handler
        lock.unlock()
    }

    /// Log `message` under `category`, routing to the installed sink or NSLog.
    public static func log(_ message: String, category: String = "RTI") {
        lock.lock()
        let handler = sink
        lock.unlock()
        if let handler {
            handler(message, category)
        } else {
            NSLog("[%@] %@", category, message)
        }
    }
}
