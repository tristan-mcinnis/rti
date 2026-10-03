import Foundation
import os

// The pure rules behind the Sessions window's list rail (house chat grammar,
// design-system docs/chat-surfaces.md section 5): date groups, the row's
// second line, title filtering, content snippets, and the window's keys.
// No AppKit, no file reads, so every rule is unit-tested in RTITests.

/// What the rail knows about one archived session.
public struct SessionRailItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let startedAt: Date?
    public let durationSeconds: Int?
    public let project: String?
    public let mode: String?
    /// Names given to the session's speakers ("Anna Lu"), for filtering.
    public let speakerNames: [String]
    /// Canonical stamp `yyyyMMdd-HHmmss`, the key vault notes and search
    /// results use for this session.
    public let stamp: String?

    public init(
        id: String,
        title: String,
        startedAt: Date?,
        durationSeconds: Int? = nil,
        project: String? = nil,
        mode: String? = nil,
        speakerNames: [String] = [],
        stamp: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.project = project
        self.mode = mode
        self.speakerNames = speakerNames
        self.stamp = stamp
    }
}

/// The rail's date sections, newest first (house date groups; RTI has no
/// pinning).
public enum SessionRailGroup: String, CaseIterable, Sendable {
    case today = "Today"
    case thisWeek = "This week"
    case earlier = "Earlier"
}

/// One row's snippet: where a content search found it, with the query
/// terms marked. "Transcript: …flat zero scope…".
public struct SessionSnippet: Equatable, Sendable {
    public struct Run: Equatable, Sendable {
        public let text: String
        public let isMatch: Bool

        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    /// "Transcript:", "Notes:", "Summary:", "Chat:", or "Meeting note:".
    public let label: String
    public let runs: [Run]

    public init(label: String, runs: [Run]) {
        self.label = label
        self.runs = runs
    }

    public var text: String { runs.map(\.text).joined() }
    /// What VoiceOver and a tooltip read.
    public var plainText: String { label.isEmpty ? text : "\(label) \(text)" }

    /// The same snippet with at most `characters` before the first match,
    /// so the match stays in view on a narrow row (the rail).
    public func keepingLead(_ characters: Int) -> SessionSnippet {
        guard let firstMatch = runs.firstIndex(where: \.isMatch) else { return self }
        let lead = runs[..<firstMatch].map(\.text).joined()
        guard lead.count > characters else { return self }
        var kept = String(lead.suffix(characters))
        // Start at a word when one starts close by.
        if let space = kept.firstIndex(of: " ") {
            kept = String(kept[kept.index(after: space)...])
        }
        let newLead: [Run] = [Run(text: "…" + kept, isMatch: false)]
        return SessionSnippet(label: label, runs: newLead + runs[firstMatch...])
    }
}

public enum SessionsWindowRules {
    /// A content search needs at least this many characters.
    public static let minimumContentQueryLength = 3
    /// Pause after the last keystroke before a content search runs.
    public static let contentSearchDelay: Duration = .milliseconds(250)
    /// Characters kept on each side of a snippet's first match.
    public static let snippetContext = 40

    // MARK: - Groups

    /// Today, this week (the six days before today), then earlier. Items
    /// keep their order inside a group; empty groups are left out.
    public static func grouped(
        _ items: [SessionRailItem],
        now: Date,
        calendar: Calendar = .current
    ) -> [(group: SessionRailGroup, items: [SessionRailItem])] {
        var buckets: [SessionRailGroup: [SessionRailItem]] = [:]
        for item in items {
            buckets[group(for: item.startedAt, now: now, calendar: calendar), default: []].append(item)
        }
        return SessionRailGroup.allCases.compactMap { group in
            buckets[group].map { (group, $0) }
        }
    }

    public static func group(for date: Date?, now: Date, calendar: Calendar = .current) -> SessionRailGroup {
        guard let date else { return .earlier }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekStart = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekStart, date < startOfToday {
            return .thisWeek
        }
        return .earlier
    }

    // MARK: - Row text

