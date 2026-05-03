import Foundation

/// Shared helpers for summary section assembly.
enum SummaryFormatting {

    /// Combine "Open Questions" and "Next Steps" sections into a single
    /// markdown block. Returns `nil` if both inputs are empty/None.
    static func combineFollowUps(openQuestions: String?, nextSteps: String?) -> String? {
        var parts: [String] = []
        if let q = openQuestions, q != "None.", !q.isEmpty {
            parts.append("## Open Questions\n\(q)")
        }
        if let s = nextSteps, s != "None.", !s.isEmpty {
            parts.append("## Next Steps\n\(s)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
