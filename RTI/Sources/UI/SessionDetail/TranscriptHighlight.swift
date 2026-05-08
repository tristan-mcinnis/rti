import Foundation
import SwiftUI

/// Pure helpers for highlighting search matches inside a session's
/// transcript. Used by `SessionDetailView` when the user opens a session
/// from the command palette with a non-empty query.
///
/// Tokenisation matches `SessionSearch.makeFTSQuery` so what the FTS index
/// matched is what we visually highlight.
enum TranscriptHighlight {

    /// Split a free-text query into the same alphanumeric tokens that
    /// `SessionSearch` feeds to FTS5. Lowercased and de-duplicated.
    static func tokens(from query: String) -> [String] {
        let raw = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var out: [String] = []
        for tok in raw where seen.insert(tok).inserted {
            out.append(tok)
        }
        return out
    }

    /// Index of the first element in `texts` that contains any token from
    /// `query`, case-insensitively. Nil if no element matches.
    static func firstMatchIndex<S: Sequence>(in texts: S, query: String) -> Int?
    where S.Element == String {
        let toks = tokens(from: query)
        guard !toks.isEmpty else { return nil }
        for (i, t) in texts.enumerated() {
            let lower = t.lowercased()
            if toks.contains(where: { lower.contains($0) }) {
                return i
            }
        }
        return nil
    }

    /// Build an `AttributedString` from `text` with each matched token
    /// background-highlighted. If `query` is nil/empty or has no tokens,
    /// returns `AttributedString(text)` unchanged.
    static func attributed(_ text: String, query: String?) -> AttributedString {
        var attr = AttributedString(text)
        guard let query, !query.isEmpty else { return attr }
        let toks = tokens(from: query)
        guard !toks.isEmpty else { return attr }
        for token in toks {
            highlightAll(of: token, in: &attr)
        }
        return attr
    }

    private static func highlightAll(of token: String, in attr: inout AttributedString) {
        var cursor = attr.startIndex
        while cursor < attr.endIndex,
              let range = attr[cursor..<attr.endIndex].range(of: token, options: .caseInsensitive) {
            attr[range].backgroundColor = Color.yellow.opacity(0.35)
            attr[range].foregroundColor = Color.primary
            cursor = range.upperBound
        }
    }
}