    /// The row's second line: "15:00 · 16 min · Northwind app" today,
    /// "Sep 4 · 16 min · Northwind app" before (house rail rule: time today,
    /// day before). It never repeats what the title already says: a
    /// fallback title names the day and length ("Meeting · Sep 4, 15:00 ·
    /// 16 min"), a short test its length ("Short test · 12 s").
    public static func detailLine(
        for item: SessionRailItem,
        titleSource: SessionTitleSource = .summary,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let showsDate = titleSource != .fallback
        let showsLength = titleSource != .fallback && titleSource != .shortTest
        var parts: [String] = []
        if showsDate, let date = item.startedAt {
            parts.append(dayOrTime(date, now: now, calendar: calendar))
        }
        if showsLength, let seconds = item.durationSeconds {
            parts.append(SessionTitleResolver.durationText(seconds))
        }
        if let project = nonEmpty(item.project) {
            parts.append(project)
        } else if parts.isEmpty, let mode = nonEmpty(item.mode) {
            parts.append(mode)
        }
        return parts.joined(separator: " · ")
    }

    /// "15:00" today, "Sep 4" this year, "Sep 4, 2025" before.
    public static func dayOrTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return format(date, "HH:mm", calendar: calendar)
        }
        return dayText(date, now: now, calendar: calendar)
    }

    /// The header's date: "Today", "Yesterday", "Sep 4", or "Sep 4, 2025".
    public static func headerDay(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return dayText(date, now: now, calendar: calendar)
    }

    public static func timeText(_ date: Date, calendar: Calendar = .current) -> String {
        format(date, "HH:mm", calendar: calendar)
    }

    // MARK: - Title filtering (tier 1: in memory, no index)

    /// The query's words, lowercased, without empty pieces.
    public static func terms(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// True when every query term appears in the row's title, project,
    /// mode, speaker names, or date words ("today", "friday", "sep 4").
    /// Case- and diacritic-insensitive. An empty query matches everything.
    public static func matches(_ item: SessionRailItem, query: String, now: Date, calendar: Calendar = .current) -> Bool {
        let terms = terms(query)
        guard !terms.isEmpty else { return true }
        let haystack = searchableText(for: item, now: now, calendar: calendar)
        return terms.allSatisfy { haystack.range(of: $0, options: foldOptions) != nil }
    }

    static func searchableText(for item: SessionRailItem, now: Date, calendar: Calendar) -> String {
        var parts = [item.title]
        parts += [item.project, item.mode].compactMap { $0 }
        parts += item.speakerNames
        if let date = item.startedAt {
            if calendar.isDate(date, inSameDayAs: now) { parts.append("today") }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
                parts.append("yesterday")
            }
            parts.append(format(date, "EEEE", calendar: calendar))
            parts.append(format(date, "MMM d", calendar: calendar))
            parts.append(format(date, "MMMM d", calendar: calendar))
            parts.append(format(date, "yyyy-MM-dd", calendar: calendar))
        }
        return parts.joined(separator: " \u{1F}")
    }

    // MARK: - Content snippets (tier 2: through the vault search)

    /// The snippet label for a vault search result's path.
    public static func snippetLabel(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        if path.hasPrefix("meetings/"), !path.hasPrefix("meetings/transcripts-raw/") { return "Meeting note:" }
        if name.hasPrefix("summary") { return "Summary:" }
        if name.hasPrefix("notes") { return "Notes:" }
        if name.hasPrefix("chat") { return "Chat:" }
        return "Transcript:"
    }

    /// A snippet of `text` around the first place the first term occurs,
    /// with every term marked. Nil when the first term is not in `text`.
    public static func snippet(label: String, text original: String, query: String, context: Int = snippetContext) -> SessionSnippet? {
        let terms = terms(query)
        guard let first = terms.first else { return nil }
        let display = original.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard let anchor = display.range(of: first, options: foldOptions) else { return nil }

        var start = display.index(anchor.lowerBound, offsetBy: -context, limitedBy: display.startIndex) ?? display.startIndex
        var end = display.index(anchor.upperBound, offsetBy: context, limitedBy: display.endIndex) ?? display.endIndex
        // Cut at a word boundary when one is near.
        if start > display.startIndex, let space = display[start..<anchor.lowerBound].firstIndex(of: " ") {
            start = display.index(after: space)
        }
        if end < display.endIndex, let space = display[anchor.upperBound..<end].lastIndex(of: " ") {
            end = space
        }
        let window = String(display[start..<end])
        var runs: [SessionSnippet.Run] = []
        if start > display.startIndex { runs.append(.init(text: "…", isMatch: false)) }
        runs += markedRuns(window, terms: terms)
        if end < display.endIndex { runs.append(.init(text: "…", isMatch: false)) }
        return SessionSnippet(label: label, runs: merged(runs))
    }

    /// `text` split into runs with every occurrence of any term marked.
    public static func markedRuns(_ text: String, terms: [String]) -> [SessionSnippet.Run] {
        var ranges: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: term, options: foldOptions, range: searchStart..<text.endIndex) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var runs: [SessionSnippet.Run] = []
        var cursor = text.startIndex
        for range in ranges where range.lowerBound >= cursor {
            if cursor < range.lowerBound { runs.append(.init(text: String(text[cursor..<range.lowerBound]), isMatch: false)) }
            runs.append(.init(text: String(text[range]), isMatch: true))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { runs.append(.init(text: String(text[cursor...]), isMatch: false)) }
        return runs
    }

    /// The session a vault search result belongs to, as its canonical stamp:
    /// a file inside `…/rti/sessions/<yyyy-MM-dd HHmmss>/`, a raw meeting
    /// transcript `meetings/transcripts-raw/<yyyyMMdd-HHmmss>-…`, or a
    /// meeting note that names a session (`noteStamps`: file name → stamp).
    public static func sessionStamp(forResultPath path: String, noteStamps: [String: String]) -> String? {
        let pieces = path.split(separator: "/").map(String.init)
        if let sessions = pieces.firstIndex(of: "sessions"), sessions > 0, pieces[sessions - 1] == "rti",
           sessions + 1 < pieces.count,
           let stamp = VaultMeetingTitleMap.canonicalStamp(fromFolderName: pieces[sessions + 1]) {
            return stamp
        }
        if pieces.count >= 2, pieces[pieces.count - 2] == "transcripts-raw",
           let range = pieces[pieces.count - 1].range(of: #"^\d{8}-\d{6}"#, options: .regularExpression) {
            return String(pieces[pieces.count - 1][range])
        }
        if pieces.first == "meetings", let name = pieces.last {
            return noteStamps[name]
        }
        return nil
    }

    // MARK: - Transcript status

    /// The header's word for the transcript, from the session folder's file
    /// names: "Transcript upgraded", "Upgrade pending", "No transcript", or
    /// nil for a plain live transcript (the usual case needs no word).
    public static func transcriptStatus(fileNames: Set<String>) -> String? {
        if fileNames.contains("transcript.upgraded.md") { return "Transcript upgraded" }
        if fileNames.contains("automatic-upgrade.pending") { return "Upgrade pending" }
        if fileNames.contains("transcript.md") { return nil }
        return "No transcript"
    }

    /// The header's word for a missing summary: "Summary unavailable" when a
    /// session has a transcript but the end-of-session summary never landed.
    /// The summary call can return no text at all (a reasoning model can
    /// spend its whole token budget thinking and emit nothing), and that
    /// used to leave a silent gap. Saying it in the row makes the failure
    /// visible without opening the log.
    public static func summaryStatus(fileNames: Set<String>) -> String? {
        guard !fileNames.contains("summary.md") else { return nil }
        guard fileNames.contains("transcript.md") || fileNames.contains("transcript.upgraded.md") else { return nil }
        return "Summary unavailable"
    }

    // MARK: - Find

    /// Every range of `query` in `text`, case- and diacritic-insensitive.
    public static func findRanges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: needle, options: foldOptions, range: searchStart..<text.endIndex) {
            ranges.append(found)
            searchStart = found.upperBound
        }
        return ranges
    }

    /// "2 of 17", "No matches", or "" for an empty query.
    public static func findStatus(current: Int, total: Int, query: String) -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard total > 0 else { return "No matches" }
        return "\(min(max(current, 0), total - 1) + 1) of \(total)"
    }

    /// Markdown split into blocks at blank lines, never inside a code fence,
    /// so find can mark and scroll to the block that holds a hit.
    public static func markdownBlocks(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inFence = false
        func flush() {
            let block = current.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !block.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(block) }
            current = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }

    // MARK: - Helpers

    static let foldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func dayText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return format(date, sameYear ? "MMM d" : "MMM d, yyyy", calendar: calendar)
    }

    static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        DateFormatterCache.formatter(pattern, calendar: calendar).string(from: date)
    }

    private static func merged(_ runs: [SessionSnippet.Run]) -> [SessionSnippet.Run] {
        var out: [SessionSnippet.Run] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.isMatch == run.isMatch {
                out[out.count - 1] = .init(text: last.text + run.text, isMatch: run.isMatch)
            } else {
                out.append(run)
            }
        }
        return out
    }
}

