import Foundation
import Observation

/// User-defined glossary of project- or domain-specific terms. Injected
/// into LLM system prompts so the model uses the user's preferred names,
/// spellings, and definitions instead of guessing from context.
///
/// Storage is a single UserDefaults blob — one entry per line, in the
/// shape `Term — meaning` or `Term: meaning`. Blank lines and lines
/// starting with `#` are ignored.
@Observable @MainActor
final class GlossaryStore {
    static let shared = GlossaryStore()

    var rawText: String {
        didSet {
            UserDefaults.standard.set(rawText, forKey: Self.key)
        }
    }

    private static let key = "rti.glossary.rawV1"

    private init() {
        self.rawText = UserDefaults.standard.string(forKey: Self.key) ?? ""
    }

    /// Parsed (term, meaning) pairs in the order the user wrote them.
    /// Empty when the glossary is unconfigured.
    var entries: [(term: String, meaning: String)] {
        var out: [(String, String)] = []
        for raw in rawText.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let separator: Character? = {
                if line.contains("—") { return "—" }
                if line.contains(":") { return ":" }
                if line.contains("-") { return "-" }
                return nil
            }()
            guard let sep = separator,
                  let range = line.firstIndex(of: sep) else { continue }
            let term = line[..<range].trimmingCharacters(in: .whitespaces)
            let meaning = line[line.index(after: range)...].trimmingCharacters(in: .whitespaces)
            if !term.isEmpty && !meaning.isEmpty {
                out.append((term, meaning))
            }
        }
        return out
    }

    /// Returns a system-message fragment ready to append to an LLM call,
    /// or `nil` when the glossary is empty. Caps at the first 200 entries
    /// to keep the system prompt bounded.
    var systemPromptFragment: String? {
        let parsed = entries
        guard !parsed.isEmpty else { return nil }
        let capped = parsed.prefix(200)
        let lines = capped.map { "- \($0.term): \($0.meaning)" }.joined(separator: "\n")
        return """
        Project glossary. Use these terms exactly as written (spelling, casing, definition). When the transcript contains a near-match or paraphrase, prefer the canonical term.

        \(lines)
        """
    }
}
