import Foundation

public enum LiveTranscriptPresentation {
    public struct Row: Identifiable, Equatable {
        public let id: UUID
        public let speakerId: String
        public let speakerLabel: String
        public let startMs: Int
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

        public init(speakerId: String, text: String) {
            self.speakerId = speakerId
            self.text = text
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

            if canMerge, let lastIndex = result.indices.last {
                if isTranslation {
                    append(entry.text, to: &result[lastIndex].translation)
                    result[lastIndex].translationLanguage = entry.language ?? result[lastIndex].translationLanguage
                } else {
                    append(entry.text, to: &result[lastIndex].original)
                }
            } else {
                result.append(Row(
                    id: entry.id,
                    speakerId: entry.speakerId,
                    speakerLabel: label(for: entry.speakerId, names: names),
                    startMs: entry.startMs,
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

    /// Where interim segments go: those from the speaker of the last final
    /// run continue that run in place (`inline`); the rest open runs of their
    /// own below it (`trailing`). So interim words settle where they appear.
    public static func placeInterim(
        _ segments: [InterimSegment],
        afterSpeaker lastSpeakerId: String?
    ) -> (inline: String, trailing: [InterimSegment]) {
        guard let lastSpeakerId, lastSpeakerId != "note", !lastSpeakerId.isEmpty else {
            return ("", segments)
        }
        let inline = segments.filter { $0.speakerId == lastSpeakerId }.map(\.text).joined(separator: " ")
        return (inline, segments.filter { $0.speakerId != lastSpeakerId })
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
        var result: [String] = []
        var start = 0
        var i = 0
        func close(through end: Int) {
            let paragraph = String(chars[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { result.append(paragraph) }
            var next = end + 1
            while next < chars.count, chars[next].isWhitespace { next += 1 }
            start = next
        }
        while i < chars.count {
            let length = i - start + 1
            let c = chars[i]
            if length >= softLimit, sentenceEnds.contains(c) {
                let atEnd = i + 1 >= chars.count
                if atEnd || chars[i + 1].isWhitespace || closesWithoutSpace.contains(c) {
                    close(through: i)
                    i = start
                    continue
                }
            }
            if length >= hardLimit, c.isWhitespace {
                close(through: i)
                i = start
                continue
            }
            i += 1
        }
        let open = start < chars.count
            ? String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        result.append(open)
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

    private static func append(_ text: String, to target: inout String) {
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
