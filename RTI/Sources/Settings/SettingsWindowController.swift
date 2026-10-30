import AppKit
import HouseDesign

/// Compatibility entry point. Settings belongs to the main workspace.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    static let autosaveName = "rti.settings"
    static let standardSize = NSSize(width: House.Layout.settingsWidth, height: House.Layout.settingsHeight)

    func show(pane: SettingsView.SettingsTab = .providers) {
        WindowCoordinator.shared.openSettings(pane: pane)
    }

    func close() { WorkspaceModel.shared.leaveSettings() }
}
