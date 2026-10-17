import Foundation

/// Decodes JSON emitted by LLMs that may wrap it in ``` fences or `json`
/// hints despite the prompt asking for raw JSON. Fence stripping lives in
/// this one place.
public enum JSONExtractor {
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

    /// Tolerantly decode the array under `key` in a `{ "key": [ {…}, {…} ] }`
    /// response, item by item. Each top-level object inside the array is
    /// extracted by brace-matching and decoded on its own; an item that fails
    /// (a model-typo'd field, a wrong key) is skipped rather than failing the
    /// whole batch, and a truncated trailing object (the response got cut off
    /// mid-stream) simply never closes its braces and is dropped — so we keep
    /// every complete item that arrived. Returns the items that decoded.
    ///
    /// This exists because a single bad item used to sink a whole Auto-mode
    /// batch, and a response cut off mid-JSON discarded every card in it.
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
