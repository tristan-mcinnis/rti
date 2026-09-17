import Foundation

// Turns what a chat turn did into the records the thread draws (tool lines,
// sources, sent attachments), so the view never sniffs streamed text for
// progress. Pure: no AppKit, no clock, no disk. In memory only, like the chat.

/// Reads tool results and search traces into `ChatToolLine` and `ChatSource`
/// records.
public enum ToolTraceParser {
    // MARK: - Status text

    /// A tool's running status as the thread shows it: the leading emoji
    /// dropped ("📷 Looking at your screen…" becomes "Looking at your
    /// screen…"), white space trimmed.
    public static func statusText(_ raw: String) -> String {
        var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = text.first, isPictograph(first) {
            text = text.dropFirst()
            text = Substring(text.trimmingCharacters(in: .whitespaces))
        }
        return String(text)
    }

    /// True for an emoji-style character. ASCII digits, `#`, and `*` count
    /// as emoji to Unicode; they are text here.
    private static func isPictograph(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, scalar.value > 0x7F else { return false }
        return scalar.properties.isEmoji || scalar.properties.isEmojiPresentation
            || scalar.properties.generalCategory == .otherSymbol
    }

    // MARK: - Tool lines

    /// The line a finished tool call leaves above the answer. Nil for a
    /// tool with nothing to say.
    public static func toolLine(forTool name: String, result: String) -> ChatToolLine? {
        switch name {
        case "search_vault":
            return searchLine(resultCount: searchResultCount(in: result), scoped: false)
        case "grep_vault":
            let count = grepFileCount(in: result)
            return ChatToolLine(kind: .grepVault, text: "Searched vault text · " + (count == 0 ? "no matches" : plural(count, "file")))
        case "read_document":
            if result.hasPrefix("Couldn't read") || result.hasPrefix("Refused") {
                return ChatToolLine(kind: .readDocument, text: "Could not read a document")
            }
            if let title = documentTitle(in: result) {
                return ChatToolLine(kind: .readDocument, text: "Read \(title)")
            }
            return ChatToolLine(kind: .readDocument, text: "Read a document")
        case "list_files":
            let count = listedFileCount(in: result)
            return ChatToolLine(kind: .listFiles, text: "Listed files · " + (count == 0 ? "none" : "\(count)"))
        case "recent_meetings":
            let count = numberedLineCount(in: result)
            return ChatToolLine(kind: .recentMeetings, text: "Checked recent meetings · " + (count == 0 ? "none" : "\(count)"))
        case "capture_screen":
            return ChatToolLine(kind: .readScreen, text: "Read the screen")
        case "highlight_screen_text":
            return ChatToolLine(kind: .highlightScreen, text: "Marked text on the screen")
        default:
            guard !name.isEmpty else { return nil }
            return ChatToolLine(kind: .other, text: "Used \(name)")
        }
    }

    /// "Searched vault · 6 results", or "Searched this project" when the
    /// search was held to the meeting's project.
    public static func searchLine(resultCount: Int, scoped: Bool) -> ChatToolLine {
        let place = scoped ? "Searched this project" : "Searched vault"
        let count = resultCount == 0 ? "no results" : plural(resultCount, "result")
        return ChatToolLine(kind: .searchVault, text: "\(place) · \(count)")
    }

