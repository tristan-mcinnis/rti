import Foundation

public enum LiveTranscriptPresentation {
    public struct Row: Identifiable, Equatable {
        public let id: UUID
        public let speakerId: String
        public let speakerLabel: String
        public let startMs: Int
        /// Canonical display continuation, including a peer-corrected fragment.
        public let streamID: UUID?
        public var original: String
        public var translation: String
        public var translationLanguage: String?

        public var isNote: Bool { speakerId == "note" }
        /// The mic leg's main voice: the person running RTI.
        public var isSelf: Bool { speakerId == "self" }
        public var hasOriginal: Bool { !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        public var hasTranslation: Bool { !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Interim (not yet final) text from one speaker.
    public struct InterimSegment: Equatable {
        public let speakerId: String
        public let text: String
        public let textOrigin: LiveEntry.TextOrigin
        public let startMs: Int?
        public let translationStatus: String
        public let language: String?
        public let streamID: UUID?
        public let tokens: [LiveEntry.TimedToken]

        public init(
            speakerId: String,
            text: String,
            textOrigin: LiveEntry.TextOrigin = .standalone,
            startMs: Int? = nil,
            translationStatus: String = "none",
            language: String? = nil,
            streamID: UUID? = nil,
            tokens: [LiveEntry.TimedToken] = []
        ) {
            self.speakerId = speakerId
            self.text = text
            self.textOrigin = textOrigin
            self.startMs = startMs
            self.translationStatus = translationStatus
            self.language = language
            self.streamID = streamID
            self.tokens = tokens
        }
    }

    /// The label a live speaker id reads as, derived from the id alone so it
    /// never changes while the meeting runs: `self` is "You", the system
    /// leg's voices are "Speaker N", extra voices on the mic are "Room
    /// speaker N". A name the user gave (`names`, keyed by raw id) wins.
    ///
    /// Numbering by first appearance (the old rule) let labels swap when the
    /// cross-channel echo pass later dropped an early entry, and made the mic
    /// wearer "Speaker 2" whenever someone else spoke first.
    public static func label(for speakerId: String, names: [String: String] = [:]) -> String {
        if speakerId == "note" { return "Note" }
        if let name = names[speakerId]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if speakerId == "self" { return "You" }
        if let n = numericSuffix(of: speakerId, afterPrefix: "remote_") { return "Speaker \(n)" }
        if let n = numericSuffix(of: speakerId, afterPrefix: "them_") { return "Speaker \(n)" }
        if let n = numericSuffix(of: speakerId, afterPrefix: "room_") { return "Room speaker \(n)" }
        return speakerId
    }

    /// Invitees of the confirmed calendar meeting offered as names for a live
    /// speaker: the user themself left out, each name once, and a name already
    /// given to a different speaker left out so one person is never two voices.
    public static func nameChoices(
        attendees: [CalendarMeeting.Attendee],
        names: [String: String],
        for speakerId: String
    ) -> [String] {
        let takenElsewhere = Set(names
            .filter { $0.key != speakerId }
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var seen: Set<String> = []
        return attendees.compactMap { attendee in
            let name = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !attendee.isCurrentUser, !name.isEmpty,
                  !takenElsewhere.contains(key), seen.insert(key).inserted else { return nil }
            return name
        }
    }

    public static func rows(
        from entries: [LiveEntry],
        showTranslations: Bool,
        names: [String: String] = [:]
    ) -> [Row] {
        var result: [Row] = []

        for entry in entries {
            let isTranslation = entry.translationStatus == "translation"
            let canMerge = !entry.speakerId.isEmpty
                && entry.speakerId != "note"
                && result.last?.speakerId == entry.speakerId
                && result.last?.streamID == entry.displayStreamID

            if canMerge, let lastIndex = result.indices.last {
                if isTranslation {
                    append(entry.text, origin: entry.textOrigin, to: &result[lastIndex].translation)
                    result[lastIndex].translationLanguage = entry.language ?? result[lastIndex].translationLanguage
                } else {
                    append(entry.text, origin: entry.textOrigin, to: &result[lastIndex].original)
                }
            } else {
                result.append(Row(
                    id: entry.id,
                    speakerId: entry.speakerId,
                    speakerLabel: label(for: entry.speakerId, names: names),
                    startMs: entry.startMs,
                    streamID: entry.displayStreamID,
                    original: isTranslation ? "" : entry.text,
                    translation: isTranslation ? entry.text : "",
                    translationLanguage: isTranslation ? entry.language : nil
                ))
            }
        }

        return result.filter { row in
            row.hasOriginal || (showTranslations && row.hasTranslation)
        }
    }

    public static func copyText(rows: [Row], showTranslations: Bool) -> String {
        rows.map { copyText(row: $0, showTranslations: showTranslations) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public static func copyText(row: Row, showTranslations: Bool) -> String {
        let original = row.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = row.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !original.isEmpty {
            parts.append("[\(formatOffset(row.startMs))] \(row.speakerLabel): \(original)")
        }
        if showTranslations, !translation.isEmpty {
            let label = row.translationLanguage.map { "Translation \($0.uppercased())" } ?? "Translation"
            parts.append("[\(formatOffset(row.startMs))] \(label): \(translation)")
        }
        return parts.joined(separator: "\n")
    }

    /// Split the pipeline's interim line (`"remote_1: text  self: text"`,
    /// one part per leg and speaker) into speaker-attributed segments, so the
    /// view can show interim words in the run they belong to instead of as an
    /// unattributed line. Ordinary colons in speech are kept; text before any
    /// speaker id is attributed to an empty id.
    public static func interimSegments(_ raw: String) -> [InterimSegment] {
        let range = NSRange(raw.startIndex..., in: raw)
        let markers = interimMarker.matches(in: raw, range: range)
        var segments: [InterimSegment] = []
        func add(_ speakerId: String, _ text: Substring) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let last = segments.last, last.speakerId == speakerId {
                segments[segments.count - 1] = InterimSegment(speakerId: speakerId, text: last.text + " " + trimmed)
            } else {
                segments.append(InterimSegment(speakerId: speakerId, text: trimmed))
            }
        }
        var cursor = raw.startIndex
        var currentSpeaker = ""
        for marker in markers {
            guard let whole = Range(marker.range, in: raw),
                  let id = Range(marker.range(at: 1), in: raw) else { continue }
            add(currentSpeaker, raw[cursor..<whole.lowerBound])
            currentSpeaker = String(raw[id])
            cursor = whole.upperBound
        }
        add(currentSpeaker, raw[cursor...])
        return segments
    }

    /// Split one speaker's run into reading paragraphs. A paragraph closes at
    /// the first sentence end once it holds `softLimit` characters, or at the
    /// first space past `hardLimit` when the speech has no punctuation. The
    /// last element is the open paragraph, empty when the text ends on a
    /// closed one, so words still to come start a new paragraph there.
    ///
    /// Each break depends only on the text before it, so appending words never
    /// moves an earlier break: settled paragraphs keep their layout while the
    /// open one grows. That keeps a long monologue readable, and it keeps an
    /// interim frame from re-laying out the whole run.
    public static func paragraphs(_ text: String, softLimit: Int = 450, hardLimit: Int = 1_200) -> [String] {
        let chars = Array(text)
        return paragraphRanges(chars, softLimit: softLimit, hardLimit: hardLimit).map { String(chars[$0]) }
    }

    /// Shared by the plain compatibility view and the styled live projection.
    /// The final empty range keeps the existing open-paragraph contract.
    private static func paragraphRanges(_ chars: [Character], softLimit: Int = 450, hardLimit: Int = 1_200) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        var index = 0
        func trimmed(_ range: Range<Int>) -> Range<Int> {
            var lower = range.lowerBound
            var upper = range.upperBound
            while lower < upper, chars[lower].isWhitespace { lower += 1 }
            while upper > lower, chars[upper - 1].isWhitespace { upper -= 1 }
            return lower..<upper
        }
        func close(at end: Int) {
            let range = trimmed(start..<end)
            if !range.isEmpty { result.append(range) }
            start = end
            while start < chars.count, chars[start].isWhitespace { start += 1 }
        }
        while index < chars.count {
            let length = index - start + 1
            let character = chars[index]
            if length >= softLimit, sentenceEnds.contains(character),
               index + 1 == chars.count || chars[index + 1].isWhitespace || closesWithoutSpace.contains(character) {
                close(at: index + 1)
                index = start
            } else if length >= hardLimit, character.isWhitespace {
                close(at: index + 1)
                index = start
            } else {
                index += 1
            }
        }
        result.append(trimmed(start..<chars.count))
        return result
    }

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "。", "？", "！"]
    /// CJK sentence marks are not followed by a space.
    private static let closesWithoutSpace: Set<Character> = ["。", "？", "！"]

    /// A raw speaker id followed by ": ", at the start or after the two-space
    /// separator the aggregator puts between parts.
    private static let interimMarker = try! NSRegularExpression(
        pattern: #"(?:^|(?<=  ))(self|(?:room|remote|them)_[0-9]+): "#
    )

    private static func numericSuffix(of key: String, afterPrefix prefix: String) -> Int? {
        guard key.hasPrefix(prefix) else { return nil }
        return Int(key.dropFirst(prefix.count))
    }

    private static func append(_ text: String, origin: LiveEntry.TextOrigin, to target: inout String) {
        switch origin {
        case .providerTokens, .providerCorrection:
            target += text
            return
        case .standalone:
            break
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        target += (target.isEmpty ? "" : " ") + trimmed
    }

    private static func formatOffset(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension LiveTranscriptPresentation {
    /// Identity follows a timed speaker run, never its pending/final state.
    /// A provider changing the run's speaker or start time is a distinct edit.
    public struct RunID: Hashable, Sendable {
        public let streamID: UUID?
        public let speakerId: String
        public let startMs: Int
        fileprivate let fallbackID: UUID?
        fileprivate let untimedOrdinal: Int?
        fileprivate let translated: Bool
    }

    public struct Span: Equatable, Sendable {
        public fileprivate(set) var text: String
        public let isFinal: Bool

        public init(text: String, isFinal: Bool) {
            self.text = text
            self.isFinal = isFinal
        }
    }

    public struct Paragraph: Identifiable, Equatable, Sendable {
        public let id: Int
        public let spans: [Span]
        public var text: String { spans.map(\.text).joined() }
    }

    /// A cached prefix and a small replacement tail, without concatenating or
    /// comparing the historical array on each provisional update.
    public struct SliceCollection<Element>: RandomAccessCollection {
        public typealias Index = Int
        private let prefix: ArraySlice<Element>
        private let tail: [Element]
        private let replacements: [Int: Element]
        private let insertions: [(position: Int, value: Element)]

        public init() {
            prefix = []
            tail = []
            replacements = [:]
            insertions = []
        }

        fileprivate init(prefix: ArraySlice<Element>, tail: [Element]) {
            self.prefix = prefix
            self.tail = tail
            replacements = [:]
            insertions = []
        }

        fileprivate init(base: [Element], replacements: [Int: Element], insertions: [(at: Int, value: Element)]) {
            prefix = base[...]
            tail = []
            self.replacements = replacements
            self.insertions = insertions.enumerated().map { ($0.element.at + $0.offset, $0.element.value) }
        }

        public var startIndex: Int { 0 }
        public var endIndex: Int { prefix.count + tail.count + insertions.count }
        public func index(after i: Int) -> Int { i + 1 }
        public func index(before i: Int) -> Int { i - 1 }
        public func index(_ i: Int, offsetBy distance: Int) -> Int { i + distance }
        public func distance(from start: Int, to end: Int) -> Int { end - start }
        public subscript(position: Int) -> Element {
            var low = 0
            var high = insertions.count
            while low < high {
                let middle = (low + high) / 2
                if insertions[middle].position < position { low = middle + 1 } else { high = middle }
            }
            if low < insertions.count, insertions[low].position == position { return insertions[low].value }
            let basePosition = position - low
            if let replacement = replacements[basePosition] { return replacement }
            return basePosition < prefix.count ? prefix[prefix.startIndex + basePosition] : tail[basePosition - prefix.count]
        }
    }

    public typealias Paragraphs = SliceCollection<Paragraph>
    public typealias LiveRows = SliceCollection<LiveRow>

    public struct LiveRow: Identifiable, Equatable, Sendable {
        public let id: RunID
        public let revision: UInt64
        public let speakerId: String
        public let speakerLabel: String
        public let startMs: Int?
        /// The last timed word's end, when the provider gave one.
        public let endMs: Int?
        public let streamID: UUID?
        public let paragraphs: Paragraphs
        public let translation: String
        public let translationLanguage: String?
        public let hasPending: Bool

        public var isNote: Bool { speakerId == "note" }
        public var isSelf: Bool { speakerId == "self" }
        /// For explicit copy/proof work. Rendering uses the cached paragraphs.
        public var visibleText: String { paragraphs.map(\.text).joined(separator: "\n\n") }

        public static func == (lhs: LiveRow, rhs: LiveRow) -> Bool {
            lhs.id == rhs.id && lhs.revision == rhs.revision
        }
    }

    /// Plain utterances are shared by live presentation and prompt formatting.
    /// They contain no paragraph layout or provisional text.
    public struct Utterance {
        public let speakerId: String
        public var text: String
        public let startMs: Int
        public let translationStatus: String
    }

    public static func utterances(from entries: [LiveEntry]) -> [Utterance] {
        var grouping = UtteranceGrouping()
        var result: [Utterance] = []
        for fragment in entries.flatMap({ LiveFragment.pieces($0) }).sorted(by: { ordered($0, before: $1) }) {
            let assignment = grouping.place(fragment)
            if assignment.isNew {
                result.append(Utterance(speakerId: fragment.id.speakerId, text: fragment.text,
                                        startMs: fragment.id.startMs, translationStatus: fragment.translationStatus))
            } else {
                append(fragment.text, origin: fragment.origin, to: &result[assignment.index].text)
            }
        }
        return result.enumerated().sorted {
            $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs
        }.map(\.element)
    }

    /// Assemble each source's utterances before ordering the two legs. Only a
    /// real speaker/stream change or at least one second of measured silence
    /// closes an utterance. Finality and provider packets do not close it.
    /// Interim updates replace only affected rows over the cached collection.
    public struct Projection {
        private var sources: [UUID: LiveEntry] = [:]
        private var grouping = UtteranceGrouping()
        private var builders: [LiveBuilder] = []
        private var translationGroups: [Int: [Int]] = [:]
        private var attachedTranslations: Set<Int> = []
        private var cachedRows: [LiveRow] = []
        private var rowByGroup: [Int: Int] = [:]
        private var names: [String: String] = [:]
        private var showTranslations = false
        private var revision: UInt64 = 0

        public init() {}
        public mutating func reset() { self = Projection() }
        public var committedRows: LiveRows { LiveRows(prefix: cachedRows[...], tail: []) }

        public mutating func updateFinals(
            _ entries: [LiveEntry],
            names: [String: String] = [:],
            showTranslations: Bool = false
        ) {
            var additions: [LiveEntry] = []
            var matched = 0
            var extendsCache = true
            for entry in entries {
                if let previous = sources[entry.id] {
                    matched += 1
                    if !samePresentationEntry(previous, entry) { extendsCache = false }
                } else {
                    additions.append(entry)
                }
            }
            extendsCache = extendsCache && matched == sources.count
            if additions.contains(where: { entry in
                let start = entry.tokens.map(\.startMs).min() ?? entry.startMs
                return entry.translationStatus != "translation"
                    && (grouping.hasLaterOriginal(in: entry.displayStreamID, than: start)
                        || grouping.hasTranslation(in: entry.displayStreamID, atOrAfter: start))
            }) { extendsCache = false }
            let settingsChanged = self.names != names || self.showTranslations != showTranslations
            if extendsCache, additions.isEmpty, !settingsChanged { return }
            revision &+= 1
            self.names = names
            self.showTranslations = showTranslations
            if !extendsCache {
                sources = [:]
                grouping = UtteranceGrouping()
                builders = []
                translationGroups = [:]
                attachedTranslations = []
                additions = entries
            }
            var changed: Set<Int> = []
            for entry in additions { sources[entry.id] = entry }
            for fragment in additions.flatMap({ LiveFragment.pieces($0) }).sorted(by: { ordered($0, before: $1) }) {
                let assignment = grouping.place(fragment)
                if assignment.isNew {
                    builders.append(LiveBuilder(fragment))
                    if let companion = assignment.companion {
                        translationGroups[companion, default: []].append(assignment.index)
                        attachedTranslations.insert(assignment.index)
                    }
                } else {
                    builders[assignment.index].append(fragment)
                }
                changed.insert(assignment.index)
                if let companion = assignment.companion { changed.insert(companion) }
            }
            for index in changed { builders[index].body.freeze() }
            let previousRows = cachedRows
            let previousIndices = rowByGroup
            cachedRows = []
            rowByGroup = [:]
            let visible = builders.indices.filter {
                !attachedTranslations.contains($0) && builders[$0].isVisible(showTranslations: showTranslations)
            }.sorted { ordered(builders[$0].id, before: builders[$1].id) }
            for index in visible {
                rowByGroup[index] = cachedRows.count
                if extendsCache, !settingsChanged, !changed.contains(index), let prior = previousIndices[index] {
                    cachedRows.append(previousRows[prior])
                } else {
                    cachedRows.append(displayRow(builders[index], group: index))
                }
            }
        }

        private func samePresentationEntry(_ lhs: LiveEntry, _ rhs: LiveEntry) -> Bool {
            lhs.id == rhs.id && lhs.speakerId == rhs.speakerId && lhs.startMs == rhs.startMs
                && lhs.streamID == rhs.streamID && lhs.textOrigin == rhs.textOrigin
                && lhs.text == rhs.text && lhs.translationStatus == rhs.translationStatus
                && lhs.language == rhs.language && lhs.sourceLanguage == rhs.sourceLanguage && lhs.tokens == rhs.tokens
        }

        public mutating func updateInterims(_ segments: [InterimSegment]) -> LiveRows {
            revision &+= 1
            let pending = segments.enumerated()
                .filter { $0.element.translationStatus != "translation" }
                .flatMap { LiveFragment.pieces($0.element, ordinal: $0.offset) }
                .sorted { ordered($0, before: $1) }
            guard !pending.isEmpty else { return committedRows }
            var liveGrouping = grouping
            var live: [Int: LiveBuilder] = [:]
            for fragment in pending {
                let assignment = liveGrouping.place(fragment)
                if var builder = live[assignment.index] {
                    builder.append(fragment)
                    live[assignment.index] = builder
                } else if assignment.index < builders.count {
                    var builder = builders[assignment.index]
                    builder.append(fragment)
                    live[assignment.index] = builder
                } else {
                    live[assignment.index] = LiveBuilder(fragment)
                }
            }
            var replacements: [Int: LiveRow] = [:]
            var insertions: [(at: Int, value: LiveRow)] = []
            for (group, builder) in live.sorted(by: { ordered($0.value.id, before: $1.value.id) }) {
                guard builder.isVisible(showTranslations: showTranslations) else { continue }
                let row = displayRow(builder, group: group)
                if let index = rowByGroup[group] {
                    replacements[index] = row
                } else {
                    var low = 0
                    var high = cachedRows.count
                    while low < high {
                        let middle = (low + high) / 2
                        if ordered(cachedRows[middle].id, before: row.id) { low = middle + 1 } else { high = middle }
                    }
                    insertions.append((low, row))
                }
            }
            return LiveRows(base: cachedRows, replacements: replacements, insertions: insertions)
        }

        private func displayRow(_ source: LiveBuilder, group: Int) -> LiveRow {
            var builder = source
            if showTranslations {
                for translated in translationGroups[group] ?? [] {
                    if builder.translation.isEmpty {
                        builder.translation = builders[translated].translation
                    } else {
                        builder.translation += builders[translated].translation
                    }
                    builder.translationLanguage = builders[translated].translationLanguage ?? builder.translationLanguage
                }
            }
            return builder.row(names: names, revision: revision, showTranslations: showTranslations)
        }
    }

    public static func copyText(rows: LiveRows) -> String {
        rows.map { row in
            let stamp = formatOffset(row.startMs ?? 0)
            var parts: [String] = []
            let original = row.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !original.isEmpty {
                parts.append("[\(stamp)] \(row.speakerLabel): \(original)")
            }
            let translation = row.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !translation.isEmpty {
                let label = row.translationLanguage.map { "Translation \($0.uppercased())" } ?? "Translation"
                parts.append("[\(stamp)] \(label): \(translation)")
            }
            return parts.joined(separator: "\n")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private struct LiveFragment {
        let id: RunID
        let text: String
        let origin: LiveEntry.TextOrigin
        let isFinal: Bool
        let isTranslation: Bool
        let language: String?
        let translationStatus: String
        let endMs: Int?

        static func pieces(_ entry: LiveEntry) -> [LiveFragment] {
            guard entry.textOrigin == .providerTokens, !entry.tokens.isEmpty else { return [LiveFragment(entry)] }
            return entry.tokens.map { LiveFragment(entry, token: $0) }
        }

        static func pieces(_ segment: InterimSegment, ordinal: Int) -> [LiveFragment] {
            guard segment.textOrigin == .providerTokens, !segment.tokens.isEmpty else { return [LiveFragment(segment, ordinal: ordinal)] }
            return segment.tokens.map { LiveFragment(segment, ordinal: ordinal, token: $0) }
        }

        init(_ entry: LiveEntry, token: LiveEntry.TimedToken? = nil) {
            id = RunID(streamID: entry.displayStreamID, speakerId: entry.speakerId, startMs: token?.startMs ?? entry.startMs,
                       fallbackID: entry.speakerId == "note" || entry.textOrigin == .standalone ? entry.id : nil,
                       untimedOrdinal: nil, translated: entry.translationStatus == "translation")
            text = token?.text ?? entry.text
            origin = entry.textOrigin
            isFinal = true
            isTranslation = entry.translationStatus == "translation"
            language = entry.language
            translationStatus = entry.translationStatus
            endMs = token.flatMap { $0.endMs > 0 && $0.endMs >= $0.startMs ? $0.endMs : nil }
        }

        init(_ segment: InterimSegment, ordinal: Int, token: LiveEntry.TimedToken? = nil) {
            let startMs = token?.startMs ?? segment.startMs
            id = RunID(streamID: segment.streamID, speakerId: segment.speakerId, startMs: startMs ?? Int.max,
                       fallbackID: nil, untimedOrdinal: startMs == nil ? ordinal : nil, translated: segment.translationStatus == "translation")
            text = token?.text ?? segment.text
            origin = segment.textOrigin
            isFinal = false
            isTranslation = segment.translationStatus == "translation"
            language = segment.language
            translationStatus = segment.translationStatus
            endMs = token.flatMap { $0.endMs > 0 && $0.endMs >= $0.startMs ? $0.endMs : nil }
        }
    }

    private static func ordered(_ lhs: LiveFragment, before rhs: LiveFragment) -> Bool {
        ordered(lhs.id, before: rhs.id)
    }

    private static func ordered(_ lhs: RunID, before rhs: RunID) -> Bool {
        if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
        if lhs.streamID != rhs.streamID {
            return (lhs.streamID?.uuidString ?? "") < (rhs.streamID?.uuidString ?? "")
        }
        if lhs.speakerId != rhs.speakerId { return lhs.speakerId < rhs.speakerId }
        if lhs.translated != rhs.translated { return !lhs.translated }
        return (lhs.untimedOrdinal ?? 0) < (rhs.untimedOrdinal ?? 0)
    }

    /// Original and translated tokens use separate lanes so a translation
    /// packet cannot split a spoken word. Both share this exact pause rule.
    private struct UtteranceGrouping {
        struct Lane: Hashable {
            let stream: UUID?
            let translated: Bool
        }
        struct Speaker: Hashable {
            let stream: UUID?
            let speakerId: String
        }
        struct Boundary {
            let index: Int
            let speakerId: String
            let endMs: Int?
            let startMs: Int
            let companion: Int?
        }
        struct Assignment {
            let index: Int
            let isNew: Bool
            let companion: Int?
        }
        struct Original {
            let index: Int
            let startMs: Int
        }
        var count = 0
        var last: [Lane: Boundary] = [:]
        var originals: [Speaker: [Original]] = [:]
        var latestTranslationStart: [UUID?: Int] = [:]

        func hasLaterOriginal(in stream: UUID?, than startMs: Int) -> Bool {
            (last[Lane(stream: stream, translated: false)]?.startMs ?? Int.min) > startMs
        }

        /// A newly arrived source can change even an already paired
        /// translation's owner. Rebuild that exceptional ordering from time.
        func hasTranslation(in stream: UUID?, atOrAfter startMs: Int) -> Bool {
            latestTranslationStart[stream].map { $0 >= startMs } ?? false
        }

        mutating func place(_ fragment: LiveFragment) -> Assignment {
            let lane = Lane(stream: fragment.id.streamID, translated: fragment.isTranslation)
            let speaker = Speaker(stream: fragment.id.streamID, speakerId: fragment.id.speakerId)
            let history = originals[speaker] ?? []
            var low = 0
            var high = history.count
            while low < high {
                let middle = (low + high) / 2
                if history[middle].startMs <= fragment.id.startMs { low = middle + 1 } else { high = middle }
            }
            let companion = fragment.isTranslation && low > 0 ? history[low - 1].index : nil
            let previous = last[lane]
            let paused = previous?.endMs.map {
                fragment.id.untimedOrdinal == nil && fragment.id.startMs - $0 >= 1000
            } ?? false
            let continues = previous?.speakerId == fragment.id.speakerId
                && fragment.id.speakerId != "note" && !fragment.id.speakerId.isEmpty
                && previous?.companion == companion && !paused
            let index = continues ? previous!.index : count
            if !continues { count += 1 }
            last[lane] = Boundary(index: index, speakerId: fragment.id.speakerId, endMs: fragment.endMs,
                                  startMs: fragment.id.startMs, companion: companion)
            if !fragment.isTranslation, fragment.id.speakerId != "note", !continues {
                originals[speaker, default: []].append(Original(index: index, startMs: fragment.id.startMs))
            }
            if fragment.isTranslation {
                latestTranslationStart[fragment.id.streamID] = max(latestTranslationStart[fragment.id.streamID] ?? Int.min,
                                                                  fragment.id.startMs)
            }
            return Assignment(index: index, isNew: !continues, companion: companion)
        }
    }

    private struct LiveBuilder {
        let id: RunID
        var body = LiveBody()
        var translation = ""
        var translationLanguage: String?
        var hasOriginal = false
        var hasPending = false
        var endMs: Int?

        init(_ fragment: LiveFragment) {
            id = fragment.id
            append(fragment)
        }

        mutating func append(_ fragment: LiveFragment) {
            if fragment.isTranslation {
                LiveTranscriptPresentation.append(fragment.text, origin: fragment.origin, to: &translation)
                translationLanguage = fragment.language ?? translationLanguage
            } else {
                body.append(fragment.text, origin: fragment.origin, isFinal: fragment.isFinal)
                hasOriginal = hasOriginal || !fragment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                hasPending = hasPending || !fragment.isFinal
                if let end = fragment.endMs { endMs = max(endMs ?? end, end) }
            }
        }

        func isVisible(showTranslations: Bool) -> Bool {
            hasOriginal || (showTranslations && !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        func row(names: [String: String], revision: UInt64, showTranslations: Bool) -> LiveRow {
            LiveRow(id: id, revision: revision, speakerId: id.speakerId,
                    speakerLabel: label(for: id.speakerId, names: names), startMs: id.untimedOrdinal == nil ? id.startMs : nil,
                    endMs: endMs, streamID: id.streamID, paragraphs: body.paragraphs,
                    translation: showTranslations ? translation : "",
                    translationLanguage: showTranslations ? translationLanguage : nil, hasPending: hasPending)
        }
    }

    private struct LiveBody {
        var frozen: [Paragraph] = []
        var open: [Span] = []
        var offset = 0
        var hasText = false

        mutating func append(_ text: String, origin: LiveEntry.TextOrigin, isFinal: Bool) {
            let addition: String
            if origin == .standalone {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                addition = (hasText ? " " : "") + trimmed
            } else {
                addition = text
            }
            guard !addition.isEmpty else { return }
            hasText = true
            if let last = open.indices.last, open[last].isFinal == isFinal {
                open[last].text += addition
            } else {
                open.append(Span(text: addition, isFinal: isFinal))
            }
        }

        mutating func freeze() {
            let paragraphs = paragraphLayout(open, offset: offset)
            guard paragraphs.count > 1, let last = paragraphs.last else { return }
            let cut = last.id - offset
            frozen.append(contentsOf: paragraphs.dropLast())
            open = slicedSpans(open, from: cut)
            offset += cut
        }

        var paragraphs: Paragraphs {
            Paragraphs(prefix: frozen[...], tail: paragraphLayout(open, offset: offset))
        }
    }

    private static func slicedSpans(_ spans: [Span], from offset: Int) -> [Span] {
        var position = 0
        return spans.compactMap { span in
            defer { position += span.text.count }
            let skipped = max(0, offset - position)
            guard skipped < span.text.count else { return nil }
            return Span(text: String(span.text.dropFirst(skipped)), isFinal: span.isFinal)
        }
    }

    private static func paragraphLayout(_ spans: [Span], offset: Int) -> [Paragraph] {
        let text = spans.map(\.text).joined()
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        var spanRanges: [(Range<Int>, Bool)] = []
        var position = 0
        for span in spans {
            let end = position + span.text.count
            spanRanges.append((position..<end, span.isFinal))
            position = end
        }
        return paragraphRanges(chars).compactMap { range in
            guard !range.isEmpty else { return nil }
            let styled = spanRanges.compactMap { spanRange, isFinal -> Span? in
                let lower = max(range.lowerBound, spanRange.lowerBound)
                let upper = min(range.upperBound, spanRange.upperBound)
                return lower < upper ? Span(text: String(chars[lower..<upper]), isFinal: isFinal) : nil
            }
            return Paragraph(id: offset + range.lowerBound, spans: styled)
        }
    }
}

extension LiveTranscriptPresentation.SliceCollection: Sendable where Element: Sendable {}
