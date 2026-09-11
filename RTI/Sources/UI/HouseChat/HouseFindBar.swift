// Copied from quick-launch@b9ee129 Sources/Views/AIChatWindowView.swift (AIChatFindBar)
// and Sources/ViewModels/AIChatWindowModel.swift (find in chat)
import AppKit
import RTICore
import SwiftUI

// Find in Chat for the Assist thread (design-system docs/chat-surfaces.md
// section 6): a bar under the header, every hit painted in the text, the
// current one in the selection fill, `↩` and `⇧↩` to step, `esc` to close.
//
// RTI divergence: answers render through MarkdownUI (no text view to paint
// ranges into), so a hit is painted by rewriting the answer's Markdown for
// display only: `~~hit~~` for a hit and `[hit](rti-find:current)` for the
// current one, which the find theme in `RTIMarkdown` draws as the hover and
// selection fills. Code blocks and inline code are not searched.

// MARK: - State

/// Whether the find bar shows, what it looks for, and which hit is current.
/// One per overlay; the esc order and the menu reach it through `shared`.
@Observable @MainActor
final class ThreadFindState {
    static let shared = ThreadFindState()

    var isPresented = false
    var query = ""
    /// Bumped to pull focus back into the field (`⌘F` while already open).
    private(set) var focusRequest = 0
    /// The current hit, pinned to the text it was found for: a new query
    /// starts again at the first hit.
    private var cursor: (needle: String, index: Int)?

    init() {}

    /// The text as searched: white space as one space, trimmed.
    var needle: String { ThreadFindIndex.needle(query) }

    /// `⌘F`: show the bar (or focus it again) and start at the first hit.
    func open() {
        isPresented = true
        focusRequest &+= 1
    }

    /// `esc` or the close button. Returns false when the bar was not open,
    /// so an esc router can pass the key on.
    @discardableResult
    func close() -> Bool {
        guard isPresented else { return false }
        isPresented = false
        query = ""
        cursor = nil
        return true
    }

    /// The current hit's position among `count` hits.
    func currentIndex(of count: Int) -> Int? {
        guard count > 0 else { return nil }
        if let cursor, cursor.needle == needle, cursor.index < count { return cursor.index }
        return 0
    }

    /// `↩` or `⌘G`: the next hit, wrapping. `⇧↩` or `⇧⌘G`: the previous.
    func step(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        let start = currentIndex(of: count) ?? 0
        cursor = (needle, ((start + delta) % count + count) % count)
    }

    /// "3 of 17", "No matches", or nothing before anything is typed.
    func status(count: Int) -> String {
        guard !needle.isEmpty else { return "" }
        guard let index = currentIndex(of: count) else { return "No matches" }
        return "\(index + 1) of \(count)"
    }
}

// MARK: - Hits

/// One hit: a range in the text one part of one turn shows.
struct ThreadFindHit: Hashable {
    enum Part: Hashable {
        /// The question pill's words.
        case question
        /// The answer's prose, as `MarkdownFindText.text` reads it.
        case answer
    }

    let entryID: UUID
    let part: Part
    /// UTF-16 range in the part's searchable text.
    let range: NSRange
    /// Where the hit starts, as a fraction of its turn's text (0 to 1), so
    /// the thread can bring it into view without laying the text out.
    let position: Double
}

/// Every hit of the find text in the thread, in reading order.
struct ThreadFindIndex {
    let hits: [ThreadFindHit]

    /// - Parameter questionText: the words a user turn's pill shows (a
    ///   canned action shows its name, not its prompt).
    init(query: String, entries: [ChatEntry], questionText: (ChatEntry) -> String) {
        let needle = Self.needle(query)
        guard !needle.isEmpty else {
            hits = []
            return
        }
        var found: [ThreadFindHit] = []
        for entry in entries {
            if entry.role == "user" {
                let text = questionText(entry)
                found += Self.ranges(of: needle, in: text).map {
                    ThreadFindHit(entryID: entry.id, part: .question, range: $0, position: Self.fraction($0.location, of: text.utf16.count))
                }
            } else {
                let projection = MarkdownFindText(entry.text)
                found += Self.ranges(of: needle, in: projection.text).map {
                    ThreadFindHit(
                        entryID: entry.id, part: .answer, range: $0,
                        position: Self.fraction(projection.sourceOffset(ofTextOffset: $0.location), of: entry.text.utf16.count)
                    )
                }
            }
        }
        hits = found
    }

