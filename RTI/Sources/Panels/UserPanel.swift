import Foundation

/// One configured live panel. Counter panels match keywords/regex against the
/// streaming transcript. Held in memory only — panels are products of the live
/// chat session and don't outlive the app.
struct UserPanel: Identifiable, Equatable {
    let id: String
    let kind: PanelKind
    var config: PanelConfig
    let createdAt: Date

    /// Human-friendly title pulled from the config. Used in window titles and
    /// the right-click menu so we never show a raw uuid to the user.
    var displayTitle: String {
        switch kind {
        case .counter:
            return config.counter?.label ?? "Counter"
        }
    }
}