    /// Lines from a search trace string (`VaultRetrieval.Response.trace`:
    /// "Vault-wide search · 812ms · 6 sources: a.md, b.md, c.md, +3"), for
    /// a turn that only kept the trace. Timings are dropped: the thread
    /// says what happened, not how long it took.
    public static func lines(fromTrace trace: String) -> [ChatToolLine] {
        trace.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("vault-wide search") || lower.hasPrefix("vault search") {
                return searchLine(resultCount: traceSourceCount(in: line), scoped: false)
            }
            if lower.hasPrefix("scoped search") {
                return searchLine(resultCount: traceSourceCount(in: line), scoped: true)
            }
            return nil
        }
    }

    // MARK: - Sources

    /// The sources a `search_vault` result lists: each numbered line
    /// "1. Title (path.md, updated 2026-09-04)". Order kept, paths unique.
    public static func sources(inSearchResult text: String) -> [ChatSource] {
        let pattern = #"(?m)^\s*\d+\.\s+(.+?)\s+\(([^()]+?\.md),\s*updated\s+(\d{4}-\d{2}-\d{2})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [ChatSource] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let title = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let path = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let day = ns.substring(with: match.range(at: 3))
            guard !out.contains(where: { $0.path == path }) else { continue }
            out.append(ChatSource(title: title.isEmpty ? fileTitle(for: path) : title, path: path, date: date(fromDay: day)))
        }
        return out
    }

    /// A readable title for a path with no title of its own: the file name
    /// without `.md`, dashes and underscores as spaces.
    public static func fileTitle(for path: String) -> String {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        let spaced = stem.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spaced.isEmpty ? path : spaced
    }

    // MARK: - Counting

    static func searchResultCount(in result: String) -> Int {
        if let n = firstInteger(after: "Found ", in: result) { return n }
        return sources(inSearchResult: result).count
    }

    static func grepFileCount(in result: String) -> Int {
        if result.hasPrefix("No files") || result.hasPrefix("No query") || result.hasPrefix("Nothing") { return 0 }
        // "Files matching "q" … (12):" or "(50+):"
        let pattern = #"^Files matching .*\((\d+)\+?\):"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: (result as NSString).length)),
           let n = Int((result as NSString).substring(with: match.range(at: 1))) {
            return n
        }
        // "Files matching "q" in this context:" then one "• path" line.
        let bullets = result.split(separator: "\n").filter { $0.hasPrefix("• ") }.count
        return result.hasPrefix("Files matching") ? max(bullets, 1) : bullets
    }

    static func listedFileCount(in result: String) -> Int {
        guard result.hasPrefix("Files") else { return 0 }
        return result.split(separator: "\n").dropFirst().filter { $0.hasPrefix("  ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    static func numberedLineCount(in result: String) -> Int {
        result.split(separator: "\n").filter { line in
            let trimmed = line.drop { $0 == " " }
            guard let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex else { return false }
            return trimmed[trimmed.startIndex..<dot].allSatisfy(\.isNumber) && line.first?.isNumber == true
        }.count
    }

    /// The count in a trace line: "· 6 sources:" → 6; none → 0.
    static func traceSourceCount(in line: String) -> Int {
        let pattern = #"·\s*(\d+)\s+sources?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              let n = Int((line as NSString).substring(with: match.range(at: 1))) else { return 0 }
        return n
    }

    /// A read document's title: its frontmatter `title:`, else its first
    /// `# ` heading. Nil when it has neither.
    static func documentTitle(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(60).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" { break }
                if trimmed.lowercased().hasPrefix("title:") {
                    let value = trimmed.dropFirst("title:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !value.isEmpty { return value }
                }
            }
        }
        for line in lines where line.hasPrefix("# ") {
            let value = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func firstInteger(after prefix: String, in text: String) -> Int? {
        guard let range = text.range(of: prefix) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// "2026-09-04" as noon that day in the current calendar; nil if malformed.
    static func date(fromDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

/// Builds the records one chat turn carries: the chips over the question,
/// the context lines above the answer, and the chip and source details the
/// thread prints. The rules live here so they are testable without the app.
public enum ChatTurnRecordBuilder {
    /// A document attached from disk for one turn, as the composer hands it
    /// over. Sizes are optional: the loader may not report them.
    public struct AttachedFile: Equatable, Sendable {
        public let name: String
        public let path: String?
        public let byteCount: Int?
        public let pageCount: Int?
        public let wasCut: Bool

        public init(name: String, path: String? = nil, byteCount: Int? = nil, pageCount: Int? = nil, wasCut: Bool = false) {
            self.name = name
            self.path = path
            self.byteCount = byteCount
            self.pageCount = pageCount
            self.wasCut = wasCut
        }
    }

    // MARK: - Chips over the question

    /// What was sent with a question, in the order the composer strip shows
    /// it: vault files picked with `@`, then attached documents, then one
    /// read of the screen.
    public static func attachments(
        mentionPaths: [String],
        files: [AttachedFile],
        screenAttached: Bool
    ) -> [ChatAttachmentRef] {
        var refs: [ChatAttachmentRef] = []
        for path in mentionPaths where !refs.contains(where: { $0.kind == .vaultFile && $0.path == path }) {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            refs.append(ChatAttachmentRef(kind: .vaultFile, name: name, path: path))
        }
        for file in files {
            let kind: ChatAttachmentRef.Kind = file.name.lowercased().hasSuffix(".pdf") ? .pdf : .text
            refs.append(ChatAttachmentRef(
                kind: kind, name: file.name, path: file.path,
                byteCount: file.byteCount, pageCount: file.pageCount, wasCut: file.wasCut
            ))
        }
        if screenAttached {
            refs.append(ChatAttachmentRef(kind: .screen, name: "Screen"))
        }
        return refs
    }

    /// The chip's detail: "12 pp · 84 KB", "18 KB · cut", "once" for a
    /// screen read. Nil when there is nothing to add to the name.
    public static func chipDetail(for ref: ChatAttachmentRef) -> String? {
        var parts: [String] = []
        switch ref.kind {
        case .screen:
            return "once"
        case .pdf:
            if let pages = ref.pageCount { parts.append("\(pages) pp") }
            if let bytes = ref.byteCount { parts.append(byteText(bytes)) }
        case .text:
            if let bytes = ref.byteCount { parts.append(byteText(bytes)) }
        case .vaultFile:
            break
        }
        var detail = parts.joined(separator: " · ")
        if ref.wasCut { detail += detail.isEmpty ? "cut" : " · cut" }
        return detail.isEmpty ? nil : detail
    }

    /// The chip as VoiceOver reads it: spoken units ("12 pages"), never
    /// "pp".
    public static func chipAccessibilityLabel(for ref: ChatAttachmentRef) -> String {
        var parts = ["Attachment: \(ref.name)"]
        switch ref.kind {
        case .vaultFile: parts.append("vault file")
        case .pdf: parts.append("PDF")
        case .text: parts.append("text file")
        case .screen: parts.append("one read of the screen")
        }
        if let pages = ref.pageCount { parts.append("\(pages) page\(pages == 1 ? "" : "s")") }
        if let bytes = ref.byteCount { parts.append(byteText(bytes).replacingOccurrences(of: "KB", with: "kilobytes").replacingOccurrences(of: "MB", with: "megabytes")) }
        if ref.wasCut { parts.append("cut to fit") }
        return parts.joined(separator: ", ")
    }

    /// "84 KB", "1.2 MB", "900 bytes".
    public static func byteText(_ bytes: Int) -> String {
        if bytes < 1_000 { return "\(bytes) bytes" }
        if bytes < 1_000_000 { return "\(Int((Double(bytes) / 1_000).rounded())) KB" }
        let mb = Double(bytes) / 1_000_000
        return mb < 10 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB"
    }

    // MARK: - Lines above the answer

    /// What the turn read before the model answered: the transcript window
    /// and the screen. `transcriptMinutes` is nil when no transcript went in.
    public static func contextLines(
        transcriptMinutes: Int?,
        wholeTranscript: Bool,
        screenRead: Bool,
        screenFromTrail: Bool
    ) -> [ChatToolLine] {
        var lines: [ChatToolLine] = []
        if let minutes = transcriptMinutes {
            lines.append(transcriptLine(minutes: minutes, wholeTranscript: wholeTranscript))
        }
        if screenRead {
            lines.append(ChatToolLine(kind: .readScreen, text: "Read the screen"))
        } else if screenFromTrail {
            lines.append(ChatToolLine(kind: .readScreen, text: "Used recent screen context"))
        }
        return lines
    }

    /// "Used the last 6 min of the transcript", or "Used the whole
    /// transcript · 42 min".
    public static func transcriptLine(minutes: Int, wholeTranscript: Bool) -> ChatToolLine {
        let span = max(1, minutes)
        let text = wholeTranscript
            ? "Used the whole transcript · \(span) min"
            : "Used the last \(span) min of the transcript"
        return ChatToolLine(kind: .transcript, text: text)
    }

    /// Minutes a transcript window covers, rounded up: from its first line
    /// to its last, in milliseconds since the session began.
    public static func transcriptMinutes(firstStartMs: Int, lastStartMs: Int) -> Int {
        let span = max(0, lastStartMs - firstStartMs)
        return max(1, Int((Double(span) / 60_000).rounded(.up)))
    }

    /// Adds a line unless the same line is already there.
    public static func appending(_ line: ChatToolLine, to lines: [ChatToolLine]) -> [ChatToolLine] {
        lines.contains(line) ? lines : lines + [line]
    }

    /// Adds sources whose path is not listed yet, order kept.
    public static func merging(_ new: [ChatSource], into sources: [ChatSource]) -> [ChatSource] {
        var out = sources
        for source in new where !out.contains(where: { $0.path == source.path }) {
            out.append(source)
        }
        return out
    }

    // MARK: - The question pill

    /// A canned action as its pill draws it: the short name and the glyph
    /// from the action catalogue. Nil for a typed question or command.
    public static func cannedAction(for action: String?) -> (label: String, symbol: String)? {
        guard let action else { return nil }
        let ids: [String: String] = [
            "Assist": "assist",
            "Answer latest": "answerLatest",
            "Say next": "sayNext",
            "Follow-ups": "followups",
            "Key tensions": "keyTensions",
            "Probe": "probe",
            "Themes": "themes",
            "Recap": "recap",
            "Quick recap": "quickRecap",
            "Summary": "summary",
        ]
        guard let id = ids[action], let entry = AssistantAction.byID(id) else { return nil }
        return (action, entry.symbol)
    }

    /// The pill's words for a canned action: its name, and for a recap its
    /// depth ("Recap · brief").
    public static func pillLabel(forAction action: String, recapDepth: RecapDepth) -> String {
        action == "Recap" ? "\(action) · \(recapDepth.rawValue)" : action
    }

    // MARK: - Sources list

    /// The day a source row shows: "2026-09-04".
    public static func dayText(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Sources as the Copy Sources action writes them: one path a line.
    public static func sourcesText(_ sources: [ChatSource]) -> String {
        sources.map(\.path).joined(separator: "\n")
    }
}
