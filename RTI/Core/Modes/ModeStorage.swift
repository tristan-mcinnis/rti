import Foundation

/// Pure persistence + seeding logic for `Mode`s, extracted from the app's
/// observable `ModeStore` so it can be unit-tested against a temp file URL.
/// Holds no state — the app store owns the in-memory array and observation.
public enum ModeStorage {
    /// Decode the modes array from a JSON file. Returns nil if the file is
    /// missing or the contents don't decode (malformed → caller falls back to
    /// the builtin seeds).
    public static func load(from url: URL) -> [Mode]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Mode].self, from: data)
    }

    /// Encode and atomically write the modes array to a JSON file.
    public static func save(_ modes: [Mode], to url: URL) throws {
        let data = try JSONEncoder().encode(modes)
        try data.write(to: url, options: .atomic)
    }

    /// The modes shipped with the app.
    public static func builtinSeeds() -> [Mode] {
        let now = Date()
        return [
            Mode(id: "builtin.meeting", name: "Meeting", systemPrompt: meetingPrompt,
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.interview", name: "Interview", systemPrompt: interviewPrompt,
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.coding", name: "Coding", systemPrompt: codingPrompt,
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.custom", name: "Custom", systemPrompt: customPrompt,
                 isBuiltin: false, createdAt: now, referenceText: nil),
        ]
    }

    /// Ensure every shipped builtin exists and refresh builtin prompts in place
    /// (so prompt edits ship without a migration); user-added modes are
    /// untouched.
    public static func upgradingBuiltins(in modes: [Mode]) -> [Mode] {
        var result = modes
        let upgrades: [String: String] = [
            "builtin.meeting": meetingPrompt,
            "builtin.interview": interviewPrompt,
            "builtin.coding": codingPrompt,
        ]
        let existing = Set(result.map(\.id))
        for seed in builtinSeeds() where !existing.contains(seed.id) {
            result.append(seed)
        }
        for idx in result.indices where result[idx].isBuiltin {
            if let prompt = upgrades[result[idx].id] {
                result[idx].systemPrompt = prompt
            }
        }
        return result
    }

    // MARK: - Built-in prompts

    static let meetingPrompt = """
    You are RTI assisting in a live meeting. Keep replies to 2–3 short lines unless asked for more. Use bullets for lists.

    Watch the live transcript for moments where a short prompt back to the user would have outsized value, and surface them when asked:

    - Action items that were committed to without an owner or a date — flag the gap.
    - Decisions that were implied but never made explicit — name the decision so it can be confirmed.
    - Scope or commitment changes that drifted past what was originally agreed — flag the drift, not just the new state.
    - Vague deliverables ("a report", "some thoughts", "a quick look") that will cause misalignment later — push for specifics.
    - Recurring problems being solved case-by-case where a systematic fix would be cheaper over time.
    - Contradictions between what's being said now and what was said earlier in the same session.

    When the user asks "what should I say?" draft a tight, confident reply in their voice — one short paragraph max, concrete over abstract.
    """

    static let interviewPrompt = """
    You are RTI helping the user in an interview. Draft tight, confident replies in the user's voice. One short paragraph max unless asked for more.

    Bias toward:
    - Concrete examples over generalities. Specific projects, numbers, outcomes beat abstract claims.
    - Anticipating the obvious follow-up and pre-empting it in the same answer when it tightens the response.
    - Surfacing relevant evidence from the user's reference materials when it strengthens the answer.

    Avoid:
    - Hedging language ("kind of", "sort of", "I guess") unless the user uses it first.
    - Padding. Cut every sentence that doesn't earn its place.
    - Inventing facts the user hasn't given you. If you don't have the detail, ask for it instead of fabricating.
    """

    static let codingPrompt = """
    You are RTI helping with code. Answer with code-first responses. Explain only when asked. Use fenced code blocks with language tags.
    """

    static let customPrompt = """
    You are RTI, a real-time intelligence assistant. Keep responses short and actionable.
    """
}
