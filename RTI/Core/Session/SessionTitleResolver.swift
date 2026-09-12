import Foundation

/// Where a session's title came from. Ordered: the first source that has a
/// title wins (see `SessionTitleResolver.resolve`).
public enum SessionTitleSource: String, Sendable, CaseIterable {
    /// `title.txt` with `title-manual.txt` beside it: the user typed it.
    case manual
    /// `title.txt` from the end-of-session summary call (`TITLE:` line).
    case summary
    /// The vault meeting note whose frontmatter names this session
    /// (`source: rti-session-<yyyyMMdd-HHmmss>`).
    case vaultNote
    /// The calendar event picked in Prepare (`session.json` `calendarTitle`).
    case calendar
    /// The short title the Sessions window generated from the note headings
    /// (`title.txt` whose text matches `title-generated.txt`).
    case generated
    /// The first substantive line of `transcript.md`. Needs no model call,
    /// so a session that never got a summary still reads as itself.
    case transcriptLine
    /// Built from the date and length. Never "Untitled session".
    case fallback
    /// "Short test · 12 s": a tiny transcript from a session under two
    /// minutes. The title names the length, not the day.
    case shortTest
}

/// A resolved title and its source.
public struct ResolvedSessionTitle: Equatable, Sendable {
    public let text: String
    public let source: SessionTitleSource

    public init(text: String, source: SessionTitleSource) {
        self.text = text
        self.source = source
    }
}

/// What the resolver reads for one session. Every field is optional: an old
/// archive, a legacy recorded meeting, or a failed summary leaves gaps.
public struct SessionTitleInputs: Equatable, Sendable {
    /// Trimmed `title.txt`, or nil when missing or empty.
    public var titleFile: String?
    /// `title-manual.txt` exists.
    public var hasManualMarker: Bool
    /// Trimmed `title-generated.txt`: the text the generator last wrote.
    public var generatedMarker: String?
    /// The vault meeting note's `title:` for this session.
    public var vaultNoteTitle: String?
    /// `session.json` `calendarTitle`.
    public var calendarTitle: String?
    /// The head of `transcript.md`, for the first-substantive-line title.
    /// A bounded prefix is enough; the caller need not read the whole file.
    public var transcriptHead: String?
    public var startedAt: Date?
    public var durationSeconds: Int?
    /// Size of `transcript.md` in bytes; nil when there is none.
    public var transcriptBytes: Int?

    public init(
        titleFile: String? = nil,
        hasManualMarker: Bool = false,
        generatedMarker: String? = nil,
        vaultNoteTitle: String? = nil,
        calendarTitle: String? = nil,
        transcriptHead: String? = nil,
        startedAt: Date? = nil,
        durationSeconds: Int? = nil,
        transcriptBytes: Int? = nil
    ) {
        self.titleFile = titleFile
        self.hasManualMarker = hasManualMarker
        self.generatedMarker = generatedMarker
        self.vaultNoteTitle = vaultNoteTitle
        self.calendarTitle = calendarTitle
        self.transcriptHead = transcriptHead
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.transcriptBytes = transcriptBytes
    }
}

/// Resolves the title the Sessions window shows for an archived session,
/// without depending on the end-of-session summary call (which fails on
/// some long meetings and used to leave "Untitled session" rows).
///
/// First hit wins:
/// 1. a manual title, 2. the summary's title, 3. the vault meeting note's
/// title, 4. the calendar event title, 5. a generated title, 6. a
/// descriptive fallback ("Meeting · Sep 4, 15:00 · 16 min", or
/// "Short test · 12 s" for a transcript under 1 KB from a session under
/// two minutes).
///
/// Pure: the caller reads the files; this only decides.
public enum SessionTitleResolver {
    /// A transcript smaller than this is a short test, not a meeting...
    public static let shortTestByteLimit = 1024
    /// ...unless the session ran longer than this: a long session with a
    /// tiny transcript is a meeting whose transcript failed, not a test.
    public static let shortTestMaxSeconds = 120
    /// The longest generated title kept, in characters.
    public static let generatedTitleMaxLength = 80
    /// The most note headings sent to the title call.
    public static let headingLimit = 12
    /// The title file names inside a session folder.
    public static let titleFileName = "title.txt"
    public static let manualMarkerFileName = "title-manual.txt"
    public static let generatedMarkerFileName = "title-generated.txt"

