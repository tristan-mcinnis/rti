import Foundation

/// Small deterministic clean-ups applied to a finished live answer, for rules
/// the prompt states but a model does not always keep (2026-11-15 prompt
/// eval).
public enum AnswerCleanup {
    /// Drops a **Pinyin** paragraph whose paragraph above has no Chinese:
    /// pinyin is only ever the reading of the Chinese line right above it.
    public static func dropOrphanPinyin(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        var kept: [String] = []
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("**Pinyin**") {
                let above = kept.last ?? ""
                guard above.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { continue }
            }
            kept.append(paragraph)
        }
        return kept.joined(separator: "\n\n")
    }
}
