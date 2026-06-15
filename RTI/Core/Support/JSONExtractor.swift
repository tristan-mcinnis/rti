import Foundation

/// Decodes JSON emitted by LLMs that may wrap it in ``` fences or `json`
/// hints despite the prompt asking for raw JSON. Six analyzer/extractor
/// sites used to each carry their own fence-stripping copy; this is the
/// one place that knowledge lives now.
public enum JSONExtractor {

    public enum Error: Swift.Error {
        case emptyInput
        case invalidUTF8
        case decode(Swift.Error, raw: String)
    }

    /// Strip optional markdown code fences from a model response.
    /// Tolerates `\`\`\`json\n…\`\`\``, `\`\`\`\n…\`\`\``, and bare `\`\`\``.
    public static func stripFences(_ raw: String) -> String {
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
    public static func decode<T: Decodable>(_ raw: String, as type: T.Type = T.self) throws -> T {
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
    public static func tryDecode<T: Decodable>(_ raw: String, as type: T.Type = T.self) -> T? {
        try? decode(raw, as: type)
    }

    /// Tolerantly decode the array under `key` in a `{ "key": [ {…}, {…} ] }`
    /// response, item by item. Each top-level object inside the array is
    /// extracted by brace-matching and decoded on its own; an item that fails
    /// (a model-typo'd field, a wrong key) is skipped rather than failing the
    /// whole batch, and a truncated trailing object (the response got cut off
    /// mid-stream) simply never closes its braces and is dropped — so we keep
    /// every complete item that arrived. Returns the items that decoded.
    ///
    /// This exists because a single bad item used to sink an entire analysis
    /// tick: one match with `"queries"` instead of `"quotes"` discarded 27 good
    /// matches; a findings response cut off mid-JSON discarded the batch.
    public static func decodeArrayLenient<Item: Decodable>(
        _ raw: String, key: String, as type: Item.Type = Item.self
    ) -> [Item] {
        let cleaned = stripFences(raw)
        guard let keyRange = cleaned.range(of: "\"\(key)\"") else { return [] }
        guard let open = cleaned[keyRange.upperBound...].firstIndex(of: "[") else { return [] }
        let body = cleaned[cleaned.index(after: open)...]

        var objects: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        var i = body.startIndex
        loop: while i < body.endIndex {
            let c = body[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{": if depth == 0 { start = i }; depth += 1
                case "}":
                    depth -= 1
                    if depth == 0, let s = start { objects.append(String(body[s...i])); start = nil }
                case "]" where depth == 0: break loop   // array closed
                default: break
                }
            }
            i = body.index(after: i)
        }

        let decoder = JSONDecoder()
        return objects.compactMap { obj in
            guard let data = obj.data(using: .utf8) else { return nil }
            return try? decoder.decode(Item.self, from: data)
        }
    }
}
