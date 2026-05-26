import Foundation
import Observation

/// In-memory catalogue of user-spawned panels for the current run. Panels are
/// products of the live chat session (spawned via the `spawn_panel` tool) and
/// don't persist across launches — there's no transcript database to anchor
/// them to. Views observe `panels` to add/remove their hosting NSPanel windows;
/// the store does not own the windows themselves — that's `WindowCoordinator`.
@Observable @MainActor
final class UserPanelStore {
    static let shared = UserPanelStore()

    private(set) var panels: [UserPanel] = []

    private init() {}

    func add(_ panel: UserPanel) {
        panels.append(panel)
    }

    /// Wipe every user panel. Used by "Clear Current Chat" since user panels
    /// are products of the chat session.
    func removeAll() {
        panels.removeAll()
    }

    func remove(id: String) {
        panels.removeAll { $0.id == id }
    }

    /// Update an existing panel's config in place (rename/edit) without
    /// re-spawning the window.
    func update(_ panel: UserPanel) {
        if let idx = panels.firstIndex(where: { $0.id == panel.id }) {
            panels[idx] = panel
        }
    }
}
