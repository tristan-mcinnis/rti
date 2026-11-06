import Foundation

/// How long a Recap (⌘⌥R / the primary action) runs. Sticky across sessions
/// — heavy Recap users (a live FGD observer hitting it every few minutes)
/// set their preferred length once instead of re-picking it each time.
///
/// Pure value type: lives in RTICore so `PromptComposer.recap(_:)` is fully
/// self-contained and testable without hosting the app.
public enum RecapDepth: String, CaseIterable {
    case brief, standard, detailed

    public var label: String {
        switch self {
        case .brief: "Brief (1–2 bullets)"
        case .standard: "Standard (3–5 bullets)"
        case .detailed: "Detailed (grouped, ~8–12)"
        }
    }
}