    public static func resolve(
        _ inputs: SessionTitleInputs,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ResolvedSessionTitle {
        if let title = clean(inputs.titleFile) {
            if inputs.hasManualMarker {
                return ResolvedSessionTitle(text: title, source: .manual)
            }
            if title != clean(inputs.generatedMarker) {
                return ResolvedSessionTitle(text: title, source: .summary)
            }
        }
        if let title = clean(inputs.vaultNoteTitle) {
            return ResolvedSessionTitle(text: title, source: .vaultNote)
        }
        if let title = clean(inputs.calendarTitle) {
            return ResolvedSessionTitle(text: title, source: .calendar)
        }
        if let title = clean(inputs.titleFile) {
            // Only reachable when title.txt is the generator's own text.
            return ResolvedSessionTitle(text: title, source: .generated)
        }
        // Nothing named this session, so let it name itself: the first line
        // anyone actually said. No model call, so it works for a session
        // whose summary failed and for one recorded with no key at all.
        // A short test keeps the "Short test · 12 s" label instead.
        if !isShortTest(transcriptBytes: inputs.transcriptBytes, durationSeconds: inputs.durationSeconds),
           let head = inputs.transcriptHead,
           let title = firstSubstantiveLine(fromTranscriptMarkdown: head) {
            return ResolvedSessionTitle(text: title, source: .transcriptLine)
        }
        return ResolvedSessionTitle(
            text: fallbackTitle(
                startedAt: inputs.startedAt,
                durationSeconds: inputs.durationSeconds,
                transcriptBytes: inputs.transcriptBytes,
                now: now,
                calendar: calendar
            ),
            source: isShortTest(transcriptBytes: inputs.transcriptBytes, durationSeconds: inputs.durationSeconds)
                ? .shortTest
                : .fallback
        )
    }

    /// A tiny transcript from a short session: a test, not a meeting.
    public static func isShortTest(transcriptBytes: Int?, durationSeconds: Int?) -> Bool {
        guard let bytes = transcriptBytes else { return false }
        return bytes < shortTestByteLimit && (durationSeconds ?? 0) < shortTestMaxSeconds
    }

    /// Whether the window should try a generated title: nothing better than
    /// a built label or a raw transcript line, and notes to build it from.
    /// A generated title reads better than either, so both invite one.
    public static func wantsGeneratedTitle(_ resolved: ResolvedSessionTitle, hasNotes: Bool) -> Bool {
        (resolved.source == .fallback || resolved.source == .transcriptLine) && hasNotes
    }

    /// "Meeting · Sep 4, 15:00 · 16 min", "Short test · 12 s", or "Meeting".
    public static func fallbackTitle(
        startedAt: Date?,
        durationSeconds: Int?,
        transcriptBytes: Int?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if isShortTest(transcriptBytes: transcriptBytes, durationSeconds: durationSeconds) {
            return (["Short test"] + [durationSeconds.map(durationText)].compactMap { $0 })
                .joined(separator: " · ")
        }
        var parts = ["Meeting"]
        if let startedAt {
            parts.append(dayAndTime(startedAt, now: now, calendar: calendar))
        }
        if let durationSeconds {
            parts.append(durationText(durationSeconds))
        }
        return parts.joined(separator: " · ")
    }

    /// The live overlay's header title: the calendar event, then the
    /// project, then "Live session".
    public static func liveTitle(calendarTitle: String?, project: String?) -> String {
        clean(calendarTitle) ?? clean(project) ?? "Live session"
    }

    /// "12 s", "16 min", "1 hr", "1 hr 4 min".
    public static func durationText(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds) s" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// "Sep 4, 15:00"; the year joins when it is not this year.
    public static func dayAndTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return SessionsWindowRules.format(date, sameYear ? "MMM d, HH:mm" : "MMM d, yyyy, HH:mm", calendar: calendar)
    }

    // MARK: - Generated titles

