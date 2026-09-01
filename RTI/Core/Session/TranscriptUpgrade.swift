import Foundation

public struct TranscriptUpgradeSegment: Equatable, Sendable {
    public let speaker: String
    public let startMs: Int
    public let text: String

    public init(speaker: String, startMs: Int, text: String) {
        self.speaker = speaker
        self.startMs = startMs
        self.text = text
    }
}

public struct TranscriptUpgradeNote: Equatable, Sendable {
    public let startMs: Int
    public let text: String

    public init(startMs: Int, text: String) {
        self.startMs = startMs
        self.text = text
    }
}

public struct TranscriptUpgradeAudioInput: Equatable, Sendable {
    public let url: URL
    public let offsetMs: Int
    public let defaultSpeaker: String

    public init(url: URL, offsetMs: Int, defaultSpeaker: String = "Speaker 1") {
        self.url = url
        self.offsetMs = offsetMs
        self.defaultSpeaker = defaultSpeaker
    }
}

public struct TranscriptUpgradeExecutionResult: Equatable, Sendable {
    public let transcriptURL: URL
    public let summaryURL: URL?
    public let segmentCount: Int
    public let sourceFiles: [String]
    public let artifactResult: TranscriptUpgradeArtifacts.WriteResult

    public init(
        transcriptURL: URL,
        summaryURL: URL?,
        segmentCount: Int,
        sourceFiles: [String],
        artifactResult: TranscriptUpgradeArtifacts.WriteResult
    ) {
        self.transcriptURL = transcriptURL
        self.summaryURL = summaryURL
        self.segmentCount = segmentCount
        self.sourceFiles = sourceFiles
        self.artifactResult = artifactResult
    }
}

public enum TranscriptUpgradePipelineError: LocalizedError, Equatable {
    case missingAudio
    case unreadableTranscript
    case emptyTranscript(String)
    case missingSessionDate

    public var errorDescription: String? {
        switch self {
        case .missingAudio:
            return "No retained audio found in this session folder."
        case .unreadableTranscript:
            return "Couldn't read the original transcript."
        case .emptyTranscript(let provider):
            return "\(provider) returned an empty transcript; the original transcript was left unchanged."
        case .missingSessionDate:
            return "session folder name is not a timestamp"
        }
    }
}

public enum TranscriptUpgradeAudioDiscovery {
    public static func inputs(in dir: URL) -> [TranscriptUpgradeAudioInput] {
        let metadata = readMetadata(in: dir)
        let micName = safeAudioFileName(
            metadata?.micAudioFile,
            fallbacks: ["audio-mic.wav", "audio-mic.m4a"],
            in: dir
        )
        let systemName = safeAudioFileName(
            metadata?.systemAudioFile,
            fallbacks: ["audio-system.wav", "audio-system.m4a"],
            in: dir
        )
        let candidates = [
            TranscriptUpgradeAudioInput(url: dir.appendingPathComponent(micName), offsetMs: 0, defaultSpeaker: "Speaker 1"),
            TranscriptUpgradeAudioInput(url: dir.appendingPathComponent(systemName), offsetMs: metadata?.systemAudioStartOffsetMs ?? 0, defaultSpeaker: "Remote speaker")
        ]
        var seen = Set<String>()
        return candidates.filter { input in
            guard FileManager.default.fileExists(atPath: input.url.path) else { return false }
            guard hasAudioPayload(input.url) else { return false }
            return seen.insert(input.url.standardizedFileURL.path).inserted
        }
    }

    /// A crash before the delayed system leg receives its first frame leaves
    /// a valid header-only WAV. Ignore it so the complete mic leg can still be
    /// upgraded. Legacy retained formats keep their existing discovery rule.
    private static func hasAudioPayload(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "wav" else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44), header.count == 44,
              String(data: header[0..<4], encoding: .ascii) == "RIFF",
              String(data: header[36..<40], encoding: .ascii) == "data" else { return false }
        let size = header[40..<44].enumerated().reduce(UInt32(0)) { result, byte in
            result | (UInt32(byte.element) << UInt32(byte.offset * 8))
        }
        return size > 0
    }

    private static func safeAudioFileName(_ value: String?, fallbacks: [String], in dir: URL) -> String {
        if let value {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return URL(fileURLWithPath: trimmed).lastPathComponent }
        }
        return fallbacks.first {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        } ?? fallbacks[0]
    }

    private static func readMetadata(in dir: URL) -> ArchiveMetadata? {
        let url = dir.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ArchiveMetadata.self, from: data)
    }

    private struct ArchiveMetadata: Decodable {
        let systemAudioStartOffsetMs: Int?
        let micAudioFile: String?
        let systemAudioFile: String?
    }
}

