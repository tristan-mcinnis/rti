import Foundation

/// How long a Recap (⌘⌥R / the primary action) runs. Sticky across sessions
/// — heavy Recap users (a live FGD observer hitting it every few minutes)
/// set their preferred length once instead of re-picking it each time.
///
/// Pure value type: lives in RTICore so `PromptCatalogue.recap(_:)` is fully
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

    /// The depth-specific clause spliced into the shared recap prompt. Sourced
    /// from the prompt registry so it stays a single editable default.
    public var instruction: String {
        PromptComposer.recapClauseID(for: self).defaultText
    }
}

/// The catalogue of assistant prompts, exposed as the pure DEFAULT-resolved
/// facade over the prompt registry.
///
/// The default text of each prompt now lives in `PromptID`/`PromptDefaults`
/// (the single source the Settings editor and the offline lab also read), and
/// the parameterized composition lives in `PromptComposer`. This enum keeps the
/// original call-site API (`PromptCatalogue.recap(_:)`, `.assist(listener:)`,
/// …) resolving to defaults, so the controllers and the test-suite are
/// unchanged. The override-aware variants live in `PromptStore` (app side).
public enum PromptCatalogue {
    // MARK: - System

    /// The RTI default system message, used when the active mode has no system
    /// prompt of its own.
    public static var system: String {
        PromptID.systemDefault.defaultText
    }

    // MARK: - Quick actions (speaker / participant framing)

    /// Assist — "what should I say next". Listener variant surfaces what was
    /// learned instead, since an observer never speaks.
    public static func assist(listener: Bool) -> String {
        PromptComposer.assist(listener: listener)
    }

    /// Say next — a one-line draft reply. No listener variant (an observer never
    /// speaks).
    public static var sayNext: String {
        PromptID.sayNext.defaultText
    }

    /// Follow-up questions. The listener variant frames them as questions to pass
    /// to the discussion leader.
    public static func followups(listener: Bool) -> String {
        PromptComposer.followups(listener: listener)
    }

    // MARK: - Recap

    /// Recap the conversation so far at the requested depth. The language/format
    /// rule is shared across depths, so the logged prompt only varies in the
    /// bullet-count clause.
    public static func recap(_ depth: RecapDepth) -> String {
        PromptComposer.recap(depth)
    }

    // MARK: - Summary (mode-shaped)

    /// Pick the end-of-session / on-demand summary prompt for the session's
    /// mode: interviews get a research debrief, everything else gets minutes.
    public static func summary(for kind: ModeKind) -> String {
        PromptComposer.summary(for: kind)
    }

    // MARK: - Listener research actions (fieldwork observer)

    /// Key tensions — points where participants disagree or are torn.
    public static var keyTensions: String {
        PromptID.keyTensions.defaultText
    }

    /// What's unsaid / probe — threads a good moderator should chase next.
    public static var probe: String {
        PromptID.probe.defaultText
    }

    /// Emerging themes — recurring needs/attitudes/patterns starting to cohere.
    public static var themes: String {
        PromptID.themes.defaultText
    }
}
