import Foundation
import Observation

/// Singleton registry of built-in analysis panels. Centralises the mapping
/// from `FloatingPanelID` to its human-readable title and toggle notification
/// so adding a new built-in panel only touches `FloatingPanelID` + its spec
/// instead of also updating AppDelegate, NotificationNames, and
/// CommandPaletteFactory by hand.
///
/// The `UserPanelStore` pattern (data-driven, keyed by ID) inspired this
/// store, but built-in panels are singletons — there's no spawn/teardown
/// lifecycle, just show/hide.
@Observable @MainActor
final class AnalysisPanelStore {
    static let shared = AnalysisPanelStore()

    struct Descriptor: Identifiable {
        let id: FloatingPanelID
        let title: String
        let notificationName: Notification.Name
    }

    /// Every built-in analysis panel, in display order.
    let all: [Descriptor] = [
        Descriptor(id: .notes, title: "Notes", notificationName: .rtiToggleNotesPanel),
        Descriptor(id: .dossiers, title: "Dossiers", notificationName: .rtiToggleDossiersPanel),
        Descriptor(id: .themes, title: "Themes", notificationName: .rtiToggleThemesPanel),
        Descriptor(id: .discussionGuide, title: "Discussion Guide", notificationName: .rtiToggleGuidePanel),
        Descriptor(id: .translation, title: "Translation", notificationName: .rtiToggleTranslationPanel),
    ]

    /// Which built-in panels are currently visible. Updated by `toggle(_:)`
    /// and kept in sync with `WindowCoordinator` via notification.
    var activePanels: Set<FloatingPanelID> = []

    /// Return the subset of `panelIDs` that are registered in `all`.
    func descriptors(for panelIDs: Set<FloatingPanelID>) -> [Descriptor] {
        all.filter { panelIDs.contains($0.id) }
    }

    func isVisible(_ id: FloatingPanelID) -> Bool {
        activePanels.contains(id)
    }

    /// Toggle visibility and post the per-panel notification so
    /// `WindowCoordinator` can show/hide the actual `NSPanel`.
    func toggle(_ id: FloatingPanelID) {
        if activePanels.contains(id) {
            activePanels.remove(id)
        } else {
            activePanels.insert(id)
        }
        guard let descriptor = all.first(where: { $0.id == id }) else { return }
        NotificationCenter.default.post(name: descriptor.notificationName, object: nil)
    }
}