public enum TranscriptUpgradePipeline {
    public typealias Transcribe = @Sendable (_ audioURL: URL, _ outputBaseURL: URL) async throws -> String
    public typealias WriteSummary = @Sendable (_ transcriptText: String) async -> URL?
    public typealias Progress = @Sendable (_ message: String) -> Void

    public static func upgrade(
        sessionDir: URL,
        startedAt: Date?,
        providerID: String,
        providerDisplayName: String,
        frontmatter: [String],
        progress: Progress,
        transcribe: Transcribe,
        writeSummary: WriteSummary,
        runRouter: @Sendable () -> Void
    ) async throws -> TranscriptUpgradeExecutionResult {
        let originalTranscriptURL = sessionDir.appendingPathComponent("transcript.md")
        guard let originalTranscript = try? String(contentsOf: originalTranscriptURL, encoding: .utf8) else {
            throw TranscriptUpgradePipelineError.unreadableTranscript
        }
        let notes = TranscriptUpgradeMerge.notes(from: originalTranscript)

        let inputs = TranscriptUpgradeAudioDiscovery.inputs(in: sessionDir)
        guard !inputs.isEmpty else { throw TranscriptUpgradePipelineError.missingAudio }

        var segments: [TranscriptUpgradeSegment] = []
        var sourceFiles: [String] = []
        for input in inputs {
            sourceFiles.append(input.url.lastPathComponent)
            progress("Transcribing \(input.url.lastPathComponent)")
            let outputBase = sessionDir.appendingPathComponent("transcript-upgrade-\(providerID)-\(input.url.deletingPathExtension().lastPathComponent)")
            let text = try await transcribe(input.url, outputBase)
            let parsed = TranscriptUpgradeMerge.segments(
                from: text,
                defaultSpeaker: input.defaultSpeaker,
                offsetMs: input.offsetMs
            )
            segments.append(contentsOf: parsed)
        }
        guard !segments.isEmpty else {
            throw TranscriptUpgradePipelineError.emptyTranscript(providerDisplayName)
        }
        guard let startedAt else {
            throw TranscriptUpgradePipelineError.missingSessionDate
        }

        progress("Preserving \(notes.count) note\(notes.count == 1 ? "" : "s")")
        let body = TranscriptUpgradeMerge.renderBody(
            startedAt: startedAt,
            endedAt: nil,
            segments: segments,
            notes: notes,
            provider: providerDisplayName,
            sourceFiles: sourceFiles
        )
        let md = (frontmatter + [body, ""]).joined(separator: "\n")

        progress("Writing upgraded transcript")
        let artifactResult = try TranscriptUpgradeArtifacts.installUpgradedTranscript(markdown: md, in: sessionDir)

        progress("Regenerating summary")
        let summaryURL = await writeSummary(body)
        runRouter()

        return TranscriptUpgradeExecutionResult(
            transcriptURL: originalTranscriptURL,
            summaryURL: summaryURL,
            segmentCount: segments.count,
            sourceFiles: sourceFiles,
            artifactResult: artifactResult
        )
    }
}

