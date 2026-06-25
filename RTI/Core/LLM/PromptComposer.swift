import Foundation

/// Pure composition of the parameterized prompts (recap, assist, follow-ups,
/// summary) from their leaf `PromptID`s, with the leaf text supplied by an
/// injected resolver.
///
/// The resolver is the seam that lets the SAME composition logic serve both the
/// pure defaults (tests, `PromptCatalogue`) and the override-aware app
/// (`PromptStore`): pass `{ $0.defaultText }` for defaults, or
/// `{ PromptStore.shared.text($0) }` for user-edited prompts. Composition lives
/// here once instead of being duplicated across those two layers.
public enum PromptComposer {
    /// A leaf-text resolver. `PromptDefaults`-backed by default. Deliberately
    /// non-`Sendable`: the app's resolver captures a `@MainActor` store and is
    /// only ever called synchronously on that actor.
    public typealias Resolver = (PromptID) -> String

    /// The default resolver: every leaf returns its shipped default. A computed
    /// property (not a stored `static let`) so it sidesteps the global
    /// shared-mutable-state concurrency check on a non-Sendable closure.
    public static var defaultResolver: Resolver {
        { $0.defaultText }
    }

    // MARK: - Recap

    /// The `PromptID` carrying the depth-specific bullet clause.
    public static func recapClauseID(for depth: RecapDepth) -> PromptID {
        switch depth {
        case .brief: .recapBrief
        case .standard: .recapStandard
        case .detailed: .recapDetailed
        }
    }

    public static func recap(_ depth: RecapDepth, resolve: Resolver = defaultResolver) -> String {
        "Recap the conversation so far \(resolve(recapClauseID(for: depth))) \(resolve(.recapLanguageRule))"
    }

    // MARK: - Quick actions

    public static func assist(listener: Bool, resolve: Resolver = defaultResolver) -> String {
        resolve(listener ? .listenerAssist : .assistSpeaker)
    }

    public static func followups(listener: Bool, resolve: Resolver = defaultResolver) -> String {
        resolve(listener ? .listenerFollowups : .followupsSpeaker)
    }

    // MARK: - Summary

    public static func summary(for kind: ModeKind, resolve: Resolver = defaultResolver) -> String {
        switch kind {
        case .interview: resolve(.interviewSummary)
        default: resolve(.meetingSummary)
        }
    }
}
