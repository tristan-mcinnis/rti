import Foundation

/// Original-language live evidence remains immutable when a provider supplies
/// a newer playback locator. Both projections refer to the same turn IDs.
public struct SessionAnnotatedTurn: Codable, Equatable, Sendable {
    public var turnID: String
    public var rawSpeaker: String
    public var leg: String
    public var speakerConfidence: String
    public var original: String
    public var liveStartMs: Int
    public var endMs: Int
    public var context: MarkerContext
    public var discussedCodes: [String]?
    public var upgradedStartMs: Int?
    public var anchor: String?

    public init(turnID: String, rawSpeaker: String, leg: String, speakerConfidence: String,
                original: String, liveStartMs: Int, endMs: Int, context: MarkerContext)
    {
        self.turnID = turnID
        self.rawSpeaker = rawSpeaker
        self.leg = leg
        self.speakerConfidence = speakerConfidence
        self.original = original
        self.liveStartMs = liveStartMs
        self.endMs = endMs
        self.context = context
    }
}

public struct NoteAnchor: Codable, Equatable, Sendable {
    public let id: String
    public let offsetMs: Int
    public let playbackMs: Int?
    public let approximate: Bool
}

public struct SessionEvidence: Codable, Sendable {
    public static let filename = "transcript-evidence.json"
    public var schemaVersion = 1
    public var sessionID: String?
    public var groupID: String?
    public var notes: [SessionNote]
    public var spans: [MarkerSpan]
    public var turns: [SessionAnnotatedTurn]
    public var noteAnchors: [NoteAnchor] = []

    public init(sessionID: String?, groupID: String?, events: [SessionNote], through ms: Int, turns: [SessionAnnotatedTurn]) {
        let timeline = MarkerTimeline(events: events)
        self.sessionID = sessionID
        self.groupID = groupID
        notes = timeline.entries
        spans = timeline.spans(through: ms)
        self.turns = turns
    }

