import Foundation

/// Decodes JSON emitted by LLMs that may wrap it in ``` fences or `json`
/// hints despite the prompt asking for raw JSON. Six analyzer/extractor
/// sites used to each carry their own fence-stripping copy; this is the
/// one place that knowledge lives now.
enum JSONExtractor {

    enum Error: Swift.Error {
        case emptyInput
        case invalidUTF8
        case decode(Swift.Error, raw: String)
    }

    /// Strip optional markdown code fences from a model response.
    /// Tolerates `\`\`\`json\n…\`\`\``, `\`\`\`\n…\`\`\``, and bare `\`\`\``.
    static func stripFences(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        if let nl = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: nl)...])
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode JSON of type `T` from a possibly-fenced model response.
    /// Throws `Error.emptyInput` for blank input, `Error.invalidUTF8` if
    /// the cleaned string can't be encoded as UTF-8, or `Error.decode`
    /// wrapping the underlying decoder error.
    static func decode<T: Decodable>(_ raw: String, as type: T.Type = T.self) throws -> T {
        let cleaned = stripFences(raw)
        guard !cleaned.isEmpty else { throw Error.emptyInput }
        guard let data = cleaned.data(using: .utf8) else { throw Error.invalidUTF8 }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Error.decode(error, raw: cleaned)
        }
    }

    /// Non-throwing variant — returns nil on any failure. Suits the
    /// analyzer controllers, which already treat parse failure as a
    /// "skip this tick" signal rather than a propagated error.
    static func tryDecode<T: Decodable>(_ raw: String, as type: T.Type = T.self) -> T? {
        try? decode(raw, as: type)
    }
}