// MARK: - Formatters

/// One `DateFormatter` per pattern, calendar, and time zone. The rail
/// formats every row on each draw, and a new formatter per call is slow.
/// Formatting with a configured formatter is thread-safe; the lock guards
/// only the dictionary.
enum DateFormatterCache {
    private static let cache = OSAllocatedUnfairLock<[String: DateFormatter]>(initialState: [:])

    static func formatter(_ pattern: String, calendar: Calendar) -> DateFormatter {
        let key = "\(pattern)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        return cache.withLock { formatters in
            if let formatter = formatters[key] { return formatter }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            formatters[key] = formatter
            return formatter
        }
    }
}

// MARK: - Keys

/// A command the Sessions window runs from the keyboard.
public enum SessionsWindowCommand: Equatable, Sendable {
    /// ⌃⌘S: show or hide the session list (the macOS sidebar key; RTI keeps
    /// ⌘\ for its global show/hide, so it is never a list toggle here).
    case toggleList
    case find, findNext, findPrevious
    /// ⌘K: the open session's actions.
    case actions
    /// ⌘J: ask about the session in RTI's chat.
    case ask
    case rename
    case copy
    case saveMarkdown
    case close
    /// ⌘1…⌘9: open that row.
    case openRow(Int)
    // Plain keys, taken only while a layer wants them.
    case escape, moveUp, moveDown, confirm, confirmAlternate
}

