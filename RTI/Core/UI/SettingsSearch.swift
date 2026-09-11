import Foundation

/// The rules behind the settings window's rail: which panes a typed search
/// keeps, and which `⌘`-number the footer's "Next" names. Pure, so the
/// rail and its tests agree.
public enum SettingsSearch {
    /// One pane as the rail lists it.
    public struct Pane: Equatable, Sendable {
        public let id: String
        public let title: String
        /// Words for settings that live inside the pane ("microphone" finds
        /// General), so a search reaches a setting, not only a pane name.
        public let keywords: [String]

        public init(id: String, title: String, keywords: [String] = []) {
            self.id = id
            self.title = title
            self.keywords = keywords
        }
    }

    /// The panes that match `query`, in rail order. A pane matches when
    /// every word of the query starts a word of its title or keywords,
    /// ignoring case and accents. An empty query keeps every pane.
    public static func filter(_ panes: [Pane], query: String) -> [Pane] {
        let needles = words(in: query)
        guard !needles.isEmpty else { return panes }
        return panes.filter { pane in
            let haystack = words(in: ([pane.title] + pane.keywords).joined(separator: " "))
            return needles.allSatisfy { needle in haystack.contains { $0.hasPrefix(needle) } }
        }
    }

    /// The `⌘`-number of the pane after the one at `index` (1-based, as the
    /// keys are), wrapping from the last pane to the first.
    public static func nextNumber(after index: Int, count: Int) -> Int {
        guard count > 0 else { return 1 }
        return (index + 1) % count + 1
    }

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
