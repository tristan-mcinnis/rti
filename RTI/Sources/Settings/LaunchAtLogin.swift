import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or an error message on failure. SMAppService
    /// requires the app to be properly signed on macOS 13+; returns a
    /// human-readable error if registration fails (e.g., ad-hoc signed apps).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            RTILog.log("LaunchAtLogin set(\(enabled)) failed: \(error)", category: .launchAtLogin)
            return (error as NSError).localizedDescription
        }
    }
}
