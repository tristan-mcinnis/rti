import Foundation

/// Reads a moderator-copy discussion guide whose questions are bold lines
/// rather than a numbered list (2026-11-15). Invented example:
///
///     ## Section 1: Warm-Up
///     Time: 10 min | ...
///     ** G1  Tell us how you start your morning.**
///     说说您早上一般怎么开始一天。
///     - What do you drink first?
///     - 您早上第一样喝的是什么？
///
/// A bold line is a question; an optional leading tag ("G1", "G2 and G3",
/// "Skip if late") says who it is for. The first Chinese line after it is its
/// Mandarin; `-` lines are probes, an English line paired with the Chinese
/// line after it. With a group, questions tagged for other groups are left
/// out; without one, every question stays and its tag shows in brackets.
/// The skill's parser (`extract-cells.py`) reads numbered guides; this is the
/// fallback RTI uses when that parser finds no numbered questions.
public enum BoldLineGuide {
    /// The guide as `dg-questions` JSON that `GuideDocument.parse` reads, or
    /// nil when the text has no `## Section n:` heading with a bold question.
    public static func json(markdown: String, title: String, group: String?) -> Data? {
        let wanted = group?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var sections: [[String: Any]] = []
        var section: [String: Any]?
        var questions: [[String: Any]] = []
        var question: [String: Any]?
        var part: String?
        var probeEnglish: String?

        func closeQuestion() {
            if let finished = question, (finished["en"] as? String)?.isEmpty == false {
                questions.append(finished)
            }
            question = nil
            probeEnglish = nil
        }
        func closeSection() {
            closeQuestion()
            guard var finished = section, !questions.isEmpty else { questions = []; return }
            let id = finished["id"] as? String ?? "S"
            finished["questions"] = questions.enumerated().map { index, item in
                var item = item
                item["qid"] = "\(id)Q\(index + 1)"
                item["no"] = index + 1
                return item
            }
            sections.append(finished)
            questions = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let heading = match(#"^##\s+(?:Section|SECTION)\s+(\d+)\s*[:：]\s*(.+)$"#, line), !line.hasPrefix("###") {
                closeSection()
                let number = Int(heading[0]) ?? sections.count + 1
                section = ["id": "S\(number)", "no": number, "title": "SECTION \(number): \(heading[1])"]
                part = nil
                continue
            }
            guard section != nil else { continue }
            if line.hasPrefix("###") {
                closeQuestion()
                part = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                continue
            }
            if section?["minutes"] == nil, let minutes = match(#"^Time:\s*(\d+)\s*min"#, line) {
                let heading = section?["title"] as? String ?? ""
                section?["minutes"] = Int(minutes[0])
                section?["title"] = "\(heading) (\(minutes[0]) min)"
                continue
            }
            if let bold = match(#"^\*\*(.+?)\*\*$"#, line) {
                closeQuestion()
                let (groups, text) = tagged(bold[0])
                if let groups, let wanted, !groups.contains(wanted) { continue }
                var english = text
                if let groups, wanted == nil { english = "[\(groups.joined(separator: " and "))] " + text }
                question = ["en": english, "zh": "", "probes": [[String: String]](), "part": part.map { $0 as Any } ?? NSNull()]
                continue
            }
            guard question != nil, !line.isEmpty else { continue }
            if let item = match(#"^[-*]\s+(.+)$"#, line) {
                let text = item[0]
                var probes = question?["probes"] as? [[String: String]] ?? []
                if hasChinese(text) {
                    probes.append(["en": probeEnglish ?? "", "zh": text])
                    probeEnglish = nil
                } else {
                    if let pending = probeEnglish { probes.append(["en": pending, "zh": ""]) }
                    probeEnglish = text
                }
                question?["probes"] = probes
                continue
            }
            if hasChinese(line), (question?["zh"] as? String)?.isEmpty == true {
                question?["zh"] = line
            }
        }
        closeSection()
        guard !sections.isEmpty else { return nil }
        let document: [String: Any] = ["title": title, "frontmatter": ["title": title], "sections": sections]
        return try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    /// ("G1"…) groups and the text, from a bold line's inner text. "Skip if
    /// late" stays in the wording as a bracketed note.
    static func tagged(_ inner: String) -> (groups: [String]?, text: String) {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        if let tag = match(#"^((?:G\d+)(?:\s*(?:and|,|&|/)\s*G\d+)*)\s+(.+)$"#, trimmed) {
            let groups = tag[0].components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.hasPrefix("G") && $0.count > 1 }
            return (groups, tag[1].trimmingCharacters(in: .whitespaces))
        }
        if let skip = match(#"^(?i:skip if late)\s+(.+)$"#, trimmed) {
            return (nil, "[Skip if late] " + skip[0])
        }
        return (nil, trimmed)
    }

    private static func hasChinese(_ text: String) -> Bool {
        text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
    }

    /// The capture groups of the first match, or nil.
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1 ..< found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
