import Foundation

/// One row in the command palette. Either an action (existing `RTICommand`)
/// or a session match from the FTS index. The palette renders both kinds in
/// a single keyboard-navigable list, sectioned by case.
enum PaletteResult: Identifiable {
    case command(RTICommand)
    case session(SessionSearchResult)

    var id: String {
        switch self {
        case .command(let c): return "cmd:\(c.id)"
        case .session(let s): return "sess:\(s.id)"
        }
    }

    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }

    var isSession: Bool {
        if case .session = self { return true }
        return false
    }
}

/// Pure composer: blends command results and session-search results into the
/// ordered list the palette displays. Held separate from the view so the
/// ordering rules are unit-testable without spinning up SwiftUI or SQLite.
enum PaletteSearch {
    /// Default cap on session rows shown in the palette. The full result set
    /// lives in the Sessions tab — the palette is for "I know what I want,
    /// get me there fast."
    static let defaultSessionLimit = 6

    /// Compose results.
    /// - Empty query → commands only, ordered as caller passed them
    ///   (typically recents-first via `CommandRegistry.search("")`).
    /// - Non-empty query → commands first (already filtered by the registry),
    ///   then up to `sessionLimit` session matches.
    /// - If both lists are empty for a non-empty query, the result is empty
    ///   so the view can render its "no matches" empty state.
    static func compose(
        query: String,
        commands: [RTICommand],
        sessions: [SessionSearchResult],
        sessionLimit: Int = defaultSessionLimit
    ) -> [PaletteResult] {
        let cmdResults = commands.map(PaletteResult.command)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return cmdResults
        }
        let cappedSessions = Array(sessions.prefix(max(0, sessionLimit)))
        return cmdResults + cappedSessions.map(PaletteResult.session)
    }
}