    /// The slice headings of `notes.md` ("### 0:00 – 8:00 · Plan table"),
    /// without their time ranges, in order and without repeats.
    public static func noteHeadings(fromNotesMarkdown markdown: String) -> [String] {
        var seen = Set<String>()
        var headings: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("### ") else { continue }
            var heading = String(trimmed.dropFirst(4))
            if let dot = heading.range(of: " · ") {
                heading = String(heading[dot.upperBound...])
            }
            heading = heading.trimmingCharacters(in: .whitespaces)
            guard !heading.isEmpty, seen.insert(heading.lowercased()).inserted else { continue }
            headings.append(heading)
            if headings.count == headingLimit { break }
        }
        return headings
    }

    /// The prompt for the short title call. Small input: headings only.
    public static func titlePrompt(headings: [String]) -> String {
        """
        Write a short title, 3 to 7 words, for a meeting from the section headings of its notes. \
        Lead with the kind of meeting (Briefing, Review, Interview, Planning, Debrief) when the \
        headings make it clear, then the subject. Reply with the title only: no quotes, no \
        trailing punctuation, no prefix.

        Note headings:
        \(headings.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    /// The model's reply as a title: first line, no "TITLE:" prefix, no
    /// quotes or Markdown marks, no trailing punctuation, one space between
    /// words, at most `generatedTitleMaxLength` characters (cut at a word).
    /// Nil when nothing usable is left.
    public static func cleanGeneratedTitle(_ raw: String) -> String? {
        guard var line = raw.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        if line.lowercased().hasPrefix("title:") {
            line = String(line.dropFirst("title:".count))
        }
        let marks = CharacterSet(charactersIn: "\"'“”‘’*_#`")
        line = line.trimmingCharacters(in: marks.union(.whitespaces))
        while let last = line.last, ".,;:!".contains(last) {
            line.removeLast()
        }
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: marks.union(.whitespaces))
        if line.count > generatedTitleMaxLength {
            var cut = String(line.prefix(generatedTitleMaxLength))
            if let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
            line = cut
        }
        return line.isEmpty ? nil : line
    }

    // MARK: - The first substantive transcript line

    /// The fewest characters a transcript line needs to name a session.
    public static let transcriptLineMinimumCharacters = 25
    /// ...and the fewest words, so "Okay so yeah alright" never wins.
    public static let transcriptLineMinimumWords = 5

    /// The first substantive spoken line of `transcript.md`, cleaned into a
    /// title. Entry lines are written as:
    ///
    ///     `0:00` **Speaker 1:** Let's start with the Project Zeta scope.
    ///
    /// Frontmatter, the `# Transcript` heading, the date line, and typed
    /// notes (`📝 Note`) are skipped, as is any line too short or too thin to
    /// say what the session was about. Nil when nothing qualifies.
    ///
    /// Pure: the caller reads a bounded head of the file, not all of it.
    public static func firstSubstantiveLine(fromTranscriptMarkdown markdown: String) -> String? {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Every entry opens with its `mm:ss` stamp in backticks; nothing
            // else in the file does.
            guard trimmed.hasPrefix("`"),
                  let closingTick = trimmed.dropFirst().firstIndex(of: "`")
            else { continue }

            var spoken = String(trimmed[trimmed.index(after: closingTick)...])
                .trimmingCharacters(in: .whitespaces)
            if spoken.hasPrefix("**") {
                let afterMarks = spoken.index(spoken.startIndex, offsetBy: 2)
                if let close = spoken.range(of: "**", range: afterMarks..<spoken.endIndex) {
                    // A typed note is the user's aside, not the meeting.
                    guard !spoken[afterMarks..<close.lowerBound].contains("Note") else { continue }
                    spoken = String(spoken[close.upperBound...])
                }
            }
            spoken = spoken
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")

            guard spoken.count >= transcriptLineMinimumCharacters,
                  spoken.split(whereSeparator: \.isWhitespace).count >= transcriptLineMinimumWords,
                  let title = cleanGeneratedTitle(spoken)
            else { continue }
            return title
        }
        return nil
    }

    // MARK: - Helpers

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
