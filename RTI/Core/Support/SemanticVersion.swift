import Foundation

/// Minimal semantic-version parsing + comparison for the update checker.
/// Handles the shapes RTI actually ships: "0.1.0", "v0.2.0", and
/// pre-releases like "0.1.0-beta9". Per semver, a pre-release sorts *below*
/// the same core version without one, and numeric pre-release identifiers
/// compare numerically (beta9 < beta10).
public struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated pre-release identifiers ("beta9" → ["beta9"]); empty for a
    /// final release.
    public let prerelease: [String]

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }

        let coreAndPre = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = coreAndPre[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !coreParts.isEmpty else { return nil }

        func intAt(_ i: Int) -> Int? {
            guard i < coreParts.count else { return 0 } // "1.2" → patch 0
            return Int(coreParts[i])
        }
        guard let ma = intAt(0), let mi = intAt(1), let pa = intAt(2) else { return nil }
        major = ma
        minor = mi
        patch = pa
        prerelease = coreAndPre.count > 1
            ? coreAndPre[1].split(separator: ".").map(String.init)
            : []
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // Equal core: a release (no prerelease) outranks a prerelease.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false // lhs release ≥ rhs prerelease
        case (false, true): return true // lhs prerelease < rhs release
        case (false, false): return comparePrerelease(lhs.prerelease, rhs.prerelease)
        }
    }

    private static func comparePrerelease(_ a: [String], _ b: [String]) -> Bool {
        for (x, y) in zip(a, b) where x != y {
            // Numeric-aware: split "beta9" into ("beta", 9) so beta9 < beta10.
            let (xa, xn) = splitTrailingNumber(x)
            let (ya, yn) = splitTrailingNumber(y)
            if xa == ya, let xn, let yn { return xn < yn }
            return x < y
        }
        return a.count < b.count
    }

    private static func splitTrailingNumber(_ s: String) -> (String, Int?) {
        let digits = s.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty else { return (s, nil) }
        let numStr = String(digits.reversed())
        let alpha = String(s.dropLast(numStr.count))
        return (alpha, Int(numStr))
    }
}