    /// The text as searched: white space as one space, trimmed.
    static func needle(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Non-overlapping ranges of `needle` in `text`, ignoring case, accents,
    /// and width.
    static func ranges(of needle: String, in text: String) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        var start = 0
        while start < ns.length {
            let found = ns.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: NSRange(location: start, length: ns.length - start)
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            out.append(found)
            start = NSMaxRange(found)
        }
        return out
    }

    private static func fraction(_ offset: Int, of length: Int) -> Double {
        length > 0 ? min(1, max(0, Double(offset) / Double(length))) : 0
    }
}

/// What the thread paints: every hit in the hover fill, the current one in
/// the selection fill ("hover is half the selection fill", applied to text).
struct ThreadFindHighlights: Equatable {
    let current: ThreadFindHit?
    private let ranges: [UUID: [ThreadFindHit.Part: [NSRange]]]

    init(hits: [ThreadFindHit], current: ThreadFindHit?) {
        self.current = current
        var ranges: [UUID: [ThreadFindHit.Part: [NSRange]]] = [:]
        for hit in hits {
            ranges[hit.entryID, default: [:]][hit.part, default: []].append(hit.range)
        }
        self.ranges = ranges
    }

    func ranges(in entryID: UUID, part: ThreadFindHit.Part) -> [NSRange] {
        ranges[entryID]?[part] ?? []
    }

    /// The current hit's range when it is in this part of this turn.
    func current(in entryID: UUID, part: ThreadFindHit.Part) -> NSRange? {
        guard let current, current.entryID == entryID, current.part == part else { return nil }
        return current.range
    }

    /// One answer's Markdown with its hits marked for the find theme, or
    /// the Markdown unchanged when it has none.
    func markedAnswer(_ markdown: String, entryID: UUID) -> String {
        let hits = ranges(in: entryID, part: .answer)
        guard !hits.isEmpty else { return markdown }
        return MarkdownFindText(markdown).marked(hits: hits, current: current(in: entryID, part: .answer))
    }

    /// A question's words with its hits painted.
    func highlightedQuestion(_ text: String, entryID: UUID) -> AttributedString {
        var attributed = AttributedString(text)
        let current = current(in: entryID, part: .question)
        for range in ranges(in: entryID, part: .question) {
            guard NSMaxRange(range) <= (text as NSString).length,
                  let span = Range(range, in: attributed) else { continue }
            attributed[span].backgroundColor = range == current ? House.ColorToken.selectionFill : House.ColorToken.hoverFill
        }
        return attributed
    }
}

// MARK: - Markdown as find reads it

/// An answer's Markdown projected to the words it shows, so find matches
/// what the reader sees ("**Friday**" is found as "Friday", a link's target
/// is never matched), with a map back to the source for painting hits.
///
/// A line-level reading of the Markdown RTI's answers use: fenced code and
/// inline code are left out, block markers (quotes, headings, list bullets,
/// task boxes, table rules) are dropped, emphasis and strike delimiters are
/// dropped, and a link keeps its text only.
struct MarkdownFindText {
    /// The words, as find searches them.
    let text: String
    private let source: [UInt16]
    /// For each UTF-16 unit of `text`, its offset in the source.
    private let map: [Int]
    /// Source offsets left out of `marked`: link syntax and `~~` runs, which
    /// the find theme would otherwise paint as hits.
    private let dropped: Set<Int>

    static let currentLinkTarget = "rti-find:current"

