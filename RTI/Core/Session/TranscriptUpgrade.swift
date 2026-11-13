import Foundation

public struct TranscriptUpgradeSegment: Equatable, Sendable {
    public let speaker: String
    public let startMs: Int
    public let text: String
    public let source: SonioxAsyncTurnSource?

    public init(speaker: String, startMs: Int, text: String, source: SonioxAsyncTurnSource? = nil) {
        self.speaker = speaker
        self.startMs = startMs
        self.text = text
        self.source = source
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
    public let segmentCount: Int
    public let sourceFiles: [String]
    public let artifactResult: TranscriptUpgradeArtifacts.WriteResult
    /// Time-coded provider turns from the system leg. Live fallbacks never verify a quote.
    public let guideAnchorTurns: [TranscriptUpgradeSegment]

    public init(
        transcriptURL: URL,
        segmentCount: Int,
        sourceFiles: [String],
        artifactResult: TranscriptUpgradeArtifacts.WriteResult,
        guideAnchorTurns: [TranscriptUpgradeSegment] = []
    ) {
        self.transcriptURL = transcriptURL
        self.segmentCount = segmentCount
        self.sourceFiles = sourceFiles
        self.artifactResult = artifactResult
        self.guideAnchorTurns = guideAnchorTurns
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
        // An unreadable/corrupt retained leg must reach the decoder, which can
        // explain the failure. Treating it as absent silently drops a speaker.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(), length > 0 else { return false }
        do {
            try handle.seek(toOffset: 0)
            guard let header = try handle.read(upToCount: 44), header.count >= 12,
                  String(data: header[0..<4], encoding: .ascii) == "RIFF" else { return true }
            func size(_ bytes: Data.SubSequence) -> UInt64 {
                bytes.enumerated().reduce(UInt64(0)) { result, byte in
                    result | (UInt64(byte.element) << UInt64(byte.offset * 8))
                }
            }
            // RTI's compact recorder uses this layout. Keep support for its
            // durable, header-only file while the first buffer is pending.
            if header.count == 44, String(data: header[36..<40], encoding: .ascii) == "data" {
                return size(header[40..<44]) > 0
            }
            guard String(data: header[8..<12], encoding: .ascii) == "WAVE" else { return true }
            // Native encoders may insert JUNK, FLLR, fact, or an extended fmt
            // chunk before data. RIFF chunks are word-aligned, not fixed-size.
            var offset: UInt64 = 12
            while offset + 8 <= length {
                try handle.seek(toOffset: offset)
                guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { return true }
                let count = size(chunk[4..<8])
                if String(data: chunk[0..<4], encoding: .ascii) == "data" { return count > 0 }
                offset += 8 + count + (count % 2)
            }
            return true
        } catch {
            return true
        }
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
    public enum LegResult: Sendable {
        case soniox(data: Data, policy: SessionSpeakerPolicy)
        case legacyText(String)
    }

    public typealias TranscribeLeg = @Sendable (TranscriptUpgradeAudioInput, URL) async throws -> LegResult
    public typealias Transcribe = @Sendable (_ audioURL: URL, _ outputBaseURL: URL) async throws -> String
    public typealias Progress = @Sendable (_ message: String) -> Void

    public static func upgrade(
        sessionDir: URL,
        startedAt: Date?,
        providerID: String,
        providerDisplayName: String,
        frontmatter: [String],
        progress: Progress,
        transcribe: Transcribe
    ) async throws -> TranscriptUpgradeExecutionResult {
        try await upgradeLegs(sessionDir: sessionDir, startedAt: startedAt, providerID: providerID,
                              providerDisplayName: providerDisplayName, frontmatter: frontmatter, readsLegacyTranscript: true, progress: progress) { input, base in
            .legacyText(try await transcribe(input.url, base))
        }
    }

    public static func upgradeLegs(
        sessionDir: URL, startedAt: Date?, providerID: String, providerDisplayName: String,
        frontmatter: [String], readsLegacyTranscript: Bool = false, progress: Progress, transcribe: TranscribeLeg
    ) async throws -> TranscriptUpgradeExecutionResult {
        let originalTranscriptURL = sessionDir.appendingPathComponent("transcript.md")
        let originalTranscript: String
        if readsLegacyTranscript {
            guard let old = try? String(contentsOf: originalTranscriptURL, encoding: .utf8) else {
                throw TranscriptUpgradePipelineError.unreadableTranscript
            }
            originalTranscript = old
        } else {
            originalTranscript = ""
        }
        let notes = readsLegacyTranscript ? TranscriptUpgradeMerge.notes(from: originalTranscript) : []

        let inputs = TranscriptUpgradeAudioDiscovery.inputs(in: sessionDir)
        guard !inputs.isEmpty else { throw TranscriptUpgradePipelineError.missingAudio }

        var segments: [TranscriptUpgradeSegment] = []
        var guideAnchorTurns: [TranscriptUpgradeSegment] = []
        var timedTurns: [TranscriptUpgradeSegment] = []
        var sourceFiles: [String] = []
        var emptyLegs: [TranscriptUpgradeAudioInput] = []
        var nativeLegs: Set<URL> = []
        for input in inputs {
            sourceFiles.append(input.url.lastPathComponent)
            progress("Transcribing \(input.url.lastPathComponent)")
            let outputBase = sessionDir.appendingPathComponent("transcript-upgrade-\(providerID)-\(input.url.deletingPathExtension().lastPathComponent)")
            let parsed: [TranscriptUpgradeSegment]
            let timed: [TranscriptUpgradeSegment]
            switch try await transcribe(input, outputBase) {
            case let .soniox(data, policy):
                nativeLegs.insert(input.url)
                parsed = try SonioxAsyncTurns.segments(data: data, system: input.defaultSpeaker == "Remote speaker",
                                                       policy: policy, offsetMs: input.offsetMs)
                // Display an untimed fragment approximately; only actual
                // provider times can verify a playback/evidence locator.
                timed = parsed.filter { $0.source?.providerStartMs != nil }
            case let .legacyText(text):
                timed = TranscriptUpgradeMerge.timedSegments(from: text, defaultSpeaker: input.defaultSpeaker, offsetMs: input.offsetMs)
                parsed = timed.isEmpty ? TranscriptUpgradeMerge.untimedSegments(from: text, defaultSpeaker: input.defaultSpeaker, offsetMs: input.offsetMs) : timed
            }
            timedTurns.append(contentsOf: timed)
            if input.defaultSpeaker == "Remote speaker" { guideAnchorTurns.append(contentsOf: timed) }
            segments.append(contentsOf: parsed)
            if parsed.isEmpty, inputs.count > 1 || nativeLegs.contains(input.url) {
                emptyLegs.append(input)
            }
        }
        let journal = try SessionMarkerJournal.read(in: sessionDir)
        var evidence = try SessionEvidence.read(in: sessionDir)
        // The live system-leg turns, read before anything is replaced, so
        // typed names can follow their voices to the new numbering.
        let liveTurnsForNames = liveSystemTurns(in: sessionDir, evidence: evidence)
        guard !segments.isEmpty || !journal.isEmpty || (evidence?.notes.isEmpty == false) else {
            throw TranscriptUpgradePipelineError.emptyTranscript(providerDisplayName)
        }
        // One leg transcribed to nothing while another has speech. If the live
        // transcript heard that leg, keep its lines (ordered by time) rather
        // than overwrite them with a one-sided upgrade. If the live transcript
        // heard nothing there either (a silent leg), the one-sided result is
        // correct; say so.
        for leg in emptyLegs {
            let live: [TranscriptUpgradeSegment]
            if nativeLegs.contains(leg.url) {
                let system = leg.defaultSpeaker == "Remote speaker"
                let checkpointed = (evidence?.turns ?? []).filter { ($0.leg == "Them") == system }
                // The evidence is as old as the last checkpoint. After a
                // crash the token journal holds that leg's later lines.
                let journaled = SonioxLiveJournalReplay.segments(in: sessionDir, leg: system ? "system" : "mic",
                                                                 fromMs: checkpointed.map(\.endMs).max() ?? 0)
                live = checkpointed.map {
                    TranscriptUpgradeSegment(speaker: $0.leg, startMs: $0.liveStartMs, text: $0.original)
                } + journaled
            } else {
                live = TranscriptUpgradeMerge.liveSegments(from: originalTranscript, remote: leg.defaultSpeaker == "Remote speaker")
            }
            if live.isEmpty {
                progress("Warning: \(leg.url.lastPathComponent) produced no speech; the transcript may be one-sided")
            } else {
                progress("Warning: \(leg.url.lastPathComponent) produced no speech; kept \(live.count) live line\(live.count == 1 ? "" : "s") from that side")
                segments.append(contentsOf: live)
            }
        }
        guard let startedAt else {
            throw TranscriptUpgradePipelineError.missingSessionDate
        }

        progress("Preserving \(notes.count) note\(notes.count == 1 ? "" : "s")")
        if evidence == nil, !journal.isEmpty || !nativeLegs.isEmpty {
            let data = try? Data(contentsOf: sessionDir.appendingPathComponent("session.json"))
            let metadata = data.flatMap { try? JSONDecoder().decode(SessionArchiveMetadata.self, from: $0) }
            evidence = SessionEvidence(sessionID: journal.first?.sessionID ?? metadata?.sessionId, groupID: journal.first?.groupID ?? metadata?.groupID,
                                       events: journal, through: segments.map(\.startMs).max() ?? 0, turns: [])
        }
        let body: String
        if var evidence {
            // A restored archive can retain its last successful projection even
            // when the journal copy is missing. Preserve recovered IDs and
            // let any surviving original/correction records take precedence.
            let present = Set(journal.map(\.id))
            let recovered = evidence.notes.filter { !present.contains($0.id) }
            evidence.reanchor(events: recovered + journal, timed: timedTurns, all: segments)
            body = "# Transcript\n\n_Upgraded with " + providerDisplayName + "._\n\n" + evidence.transcript(segments: segments, raw: false)
            try evidence.write(in: sessionDir)
            try evidence.updateSessionMetadata(in: sessionDir)
        } else {
            body = TranscriptUpgradeMerge.renderBody(
                startedAt: startedAt, endedAt: nil, segments: segments, notes: notes,
                provider: providerDisplayName, sourceFiles: sourceFiles
            )
        }
        var sections = frontmatter
        if let data = try? Data(contentsOf: sessionDir.appendingPathComponent("session.json")),
           let policy = (try? JSONDecoder().decode(SessionArchiveMetadata.self, from: data))?.speakerPolicy,
           policy.labelsEnabled, let expected = policy.expectedCount {
            let clusters = Set(guideAnchorTurns.map(\.speaker).filter { $0.hasPrefix("Remote speaker ") })
            if clusters.count > expected {
                sections.append("\n## Speaker review\n\nExpected \(expected). The system leg produced \(clusters.count) clusters. Their identities are unverified. Review the speaker assignments before combining them.")
            }
        }
        // Put annotations before the speech records. The workbook accepts
        // multiline original words right up to the next timestamped record.
        sections.append(body)
        let md = (sections + [""]).joined(separator: "\n")

        progress("Writing upgraded transcript")
        let artifactResult = try TranscriptUpgradeArtifacts.installUpgradedTranscript(markdown: md, in: sessionDir)
        if let liveTurnsForNames, try SpeakerNameRemap.apply(in: sessionDir, live: liveTurnsForNames, upgraded: segments) {
            progress("Moved typed speaker names to the upgraded speaker numbers")
        }

        return TranscriptUpgradeExecutionResult(
            transcriptURL: originalTranscriptURL,
            segmentCount: segments.count,
            sourceFiles: sourceFiles,
            artifactResult: artifactResult,
            guideAnchorTurns: guideAnchorTurns
        )
    }
}

extension TranscriptUpgradePipeline {
    /// The live transcript's system-leg turns for `SpeakerNameRemap`, or nil
    /// when names must not move: a guided session keeps its seat
    /// assignments on the live speaker IDs, and a re-upgrade with no live
    /// record left has nothing to match.
    static func liveSystemTurns(in sessionDir: URL, evidence: SessionEvidence?) -> [TranscriptUpgradeSegment]? {
        if let data = try? Data(contentsOf: sessionDir.appendingPathComponent("session.json")),
           let metadata = try? JSONDecoder().decode(SessionArchiveMetadata.self, from: data), metadata.guidePath != nil {
            return nil
        }
        if let turns = evidence?.turns, !turns.isEmpty {
            return turns.filter { $0.leg == "Them" }.map {
                TranscriptUpgradeSegment(speaker: SpeakerLabelMapping.displayLabel(forRawKey: $0.rawSpeaker) ?? $0.rawSpeaker,
                                         startMs: $0.liveStartMs, text: $0.original)
            }
        }
        let proof = sessionDir.appendingPathComponent("transcript.live.md")
        let upgraded = sessionDir.appendingPathComponent("transcript.upgraded.md")
        let source = FileManager.default.fileExists(atPath: proof.path) ? proof
            : FileManager.default.fileExists(atPath: upgraded.path) ? nil : sessionDir.appendingPathComponent("transcript.md")
        guard let source, let text = try? String(contentsOf: source, encoding: .utf8) else { return nil }
        return TranscriptUpgradeMerge.liveSegments(from: text, remote: true)
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

    /// Spoken lines of a live (or earlier upgraded) transcript for one audio
    /// leg. System-leg lines are labelled `Remote speaker N`; every other
    /// non-note label is the mic leg (`You`, `Room speaker N`, a renamed self).
    public static func liveSegments(from markdown: String, remote: Bool) -> [TranscriptUpgradeSegment] {
        var found: [TranscriptUpgradeSegment] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("`"),
                  let close = line[line.index(after: line.startIndex)...].firstIndex(of: "`"),
                  let ms = milliseconds(from: String(line[line.index(after: line.startIndex)..<close])) else { continue }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("**"), let end = rest.range(of: ":**") else { continue }
            let speaker = rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let text = rest[end.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !speaker.isEmpty, !text.isEmpty, !speaker.contains("Note") else { continue }
            guard (speaker.hasPrefix("Remote speaker") || speaker == "Them") == remote else { continue }
            found.append(TranscriptUpgradeSegment(speaker: speaker, startMs: ms, text: text))
        }
        return found
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
        let timed = timedSegments(from: text, defaultSpeaker: defaultSpeaker, offsetMs: offsetMs)
        return timed.isEmpty ? untimedSegments(from: text, defaultSpeaker: defaultSpeaker, offsetMs: offsetMs) : timed
    }

    fileprivate static func timedSegments(from text: String, defaultSpeaker: String, offsetMs: Int) -> [TranscriptUpgradeSegment] {
        var segments: [TranscriptUpgradeSegment] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let parsed = timestampedSegment(fromLine: line, defaultSpeaker: defaultSpeaker, offsetMs: offsetMs) {
                let speaker: String
                if defaultSpeaker == "Remote speaker", parsed.speaker.hasPrefix("Speaker ") {
                    speaker = "Remote speaker " + parsed.speaker.dropFirst("Speaker ".count)
                } else {
                    speaker = parsed.speaker
                }
                segments.append(TranscriptUpgradeSegment(speaker: speaker, startMs: parsed.startMs, text: parsed.text))
            }
        }
        return segments
    }

    fileprivate static func untimedSegments(from text: String, defaultSpeaker: String, offsetMs: Int) -> [TranscriptUpgradeSegment] {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? [] : [TranscriptUpgradeSegment(speaker: defaultSpeaker, startMs: offsetMs, text: body)]
    }

    /// Labels can change across diarization runs. Exact wording and a single
    /// nearby time-coded turn on the respondent leg establish the new locator.
    public static func guideAnchor(original: String, liveStartMs: Int, in remoteTurns: [TranscriptUpgradeSegment]) -> TranscriptUpgradeSegment? {
        guard !original.isEmpty else { return nil }
        var found: TranscriptUpgradeSegment?
        for turn in remoteTurns where abs(Double(turn.startMs) - Double(liveStartMs)) <= 30_000 {
            var remainder = turn.text[...]
            while let span = remainder.range(of: original, options: .literal) {
                remainder = turn.text[span.upperBound...]
                if joinsLatinWord(original.first, turn.text[..<span.lowerBound].last) ||
                    joinsLatinWord(original.last, remainder.first) { continue }
                guard found == nil else { return nil }
                found = turn
            }
        }
        return found
    }

    private static func joinsLatinWord(_ lhs: Character?, _ rhs: Character?) -> Bool {
        guard let a = lhs?.asciiValue, let b = rhs?.asciiValue else { return false }
        func isWord(_ c: UInt8) -> Bool { (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) }
        return isWord(a) && isWord(b)
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
        let rest = String(line[line.index(after: secondTick)...]).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("**📝 Note:**") || rest.hasPrefix("**Note:**"),
              let markerRange = line.range(of: "Note:**") else { return nil }
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
        let components = secondsPart.split(separator: ".", maxSplits: 1)
        let wholeSeconds = String(components.first ?? "")
        let fraction = components.count == 2 ? String(components[1].prefix(3)) : ""
        let ms = Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        guard let seconds = Int(wholeSeconds),
              let minutes = Int(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? (Int(parts[0]) ?? 0) : 0
        return ((hours * 3600) + (minutes * 60) + seconds) * 1000 + ms
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

    /// The same leg-aware labels as the archived `transcript.md` (`You`,
    /// `Room speaker N`, `Remote speaker N`), so `speaker-names.json` keys match this export too.
    private static func speakerLabeler(for _: [LiveEntry]) -> (String) -> String {
        { id in SpeakerLabelMapping.displayLabel(forRawKey: id) ?? id }
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
        let components = secondsPart.split(separator: ".", maxSplits: 1)
        let wholeSeconds = String(components.first ?? "")
        let fraction = components.count == 2 ? String(components[1].prefix(3)) : ""
        let ms = Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        guard let seconds = Int(wholeSeconds),
              let minutes = Int(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? (Int(parts[0]) ?? 0) : 0
        return ((hours * 3600) + (minutes * 60) + seconds) * 1000 + ms
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

        public init(upgradedURL: URL, transcriptBackupURL: URL?) {
            self.upgradedURL = upgradedURL
            self.transcriptBackupURL = transcriptBackupURL
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
        // The live transcript showed where a leg recorded nothing (AUD-4);
        // the upgraded one replaces it and must keep saying so.
        let gaps = (try? JSONDecoder().decode(
            SessionArchiveMetadata.self,
            from: Data(contentsOf: sessionDir.appendingPathComponent("session.json"))
        ))?.captureGaps ?? []
        let markdown = CaptureGapLog.annotate(markdown, gaps: gaps)

        try writeOwnerOnly(markdown, to: upgradedURL)
        let transcriptBackup = try backupIfPresent(transcriptURL, stamp: backupStamp)
        try replaceRecoverably(source: upgradedURL, destination: transcriptURL)

        return WriteResult(
            upgradedURL: upgradedURL,
            transcriptBackupURL: transcriptBackup
        )
    }

    private static func replaceRecoverably(source: URL, destination: URL) throws {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).upgrade-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temp)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
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

/// Runs an operation, and once more after `delay` when `shouldRetry` allows it.
@MainActor
public enum RetryOnce {
    public static func run<T>(
        delay: Duration,
        shouldRetry: (any Error) -> Bool,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch where shouldRetry(error) {
            try await Task.sleep(for: delay)
            return try await operation()
        }
    }
}
