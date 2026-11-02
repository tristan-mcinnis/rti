import Foundation

/// Pure retrieval-policy helpers shared by the Ask/Answer-latest lanes.
/// Foundation-only and stateless so the test bundle compiles them directly
/// (LLMController itself is not part of the test target).
public enum RetrievalHeuristics {
    public static func compactKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// True when an Ask question is high-stakes enough that a failed vault
    /// search must be surfaced as a hard "nothing here" rather than softened:
    /// it names a known project/client by name, or it repeats (normalized) a
    /// question already asked earlier in this session.
    public static func shouldForceVaultSearch(query: String, workstreamNames: [String], recentQuestions: [String]) -> Bool {
        let compact = compactKey(query)
        guard !compact.isEmpty else { return false }
        if workstreamNames.contains(where: { name in
            let key = compactKey(name)
            return !key.isEmpty && compact.contains(key)
        }) {
            return true
        }
        return recentQuestions.contains { compactKey($0) == compact }
    }

    /// True when the user's own words ask for past work. In a live call this
    /// is the only thing that opens the vault tools: "research", "brief" and
    /// the client's name come up in every question, and the answer must be fast.
    public static func asksForPastWork(_ question: String) -> Bool {
        let pattern = #"\b(vault|previous|prior|earlier|last time|last week|history|look up|find|search|what did we|did we decide|recent meetings?)\b"#
        return question.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Vault retrieval is an intentional assist, not the default for every
    /// conversational turn. Search when a project is actively selected, the
    /// question names known vault context, or it clearly asks about past or
    /// document-backed material. This keeps a simple live question from being
    /// polluted by semantically-near but unrelated vault notes.
    public static func shouldSearchVault(
        query: String,
        hasSelectedScope: Bool,
        workstreamNames: [String],
        recentQuestions: [String]
    ) -> Bool {
        if hasSelectedScope || shouldForceVaultSearch(query: query, workstreamNames: workstreamNames, recentQuestions: recentQuestions) {
            return true
        }
        let intentPattern = #"\b(vault|file|document|docs?|project|client|brief|meeting|session|previous|prior|earlier|history|research|status|past)\b"#
        return query.range(of: intentPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