    init(_ markdown: String) {
        let src = Array(markdown.utf16)
        var out: [UInt16] = []
        var map: [Int] = []
        var dropped = Set<Int>()
        var fence: (char: UInt16, length: Int)?

        func emit(_ index: Int) {
            out.append(src[index])
            map.append(index)
        }

        var lineStart = 0
        while lineStart <= src.count {
            var lineEnd = lineStart
            while lineEnd < src.count, src[lineEnd] != Unit.newline { lineEnd += 1 }
            defer {
                if lineEnd < src.count, let last = out.last, last != Unit.newline {
                    out.append(Unit.newline)
                    map.append(lineEnd)
                }
                lineStart = lineEnd + 1
            }

            var p = lineStart
            while p < lineEnd, src[p] == Unit.space || src[p] == Unit.tab { p += 1 }
            let run = Self.runLength(src, from: p, end: lineEnd)
            if let open = fence {
                if p < lineEnd, src[p] == open.char, run >= open.length { fence = nil }
                continue
            }
            if p < lineEnd, src[p] == Unit.backtick || src[p] == Unit.tilde, run >= 3 {
                fence = (src[p], run)
                continue
            }
            if Self.isRuleLine(src, from: p, end: lineEnd) { continue }

            p = Self.skipBlockMarkers(src, from: p, end: lineEnd)
            Self.scanInline(src, from: p, end: lineEnd, emit: emit, drop: { dropped.insert($0) })
        }

        self.text = String(decoding: out, as: UTF16.self)
        self.source = src
        self.map = map
        self.dropped = dropped
    }

    /// The source offset of a `text` offset (the source's end past the last).
    func sourceOffset(ofTextOffset offset: Int) -> Int {
        guard !map.isEmpty else { return 0 }
        return offset < map.count ? map[offset] : (map.last ?? 0) + 1
    }

