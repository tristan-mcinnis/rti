import Foundation

/// How the Meeting Brief window's rail groups and filters the vault's
/// pre-meeting briefs. Pure, so the sections are pinned by tests.
///
/// Briefs are named `yyyy-MM-dd-<slug>`, so a brief's day is a string that
/// sorts like a date. Today's briefs come first, then the ones still ahead
/// (nearest first), then the past ones (newest first).
public enum BriefRail {
    /// One brief as the rail lists it.
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        /// `yyyy-MM-dd`, or nil when the file name carries no day.
        public let day: String?

        public init(id: String, title: String, day: String?) {
            self.id = id
            self.title = title
            self.day = day
        }
    }

    /// A labelled run of rows.
    public struct Section: Equatable, Sendable {
        public let title: String
        public let items: [Item]
    }

    public static let todayTitle = "Today"
    public static let upcomingTitle = "Upcoming"
    public static let earlierTitle = "Earlier"
    public static let resultsTitle = "Results"

    /// The rail's sections for `items` on `today` (`yyyy-MM-dd`). With a
    /// query, one Results section of the briefs whose title (or day) holds
    /// every word of it, newest first. Empty sections are left out.
    public static func sections(for items: [Item], query: String, today: String) -> [Section] {
        let needles = words(in: query)
        if !needles.isEmpty {
            let hits = items
                .filter { item in
                    let haystack = words(in: item.title + " " + (item.day ?? ""))
                    return needles.allSatisfy { needle in haystack.contains { $0.hasPrefix(needle) } }
                }
                .sorted { ($0.day ?? "") > ($1.day ?? "") }
            return hits.isEmpty ? [] : [Section(title: resultsTitle, items: hits)]
        }

        let todays = items.filter { $0.day == today }
        let upcoming = items
            .filter { ($0.day ?? "") > today }
            .sorted { ($0.day ?? "") < ($1.day ?? "") }
        let earlier = items
            .filter { $0.day == nil || ($0.day ?? "") < today }
            .sorted { ($0.day ?? "") > ($1.day ?? "") }
        return [
            Section(title: todayTitle, items: todays),
            Section(title: upcomingTitle, items: upcoming),
            Section(title: earlierTitle, items: earlier),
        ].filter { !$0.items.isEmpty }
    }

    /// The rows in the order the rail draws them, for `↑↓` and `⌘1`…`⌘9`.
    public static func flattened(_ sections: [Section]) -> [Item] {
        sections.flatMap(\.items)
    }

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