public enum TranscriptUpgradeMerge {
    public static func notes(from markdown: String) -> [TranscriptUpgradeNote] {
        // Two shapes: inline `**📝 Note:**` lines (live transcripts) and the
        // `- \`m:ss\` text` bullets under "## Session notes" that upgraded
        // transcripts carry — re-upgrading must not drop the notes.
        var inSessionNotes = false
        var found: [TranscriptUpgradeNote] = []
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                inSessionNotes = trimmed == "## Session notes"
                continue
            }
            if inSessionNotes, trimmed.hasPrefix("- `") {
                if let note = sessionNoteBullet(fromLine: trimmed) { found.append(note) }
            } else if let note = note(fromLine: line) {
                found.append(note)
            }
        }
        return found.sorted { $0.startMs < $1.startMs }
    }

    private static func sessionNoteBullet(fromLine line: String) -> TranscriptUpgradeNote? {
        let body = String(line.dropFirst(2))
        guard let firstTick = body.firstIndex(of: "`"),
              let secondTick = body[body.index(after: firstTick)...].firstIndex(of: "`"),
              let ms = milliseconds(from: String(body[body.index(after: firstTick)..<secondTick])) else { return nil }
        let text = String(body[body.index(after: secondTick)...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : TranscriptUpgradeNote(startMs: ms, text: text)
    }

    public static func segments(from text: String, defaultSpeaker: String = "Speaker 1", offsetMs: Int = 0) -> [TranscriptUpgradeSegment] {
        var segments: [TranscriptUpgradeSegment] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let parsed = timestampedSegment(fromLine: line, defaultSpeaker: defaultSpeaker, offsetMs: offsetMs) {
                let speaker: String
                if defaultSpeaker == "Remote speaker", parsed.speaker.hasPrefix("Speaker ") {
                    speaker = "Remote \(parsed.speaker.lowercased())"
                } else {
                    speaker = parsed.speaker
                }
                segments.append(TranscriptUpgradeSegment(speaker: speaker, startMs: parsed.startMs, text: parsed.text))
            }
        }
        if segments.isEmpty {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                segments.append(TranscriptUpgradeSegment(speaker: defaultSpeaker, startMs: offsetMs, text: body))
            }
        }
        return segments
    }

    public static func renderBody(
        startedAt: Date,
        endedAt: Date?,
        segments: [TranscriptUpgradeSegment],
        notes: [TranscriptUpgradeNote],
        provider: String,
        sourceFiles: [String],
        generatedAt: Date = Date()
    ) -> String {
        var lines = [
            "# Transcript",
            "",
            header(startedAt: startedAt, endedAt: endedAt),
            "",
            "_Upgraded with \(provider) on \(upgradeStamp.string(from: generatedAt)). Source audio: \(sourceFiles.joined(separator: ", "))._",
            "",
        ]

        // Notes typed during the session are real-time context aids, not part
        // of the conversation — keep the upgraded transcript body pure speech
        // and collect the notes in a trailing section instead.
        let orderedSegments = segments.enumerated().sorted { lhs, rhs in
            if lhs.element.startMs == rhs.element.startMs { return lhs.offset < rhs.offset }
            return lhs.element.startMs < rhs.element.startMs
        }
        for (_, segment) in orderedSegments {
            lines.append("`\(offset(segment.startMs))` **\(segment.speaker):** \(segment.text)")
            lines.append("")
        }

        if !notes.isEmpty {
            lines.append("## Session notes")
            lines.append("")
            let orderedNotes = notes.enumerated().sorted { lhs, rhs in
                if lhs.element.startMs == rhs.element.startMs { return lhs.offset < rhs.offset }
                return lhs.element.startMs < rhs.element.startMs
            }
            for (_, note) in orderedNotes {
                lines.append("- `\(offset(note.startMs))` \(note.text)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func note(fromLine line: String) -> TranscriptUpgradeNote? {
        guard line.contains("Note:") || line.contains("📝") else { return nil }
        guard let firstTick = line.firstIndex(of: "`"),
              let secondTick = line[line.index(after: firstTick)...].firstIndex(of: "`") else { return nil }
        let stamp = String(line[line.index(after: firstTick)..<secondTick])
        guard let ms = milliseconds(from: stamp) else { return nil }
        guard let markerRange = line.range(of: "Note:**") ?? line.range(of: "Note:") else { return nil }
        let text = line[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : TranscriptUpgradeNote(startMs: ms, text: text)
    }

    private static func timestampedSegment(fromLine line: String, defaultSpeaker: String, offsetMs: Int) -> TranscriptUpgradeSegment? {
        let candidates: [(String, String)]
        if line.hasPrefix("["),
           let close = line.firstIndex(of: "]") {
            let stamp = String(line[line.index(after: line.startIndex)..<close])
            let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            candidates = [(stamp, rest)]
        } else if line.hasPrefix("`"),
                  let close = line[line.index(after: line.startIndex)...].firstIndex(of: "`") {
            let stamp = String(line[line.index(after: line.startIndex)..<close])
            let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            candidates = [(stamp, rest)]
        } else {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            candidates = parts.count == 2 ? [(parts[0], parts[1])] : []
        }

        for (stamp, rest) in candidates {
            guard let baseMs = milliseconds(from: stamp) else { continue }
            let cleaned = rest.trimmingCharacters(in: CharacterSet(charactersIn: "-–— ").union(.whitespaces))
            let split = speakerAndText(from: cleaned, defaultSpeaker: defaultSpeaker)
            guard !split.text.isEmpty else { continue }
            return TranscriptUpgradeSegment(speaker: split.speaker, startMs: baseMs + offsetMs, text: split.text)
        }
        return nil
    }

    private static func speakerAndText(from line: String, defaultSpeaker: String) -> (speaker: String, text: String) {
        if let range = line.range(of: ":") {
            let speaker = String(line[..<range.lowerBound])
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !speaker.isEmpty, speaker.count <= 40 {
                return (speaker, text)
            }
        }
        return (defaultSpeaker, line)
    }

    private static func milliseconds(from stamp: String) -> Int? {
        let cleaned = stamp.trimmingCharacters(in: CharacterSet(charactersIn: "[]` "))
        let parts = cleaned.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsPart = parts.last ?? ""
        let wholeSeconds = secondsPart.split(separator: ".").first.map(String.init) ?? secondsPart
        guard let seconds = Int(wholeSeconds),
              let minutes = Int(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? (Int(parts[0]) ?? 0) : 0
        return ((hours * 3600) + (minutes * 60) + seconds) * 1000
    }

    private static func header(startedAt: Date, endedAt: Date?) -> String {
        let started = headerStamp.string(from: startedAt)
        guard let endedAt else { return "_\(started)_" }
        let seconds = Int(max(0, endedAt.timeIntervalSince(startedAt)))
        return "_\(started) · \(duration(seconds))_"
    }

    private static func offset(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func duration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private static let headerStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let upgradeStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

public enum CanonicalMeetingTranscript {
    public static func render(entries: [LiveEntry]) -> String {
        let spoken = entries
            .filter { $0.speakerId != "note" && $0.translationStatus != "translation" }
            .sorted { $0.startMs < $1.startMs }
        guard !spoken.isEmpty else { return "" }

        let label = speakerLabeler(for: spoken)
        return spoken.map { entry in
            "[\(offset(entry.startMs))] \(label(entry.speakerId)): \(entry.text)"
        }.joined(separator: "\n\n")
    }

    public static func render(markdownTranscript: String) -> String {
        bodyAfterFrontmatter(markdownTranscript)
            .components(separatedBy: .newlines)
            .compactMap(canonicalLine(fromMarkdownLine:))
            .joined(separator: "\n\n")
    }

    private static func speakerLabeler(for entries: [LiveEntry]) -> (String) -> String {
        var numbers: [String: Int] = [:]
        var next = 1
        for entry in entries where numbers[entry.speakerId] == nil {
            numbers[entry.speakerId] = next
            next += 1
        }
        return { id in
            if let n = numbers[id] { return "Speaker \(n)" }
            return "Speaker ?"
        }
    }

    private static func canonicalLine(fromMarkdownLine raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("`"),
              let closeTick = line[line.index(after: line.startIndex)...].firstIndex(of: "`") else {
            return nil
        }
        let rawStamp = String(line[line.index(after: line.startIndex)..<closeTick])
        let rest = line[line.index(after: closeTick)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("**"),
              let endMarker = rest.range(of: ":**") else {
            return nil
        }
        let speakerStart = rest.index(rest.startIndex, offsetBy: 2)
        let speaker = rest[speakerStart..<endMarker.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speaker.isEmpty,
              !speaker.localizedCaseInsensitiveContains("note"),
              !speaker.contains("📝") else {
            return nil
        }
        let text = rest[endMarker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let stamp = milliseconds(from: rawStamp).map(offset) ?? rawStamp
        return "[\(stamp)] \(speaker): \(text)"
    }

    private static func bodyAfterFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---"),
              let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return text
        }
        return String(text[end.upperBound...]).trimmingCharacters(in: .newlines)
    }

    private static func milliseconds(from stamp: String) -> Int? {
        let cleaned = stamp.trimmingCharacters(in: CharacterSet(charactersIn: "[]` "))
        let parts = cleaned.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsPart = parts.last ?? ""
        let wholeSeconds = secondsPart.split(separator: ".").first.map(String.init) ?? secondsPart
        guard let seconds = Int(wholeSeconds),
              let minutes = Int(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? (Int(parts[0]) ?? 0) : 0
        return ((hours * 3600) + (minutes * 60) + seconds) * 1000
    }

    private static func offset(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

public enum TranscriptUpgradeArtifacts {
    public struct WriteResult: Equatable, Sendable {
        public let upgradedURL: URL
        public let transcriptBackupURL: URL?
        public let summaryBackupURL: URL?

        public init(upgradedURL: URL, transcriptBackupURL: URL?, summaryBackupURL: URL?) {
            self.upgradedURL = upgradedURL
            self.transcriptBackupURL = transcriptBackupURL
            self.summaryBackupURL = summaryBackupURL
        }
    }

    public static func installUpgradedTranscript(
        markdown: String,
        in sessionDir: URL,
        backupStamp: String? = nil
    ) throws -> WriteResult {
        let backupStamp = backupStamp ?? timestamp.string(from: Date())
        let upgradedURL = sessionDir.appendingPathComponent("transcript.upgraded.md")
        let transcriptURL = sessionDir.appendingPathComponent("transcript.md")
        let summaryURL = sessionDir.appendingPathComponent("summary.md")

        try writeOwnerOnly(markdown, to: upgradedURL)
        let transcriptBackup = try backupIfPresent(transcriptURL, stamp: backupStamp)
        try replaceRecoverably(source: upgradedURL, destination: transcriptURL)
        let summaryBackup = try backupIfPresent(summaryURL, stamp: backupStamp)

        return WriteResult(
            upgradedURL: upgradedURL,
            transcriptBackupURL: transcriptBackup,
            summaryBackupURL: summaryBackup
        )
    }

    private static func replaceRecoverably(source: URL, destination: URL) throws {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).upgrade-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temp)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func backupIfPresent(_ url: URL, stamp: String) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).backup-\(stamp).\(url.pathExtension)")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }

    private static func writeOwnerOnly(_ string: String, to url: URL) throws {
        try string.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
