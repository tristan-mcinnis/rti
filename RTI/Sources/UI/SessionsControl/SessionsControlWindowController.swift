/// Compatibility entry point for older commands. All panes share the workspace.
@MainActor
final class SessionsControlWindowController {
    func show(tab: SessionsControlView.Tab = .providers) {
        WindowCoordinator.shared.showSessionsControl(tab: tab)
    }
}
