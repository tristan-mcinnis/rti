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
    ///
    /// Also: transcripts or a report, "what did they say", a place named
    /// after "in" (a city in a past study: "in Chengdu", "in London"), a
    /// Chinese past-work word (上次, 之前, 报告, 访谈, 逐字稿, 他们说), and a
    /// Chinese term in quotes (what do they say about "不会出错").
    public static func asksForPastWork(_ question: String) -> Bool {
        let pattern = #"\b(vault|previous|prior|earlier|last time|last week|history|look up|find|search|what did we|did we decide|recent meetings?|transcripts?|reports?|what (did|do|does) (they|people|participants|respondents|he|she) say)\b"#
        if question.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if question.range(of: #"上次|之前|以前|报告|访谈|转录|逐字稿|他们(怎么|都)?说"#, options: .regularExpression) != nil { return true }
        if question.range(of: #"["“'‘「『]\p{Han}[^"”'’」』]{0,20}["”'’」』]"#, options: .regularExpression) != nil { return true }
        return namesAPlace(question)
    }

    /// Words after "in" that name a language, a month or a period, not a place.
    private static let notPlaces: Set<String> = [
        "english", "mandarin", "chinese", "cantonese", "japanese", "korean", "thai", "french", "spanish",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "q1", "q2", "q3", "q4", "general", "particular", "short", "total", "fact",
    ]

    /// Cities where studies often run, matched in any case after "in".
    private static let knownPlaces = [
        "beijing", "shanghai", "guangzhou", "shenzhen", "chengdu", "chongqing", "hangzhou", "wuhan", "nanjing",
        "xi'an", "xian", "tianjin", "suzhou", "hong kong", "taipei", "tokyo", "osaka", "seoul", "singapore",
        "bangkok", "jakarta", "kuala lumpur", "manila", "ho chi minh", "mumbai", "delhi", "sydney", "london",
        "paris", "new york", "los angeles", "mexico city", "atlanta",
    ]

    /// "in Chengdu", "in London": a known city in any case, or a
    /// capitalised word after a lower-case "in" that is not a language,
    /// month or common phrase.
    static func namesAPlace(_ question: String) -> Bool {
        let lower = question.lowercased()
        if knownPlaces.contains(where: { lower.contains("in \($0)") }) { return true }
        for match in question.matches(of: /\bin ([A-Z][A-Za-z'-]+)/) {
            if !notPlaces.contains(String(match.output.1).lowercased()) { return true }
        }
        return false
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
