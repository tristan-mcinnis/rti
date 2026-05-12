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
    }

    /// Every built-in analysis panel, in display order.
    let all: [Descriptor] = [
        Descriptor(id: .notes, title: "Notes"),
        Descriptor(id: .dossiers, title: "Dossiers"),
        Descriptor(id: .themes, title: "Themes"),
        Descriptor(id: .discussionGuide, title: "Discussion Guide"),
        Descriptor(id: .translation, title: "Translation"),
    ]

    /// Which built-in panels are currently visible. Updated by `toggle(_:)`.
    var activePanels: Set<FloatingPanelID> = []

    /// Return the subset of `panelIDs` that are registered in `all`.
    func descriptors(for panelIDs: Set<FloatingPanelID>) -> [Descriptor] {
        all.filter { panelIDs.contains($0.id) }
    }

    func isVisible(_ id: FloatingPanelID) -> Bool {
        activePanels.contains(id)
    }

    /// Toggle visibility — flips the active set and asks
    /// `WindowCoordinator` to show/hide the actual `NSPanel`.
    func toggle(_ id: FloatingPanelID) {
        if activePanels.contains(id) {
            activePanels.remove(id)
        } else {
            activePanels.insert(id)
        }
        WindowCoordinator.shared.toggle(id)
    }
}