public enum SessionsWindowKeys {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let option = Modifiers(rawValue: 1 << 3)
    }

    /// Key codes of the plain keys (layout-independent).
    public enum KeyCode {
        public static let returnKey: UInt16 = 36
        public static let keypadEnter: UInt16 = 76
        public static let escape: UInt16 = 53
        public static let upArrow: UInt16 = 126
        public static let downArrow: UInt16 = 125
    }

    /// A key equivalent (a chord with ⌘) from `charactersIgnoringModifiers`.
    public static func command(characters: String, modifiers: Modifiers) -> SessionsWindowCommand? {
        let key = characters.lowercased()
        switch modifiers {
        case [.command, .control]:
            return key == "s" ? .toggleList : nil
        case [.command, .shift]:
            switch key {
            case "g": return .findPrevious
            case "c": return .copy
            default: return nil
            }
        case [.command]:
            switch key {
            case "f": return .find
            case "g": return .findNext
            case "k": return .actions
            case "j": return .ask
            case "e": return .rename
            case "s": return .saveMarkdown
            case "w": return .close
            default:
                if let digit = Int(key), (1...9).contains(digit) { return .openRow(digit) }
                return nil
            }
        default:
            return nil
        }
    }

    /// A plain key: esc, ↩ (⇧↩), ↑, ↓. Other modifiers pass through.
    public static func plainKey(keyCode: UInt16, modifiers: Modifiers) -> SessionsWindowCommand? {
        let others = modifiers.subtracting(.shift)
        guard others.isEmpty else { return nil }
        switch keyCode {
        case KeyCode.escape: return modifiers.isEmpty ? .escape : nil
        case KeyCode.returnKey, KeyCode.keypadEnter: return modifiers.contains(.shift) ? .confirmAlternate : .confirm
        case KeyCode.upArrow: return modifiers.isEmpty ? .moveUp : nil
        case KeyCode.downArrow: return modifiers.isEmpty ? .moveDown : nil
        default: return nil
        }
    }
}