    /// The source with each hit wrapped for the find theme: `~~hit~~`, and
    /// `[hit](rti-find:current)` for the current one. A hit that crosses
    /// Markdown syntax is marked in pieces, one per unbroken run of words.
    func marked(hits: [NSRange], current: NSRange?) -> String {
        var opens: [Int: [UInt16]] = [:]
        var closes: [Int: [UInt16]] = [:]
        let hoverOpen = Array("~~".utf16)
        let currentOpen = Array("[".utf16)
        let currentClose = Array("](\(Self.currentLinkTarget))".utf16)

        for hit in hits {
            let isCurrent = hit == current
            for run in runs(of: hit) {
                opens[run.lowerBound, default: []] += isCurrent ? currentOpen : hoverOpen
                closes[run.upperBound, default: []] += isCurrent ? currentClose : hoverOpen
            }
        }

        var out: [UInt16] = []
        out.reserveCapacity(source.count + hits.count * 8)
        for index in 0...source.count {
            if let close = closes[index] { out += close }
            if let open = opens[index] { out += open }
            if index < source.count, !dropped.contains(index) { out.append(source[index]) }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// The source ranges a hit covers: consecutive source offsets, never
    /// across a line, trimmed of white space at both ends.
    private func runs(of hit: NSRange) -> [Range<Int>] {
        let lower = max(0, hit.location)
        let upper = min(map.count, NSMaxRange(hit))
        guard lower < upper else { return [] }
        var runs: [Range<Int>] = []
        var start: Int?
        var last = -1
        func close() {
            guard let begin = start else { return }
            var a = begin
            var b = last + 1
            while a < b, Self.isSpace(source[a]) { a += 1 }
            while b > a, Self.isSpace(source[b - 1]) { b -= 1 }
            if a < b { runs.append(a..<b) }
            start = nil
        }
        for i in lower..<upper {
            let offset = map[i]
            if offset >= source.count || source[offset] == Unit.newline {
                close()
                continue
            }
            if start != nil, offset != last + 1 { close() }
            if start == nil { start = offset }
            last = offset
        }
        close()
        return runs
    }

    // MARK: Block level

    private static func runLength(_ src: [UInt16], from p: Int, end: Int) -> Int {
        guard p < end else { return 0 }
        var q = p
        while q < end, src[q] == src[p] { q += 1 }
        return q - p
    }

    /// A thematic break (`---`, `***`) or a table's rule row (`|---|:--|`).
    private static func isRuleLine(_ src: [UInt16], from p: Int, end: Int) -> Bool {
        guard p < end else { return false }
        var dashes = 0
        var stars = 0
        var unders = 0
        for i in p..<end {
            switch src[i] {
            case Unit.dash: dashes += 1
            case Unit.star: stars += 1
            case Unit.underscore: unders += 1
            case Unit.pipe, Unit.colon, Unit.space, Unit.tab: continue
            default: return false
            }
        }
        return dashes >= 3 || stars >= 3 || unders >= 3
    }

    /// Past quote markers, a heading's hashes, a list bullet or number, and
    /// a task box.
    private static func skipBlockMarkers(_ src: [UInt16], from start: Int, end: Int) -> Int {
        var p = start
        func skipSpaces() { while p < end, src[p] == Unit.space || src[p] == Unit.tab { p += 1 } }
        while p < end, src[p] == Unit.greater {
            p += 1
            skipSpaces()
        }
        let hashes = runLength(src, from: p, end: end)
        if p < end, src[p] == Unit.hash, hashes <= 6, p + hashes < end, src[p + hashes] == Unit.space {
            p += hashes
            skipSpaces()
            return p
        }
        if p + 1 < end, src[p] == Unit.dash || src[p] == Unit.star || src[p] == Unit.plus, src[p + 1] == Unit.space {
            p += 1
            skipSpaces()
        } else {
            var q = p
            while q < end, isDigit(src[q]) { q += 1 }
            if q > p, q + 1 < end, src[q] == Unit.dot || src[q] == Unit.closeParen, src[q + 1] == Unit.space {
                p = q + 1
                skipSpaces()
            }
        }
        if p + 3 < end, src[p] == Unit.openBracket, src[p + 2] == Unit.closeBracket, src[p + 3] == Unit.space,
           src[p + 1] == Unit.space || src[p + 1] == Unit.lowerX || src[p + 1] == Unit.upperX {
            p += 4
        }
        return p
    }

    // MARK: Inline level

    private static func scanInline(
        _ src: [UInt16], from start: Int, end: Int,
        emit: (Int) -> Void, drop: (Int) -> Void
    ) {
        var i = start
        // A link's `](target)` to drop when the scan reaches its `]`.
        var linkCloses: [Int: Int] = [:]
        while i < end {
            let c = src[i]
            if let parenEnd = linkCloses[i] {
                for k in i...parenEnd { drop(k) }
                i = parenEnd + 1
                continue
            }
            switch c {
            case Unit.backslash where i + 1 < end && isASCIIPunctuation(src[i + 1]):
                drop(i)
                emit(i + 1)
                i += 2
            case Unit.backtick:
                let n = runLength(src, from: i, end: end)
                if let closing = closingBackticks(src, from: i + n, end: end, length: n) {
                    // Inline code is not searched; it stays in the output.
                    i = closing + n
                } else {
                    for k in i..<(i + n) { emit(k) }
                    i += n
                }
            case Unit.bang where i + 1 < end && src[i + 1] == Unit.openBracket:
                if let close = linkClose(src, openAt: i + 1, end: end) {
                    drop(i)
                    drop(i + 1)
                    linkCloses[close.bracket] = close.paren
                    i += 2
                } else {
                    emit(i)
                    i += 1
                }
            case Unit.openBracket:
                if let close = linkClose(src, openAt: i, end: end) {
                    drop(i)
                    linkCloses[close.bracket] = close.paren
                } else {
                    emit(i)
                }
                i += 1
            case Unit.star, Unit.underscore, Unit.tilde:
                let n = runLength(src, from: i, end: end)
                let before: UInt16? = i > start ? src[i - 1] : nil
                let after: UInt16? = i + n < end ? src[i + n] : nil
                let leftFlanking = after.map { !isSpace($0) } ?? false
                let rightFlanking = before.map { !isSpace($0) } ?? false
                let intraword = before.map(isAlphanumeric) == true && after.map(isAlphanumeric) == true
                let isDelimiter = (leftFlanking || rightFlanking) && !(c == Unit.underscore && intraword)
                if isDelimiter {
                    // Real strikethrough would read as a hit under the find
                    // theme, so `~~` runs leave the marked output too.
                    if c == Unit.tilde, n == 2 { drop(i); drop(i + 1) }
                } else {
                    for k in i..<(i + n) { emit(k) }
                }
                i += n
            default:
                emit(i)
                i += 1
            }
        }
    }

    /// For a `[` that opens a link `[text](target)` on this line: the
    /// offsets of its `]` and of the `)` that ends the target.
    private static func linkClose(_ src: [UInt16], openAt open: Int, end: Int) -> (bracket: Int, paren: Int)? {
        var depth = 0
        var i = open
        while i < end {
            switch src[i] {
            case Unit.openBracket: depth += 1
            case Unit.closeBracket:
                depth -= 1
                if depth == 0 {
                    guard i + 1 < end, src[i + 1] == Unit.openParen else { return nil }
                    var parens = 0
                    var j = i + 1
                    while j < end {
                        if src[j] == Unit.openParen { parens += 1 }
                        if src[j] == Unit.closeParen {
                            parens -= 1
                            if parens == 0 { return (i, j) }
                        }
                        j += 1
                    }
                    return nil
                }
            default: break
            }
            i += 1
        }
        return nil
    }

    private static func closingBackticks(_ src: [UInt16], from start: Int, end: Int, length: Int) -> Int? {
        var i = start
        while i < end {
            if src[i] == Unit.backtick {
                let n = runLength(src, from: i, end: end)
                if n == length { return i }
                i += n
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == Unit.space || c == Unit.tab || c == Unit.newline }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isAlphanumeric(_ c: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }
    private static func isASCIIPunctuation(_ c: UInt16) -> Bool {
        (33...47).contains(c) || (58...64).contains(c) || (91...96).contains(c) || (123...126).contains(c)
    }

    /// The UTF-16 units the reading needs.
    private enum Unit {
        static let newline: UInt16 = 10
        static let tab: UInt16 = 9
        static let space: UInt16 = 32
        static let bang: UInt16 = 33
        static let hash: UInt16 = 35
        static let openParen: UInt16 = 40
        static let closeParen: UInt16 = 41
        static let star: UInt16 = 42
        static let plus: UInt16 = 43
        static let dash: UInt16 = 45
        static let dot: UInt16 = 46
        static let colon: UInt16 = 58
        static let greater: UInt16 = 62
        static let upperX: UInt16 = 88
        static let openBracket: UInt16 = 91
        static let backslash: UInt16 = 92
        static let closeBracket: UInt16 = 93
        static let underscore: UInt16 = 95
        static let backtick: UInt16 = 96
        static let lowerX: UInt16 = 120
        static let pipe: UInt16 = 124
        static let tilde: UInt16 = 126
    }
}

// MARK: - The bar

/// `⌘F`: a search field over the thread. `↩` (or `⌘G`) the next hit, `⇧↩`
/// (or `⇧⌘G`) the previous, across turns; `esc` closes. The count is hits
/// ("3 of 17"), each painted in the text.
struct HouseFindBar: View {
    @Bindable var find: ThreadFindState
    /// "3 of 17", "No matches", or empty.
    let status: String
    let onNext: () -> Void
    let onPrevious: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $find.query, prompt: Text("")) {
                Text("Find in chat")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(House.TypeToken.bodySmall)
            .foregroundStyle(House.ColorToken.textPrimary)
            .overlay(alignment: .leading) {
                if find.query.isEmpty {
                    Text("Find in chat")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($focused)
            .onSubmit {
                if NSEvent.modifierFlags.contains(.shift) { onPrevious() } else { onNext() }
            }
            .onExitCommand { find.close() }
            Text(status)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(status)
            Button(action: onNext) {
                KeyHint(label: "Next", keys: ["↩"]).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Next match (↩ or ⌘G)")
            Button(action: onPrevious) {
                KeyHint(label: "Previous", keys: ["⇧", "↩"]).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Previous match (⇧↩ or ⇧⌘G)")
            QuickAIGlyphButton(
                symbol: "xmark",
                font: HouseChatType.glyphSmall,
                color: House.ColorToken.textSecondary,
                label: "Close find",
                help: "Close find (esc)"
            ) {
                find.close()
            }
        }
        .padding(.horizontal, House.Spacing.md)
        .frame(height: House.Control.pill)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .padding(.horizontal, House.Spacing.lg)
        .padding(.bottom, House.Spacing.xs)
        .task(id: find.focusRequest) { focused = true }
        .onChange(of: status) { _, status in
            guard !status.isEmpty else { return }
            QuickAIAnnouncement.post(status, priority: .medium)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in chat")
    }
}
