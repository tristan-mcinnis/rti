import Foundation
import RTICore

/// Deterministic parser for house-format discussion guides.
/// Maps the regular markdown structure straight to the guide model, no LLM
/// round-trip — instant, offline, and lossless:
///
///   `## …`              → Objective
///   `**Objective:** …`  → that objective's description
///   `### …`             → Section
///   `1.` `2.` `Q1.` `1)`→ Question (the EN line; an immediately-following
///                         non-numbered line — the 中文 translation — is
///                         appended to the same question so the live matcher
///                         can hit either language)
///   `- Probe:` / `- …`  → dropped (moderator prompts, not guide questions to
///                         track coverage on)
///
/// YAML frontmatter (`---…---`), the `[TYPE: …]` tag, timing notes, and stray
/// horizontal rules are skipped. If there's no `##`/`###` scaffolding but there
/// IS a numbered list, the whole thing becomes one objective/section so a plain
/// numbered guide still parses.
///
/// Returns nil when there's no recognisable guide structure (foreign formats,
/// mangled exports) — the controller then falls back to the LLM parser. A
/// successful parse requires at least two questions, so a stray numbered line in
/// prose can't masquerade as a guide.
enum GuideParser {

    static func parse(_ text: String) -> [GuideObjective]? {
        var objectives: [MutableObjective] = []
        // Frontmatter state: 0 = not yet seen, 1 = inside, 2 = closed.
        var frontmatter = 0
        var lastQuestion: (obj: Int, sec: Int, q: Int)?

        @discardableResult
        func ensureObjective() -> Int {
            if objectives.isEmpty { objectives.append(MutableObjective(title: "Discussion guide")) }
            return objectives.count - 1
        }
        func ensureSection(in obj: Int) -> Int {
            if objectives[obj].sections.isEmpty {
                objectives[obj].sections.append(MutableSection(title: objectives[obj].title))
            }
            return objectives[obj].sections.count - 1
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // The first `---…---` block at the very top is YAML frontmatter;
            // later `---` are horizontal rules and are ignored.
            if line == "---" {
                if frontmatter == 0, objectives.isEmpty { frontmatter = 1 }
                else if frontmatter == 1 { frontmatter = 2 }
                lastQuestion = nil
                continue
            }
            if frontmatter == 1 { continue }

            if line.isEmpty { lastQuestion = nil; continue }
            if line.hasPrefix("[TYPE:") { continue }

            if line.hasPrefix("## ") {
                objectives.append(MutableObjective(title: stripBold(String(line.dropFirst(3)))))
                lastQuestion = nil
                continue
            }
            if line.hasPrefix("### ") {
                let o = ensureObjective()
                objectives[o].sections.append(MutableSection(title: stripBold(String(line.dropFirst(4)))))
                lastQuestion = nil
                continue
            }
            if let desc = objectiveDescription(line) {
                let o = ensureObjective()
                if objectives[o].description == nil { objectives[o].description = desc }
                lastQuestion = nil
                continue
            }
            // Bullets / probes: dropped. They also end question continuation.
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.lowercased().hasPrefix("probe:") {
                lastQuestion = nil
                continue
            }
            if let q = numberedQuestion(line) {
                let o = ensureObjective()
                let s = ensureSection(in: o)
                objectives[o].sections[s].questions.append(MutableQuestion(text: q))
                lastQuestion = (o, s, objectives[o].sections[s].questions.count - 1)
                continue
            }
            // Continuation: a non-numbered line right under a question is its
            // translation / wrap — fold it into that question's text.
            if let ref = lastQuestion {
                objectives[ref.obj].sections[ref.sec].questions[ref.q].text += "\n" + line
                continue
            }
            // Else: preamble prose, methodology, timing — ignored.
        }

        let total = objectives.reduce(0) { $0 + $1.sections.reduce(0) { $0 + $1.questions.count } }
        guard !objectives.isEmpty, total >= 2 else { return nil }

        return objectives.enumerated().map { oi, o in
            let oid = "obj_\(oi + 1)"
            return GuideObjective(
                id: oid,
                title: o.title,
                description: o.description,
                sections: o.sections.enumerated().map { si, s in
                    let sid = "\(oid)_sec_\(si + 1)"
                    return GuideSection(
                        id: sid,
                        title: s.title,
                        questions: s.questions.enumerated().map { qi, q in
                            GuideQuestion(
                                id: "\(sid)_q\(qi + 1)",
                                text: q.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                status: .pending,
                                response: nil
                            )
                        }
                    )
                },
                takeaway: nil
            )
        }
    }

    // MARK: - line matchers

    private struct MutableObjective { var title: String; var description: String?; var sections: [MutableSection] = []
        init(title: String, description: String? = nil) { self.title = title; self.description = description }
    }
    private struct MutableSection { var title: String; var questions: [MutableQuestion] = [] }
    private struct MutableQuestion { var text: String }

    private static func objectiveDescription(_ line: String) -> String? {
        let lower = line.lowercased()
        guard lower.hasPrefix("**objective:**") || lower.hasPrefix("objective:") else { return nil }
        guard let colon = line.range(of: ":") else { return nil }
        let after = String(line[colon.upperBound...])
        let trimmed = stripBold(after).trimmingCharacters(in: CharacterSet(charactersIn: " *"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Match `1.` `2)` `Q1.` `Q1)` `Q1 ` style question leads. Returns the
    /// question text (bold stripped), or nil if the line isn't a numbered item.
    private static func numberedQuestion(_ line: String) -> String? {
        var work = line
        if work.hasPrefix("**") { work.removeFirst(2) }   // tolerate "**1. …"
        let chars = Array(work)
        var i = 0
        let qPrefixed = i < chars.count && (chars[i] == "Q" || chars[i] == "q")
        if qPrefixed { i += 1 }
        let digitStart = i
        while i < chars.count, chars[i].isNumber { i += 1 }
        guard i > digitStart else { return nil }          // need at least one digit
        // Separator: "." or ")" — or, for a Q-prefixed lead, a bare space.
        if i < chars.count, chars[i] == "." || chars[i] == ")" {
            i += 1
        } else if !(qPrefixed && i < chars.count && (chars[i] == " " || chars[i] == "\t")) {
            return nil
        }
        guard i < chars.count, chars[i] == " " || chars[i] == "\t" else { return nil }
        let text = stripBold(String(chars[i...]).trimmingCharacters(in: .whitespaces))
        return text.isEmpty ? nil : text
    }

    private static func stripBold(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("**") { t.removeFirst(2) }
        while t.hasSuffix("**") { t.removeLast(2) }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
