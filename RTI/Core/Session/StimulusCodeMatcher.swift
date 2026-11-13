import Foundation

/// Finds the neutral material codes (A1, B12) spoken in a turn. One
/// alternation regex serves a whole pinned stimulus package, so a codebook
/// pass compiles it once, not once per code per turn (perf fix 7).
///
/// A code matches only as a whole token: `A1` never matches inside `A12`
/// or `XA1`. Matching is case-sensitive, as the codes are.
public struct StimulusCodeMatcher {
    /// The valid codes, sorted. A code is letters followed by digits.
    public let codes: [String]
    private let regex: NSRegularExpression?

    public init(codes: some Sequence<String>) {
        let valid = Set(codes.filter { $0.wholeMatch(of: /[A-Za-z]+[0-9]+/) != nil })
        self.codes = valid.sorted()
        // Longest first, so a longer code wins where two share a prefix.
        let alternatives = valid.sorted { ($0.count, $1) > ($1.count, $0) }
            .map(NSRegularExpression.escapedPattern(for:))
        regex = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])(?:" + alternatives.joined(separator: "|") + ")(?![A-Za-z0-9])"
        )
    }

    /// The codes spoken in `text`, sorted and without repeats.
    public func mentioned(in text: String) -> [String] {
        guard let regex, !text.isEmpty else { return [] }
        let string = text as NSString
        var found: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            found.insert(string.substring(with: match.range))
        }
        return found.sorted()
    }
}