    public static func raw(from markdown: String) -> String {
        var raw: [String] = []
        var insideNote = false
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("`"), let annotation = line.range(of: "` **📝 Note:** ") {
                raw.append("# " + line[annotation.upperBound...])
                insideNote = true
            } else if line.hasPrefix("### ") {
                raw.append("# " + String(line.dropFirst(4)))
                insideNote = true
            } else if line.hasPrefix("> Section: ") {
                raw.append("# " + String(line.dropFirst(2)))
                insideNote = false
            } else if insideNote, line.hasPrefix("> ") {
                raw.append("# " + String(line.dropFirst(2)))
            } else if line.hasPrefix("`") {
                let speech = CanonicalMeetingTranscript.render(markdownTranscript: line)
                if !speech.isEmpty {
                    raw.append(speech)
                }
                insideNote = false
            }
        }
        return raw.joined(separator: "\n")
    }

    /// Preserve unrelated versioned and legacy metadata keys during an upgrade.
    public func updateSessionMetadata(in directory: URL) throws {
        let url = directory.appendingPathComponent("session.json")
        var metadata: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let old = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            metadata = old
        }
        let encoder = JSONEncoder()
        metadata["schemaVersion"] = schemaVersion
        metadata["evidenceFile"] = Self.filename
        metadata["noteIDs"] = notes.map(\.id)
        metadata["markerSpans"] = try JSONSerialization.jsonObject(with: encoder.encode(spans))
        metadata["turns"] = try JSONSerialization.jsonObject(with: encoder.encode(turns))
        metadata["noteAnchors"] = try JSONSerialization.jsonObject(with: encoder.encode(noteAnchors))
        if let sessionID {
            metadata["sessionId"] = sessionID
        }
        if let groupID {
            metadata["group_id"] = groupID
        }
        try JSONSerialization.data(withJSONObject: metadata).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(in directory: URL) throws -> Self? {
        let file = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    public func write(in directory: URL) throws {
        let file = directory.appendingPathComponent(Self.filename)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func isRemote(_ label: String) -> Bool {
        label == "Them" || label.hasPrefix("Remote speaker")
    }

    public mutating func reanchor(events: [SessionNote], timed: [TranscriptUpgradeSegment], all: [TranscriptUpgradeSegment]) {
        let timeline = MarkerTimeline(events: events)
        notes = timeline.entries
        let end = [spans.last?.endMs, all.map(\.startMs).max(), notes.last?.offsetMs].compactMap(\.self).max() ?? 0
        spans = timeline.spans(through: end)
        let remote = timed.filter { Self.isRemote($0.speaker) }
        let mic = timed.filter { !Self.isRemote($0.speaker) }
        for index in turns.indices {
            let turn = turns[index]
            let match = TranscriptUpgradeMerge.guideAnchor(original: turn.original, liveStartMs: turn.liveStartMs,
                                                           in: turn.leg == "Them" ? remote : mic)
            var context = timeline.context(at: turn.liveStartMs)
            context.guideQuestionID = context.guideQuestionID ?? turn.context.guideQuestionID
            turns[index].context = context
            turns[index].upgradedStartMs = match?.startMs
            if let match {
                let playback = timeline.context(at: match.startMs)
                turns[index].anchor = playback.markerID == context.markerID && playback.showEventID == context.showEventID
                    ? "matched" : "review boundary"
            } else {
                turns[index].anchor = "approximate"
            }
        }
        let times = Array(Set(timed.map(\.startMs))).sorted()
        noteAnchors = notes.map { note in
            let ordered = times.sorted { abs($0 - note.offsetMs) < abs($1 - note.offsetMs) }
            let closest = ordered.first
            let gap = closest.map { abs($0 - note.offsetMs) } ?? Int.max
            let tied = ordered.count > 1 && abs(ordered[1] - note.offsetMs) == gap
            return NoteAnchor(id: note.id, offsetMs: note.offsetMs, playbackMs: closest, approximate: gap > 5000 || tied)
        }
    }

    /// Preserve the legacy speech line verbatim. Context and authored notes
    /// are separate lines, safe for an existing quote verifier to skip.
    public func transcript(segments: [TranscriptUpgradeSegment], raw: Bool) -> String {
        let timeline = MarkerTimeline(events: notes)
        let anchored = Dictionary(grouping: turns.filter { $0.upgradedStartMs != nil }, by: { $0.upgradedStartMs! })
        let originals = Dictionary(grouping: turns, by: \.liveStartMs)
        let anchorByID = Dictionary(uniqueKeysWithValues: noteAnchors.map { ($0.id, $0) })
        var lines: [String] = []
        var next = 0
        func putNote(_ event: SessionNote) {
            let heading = event.kind == .note ? "Note" : event.kind == .stimulus ? "Material" : "Section"
            let text = event.label.components(separatedBy: .newlines)
            let suffix = anchorByID[event.id]?.approximate == true ? " · approximate" : ""
            let time = GuideExtraction.locator(event.offsetMs)
            lines.append(raw ? "# \(heading) · \(time)\(suffix)" : "`\(time)` **📝 Note:** \(heading)\(suffix)")
            if !raw, event.kind != .note {
                lines.append("### " + (text.first ?? heading))
                lines += text.dropFirst().map { "> " + $0 }
            } else {
                lines += text.map { "> " + $0 }
            }
        }
        for segment in segments.sorted(by: { $0.startMs < $1.startMs }) {
            while next < notes.count, notes[next].offsetMs <= segment.startMs {
                putNote(notes[next]); next += 1
            }
            let isRemote = Self.isRemote(segment.speaker)
            let candidates = (anchored[segment.startMs] ?? originals[segment.startMs] ?? []).filter {
                ($0.leg == "Them") == isRemote && segment.text.contains($0.original)
            }
            let context = candidates.first?.context ?? timeline.context(at: segment.startMs)
            let label = context.markerLabel?.components(separatedBy: .newlines).joined(separator: " ") ?? "unmarked"
            let ids = candidates.map(\.turnID).joined(separator: ", ")
            let mixed = candidates.contains { $0.context != context }
            let qualifier = mixed ? " · mixed live contexts, see evidence" : candidates.contains { $0.anchor == "review boundary" } ? " · review boundary" : ""
            let annotationPrefix = raw ? "#" : "`" + GuideExtraction.locator(segment.startMs) + "` **📝 Note:**"
            lines.append("\(annotationPrefix) Section: \(label) · shown: \(context.materialLabel)\(context.guideQuestionID.map { " · " + $0 } ?? "")\(ids.isEmpty ? "" : " · " + ids)\(qualifier)")
            let time = GuideExtraction.locator(segment.startMs)
            lines.append(raw ? "[\(time)] \(segment.speaker): \(segment.text)"
                : "`\(time)\(String(format: ".%03d", max(0, segment.startMs) % 1000))` **\(segment.speaker):** \(segment.text)")
            if !raw {
                lines.append("")
            }
        }
        while next < notes.count {
            putNote(notes[next]); next += 1
        }
        return lines.joined(separator: "\n")
    }
}
