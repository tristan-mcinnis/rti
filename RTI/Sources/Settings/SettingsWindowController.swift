import AppKit

/// The one way to open Settings on a pane.
///
/// Stub for now: it forwards to today's behaviour, the Library & Preferences
/// window (`SessionsControlWindowController`) on the matching tab. A later
/// change gives it its own window with the house settings shell
/// (`SettingsView`, 860 × 620); callers do not change when that lands.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    /// Open Settings on `pane`. Today: the Library & Preferences window on
    /// the matching tab.
    func show(pane: SettingsView.SettingsTab = .providers) {
        WindowCoordinator.shared.showSessionsControl(tab: Self.libraryTab(for: pane))
    }

    /// The Library & Preferences tab that shows the same pane today.
    static func libraryTab(for pane: SettingsView.SettingsTab) -> SessionsControlView.Tab {
        switch pane {
        case .providers: .providers
        case .modes: .modes
        case .prompts: .prompts
        case .glossary: .glossary
        case .general: .general
        }
    }
}
