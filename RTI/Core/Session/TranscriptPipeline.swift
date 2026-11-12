import Foundation

/// The live transcript is the ordered union of the two independent provider
/// streams and the user's notes. Text on one leg never suppresses or corrects
/// another leg. Committed runs retain every provider token in receipt order.
public final class TranscriptPipeline {
    private let mic = TranscriptAggregator(channel: "mic")
    private let system = TranscriptAggregator(channel: "system")
    public private(set) var liveEntries: [LiveEntry] = []
    public private(set) var readerActivity = TranscriptReaderActivity()
    private(set) var epoch = UUID()
    private(set) var revision = 0
    private var recent: [LiveEntry] = []
    private var notesSnapshot: [SessionNote] = []
    private static let recentLimit = 256

    func additions(since revision: Int) -> ArraySlice<LiveEntry>? {
        let count = self.revision - revision
        guard count >= 0, count <= recent.count else { return nil }
        return recent.suffix(count)
    }

    private func append(_ entry: LiveEntry) {
        readerActivity.record(entry)
        revision += 1
        recent.append(entry)
        if recent.count > Self.recentLimit * 2 { recent.removeFirst(Self.recentLimit) }
        if let last = liveEntries.last, last.startMs >= entry.startMs {
            var low = 0
            var high = liveEntries.count
            let rank = Self.rank(entry)
            while low < high {
                let mid = low + (high - low) / 2
                let previous = liveEntries[mid]
                if previous.startMs < entry.startMs || (previous.startMs == entry.startMs && Self.rank(previous) <= rank) {
                    low = mid + 1
                } else { high = mid }
            }
            liveEntries.insert(entry, at: low)
        } else { liveEntries.append(entry) }
    }

    private static func rank(_ entry: LiveEntry) -> Int {
        if entry.speakerId == "note" { return 0 }
        return entry.tokens.first?.leg == "mic" ? 1 : 2
    }

    public init() {}

    public var systemSpeakerLabelsEnabled: Bool {
        get { system.labelsEnabled }
        set { system.labelsEnabled = newValue }
    }

    public func streamID(for channel: String) -> UUID { channel == "system" ? system.streamID : mic.streamID }
    public func streamOffsetMs(for channel: String) -> Int { channel == "system" ? system.startMsOffset : mic.startMsOffset }

    public var interimLine: String? {
        let lines = [mic.interimText, system.interimText].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "  ")
    }

    public var interimSegments: [LiveTranscriptPresentation.InterimSegment] {
        (mic.interimSegments + system.interimSegments).sorted { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
    }

    @discardableResult
    public func process(words: [SonioxWord], channel: String) -> Bool {
        let stream: TranscriptAggregator
        switch channel {
        case "mic": stream = mic
        case "system": stream = system
        default: return false
        }
        let finals = stream.receive(words)
        for entry in finals { append(entry) }
        return !finals.isEmpty
    }

    /// Set once the system socket reported `.live`; that re-base then owns the
    /// live system timeline.
    private var systemStreamWentLive = false

    /// The system backend's start offset. It places the system stream only
    /// until the socket goes `.live`. A later backend start (the
    /// ScreenCaptureKit fallback) must not move a live stream's base: words
    /// already counted from the `.live` re-base would jump.
    public func setSystemStartOffset(ms: Int) {
        guard !systemStreamWentLive else { return }
        system.startMsOffset = ms
    }

    @discardableResult
    public func insertNote(_ text: String, startedAt: Date) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let offsetMs = Int(max(0, Date().timeIntervalSince(startedAt) * 1000))
        let entry = LiveEntry(
            speakerId: "note",
            text: trimmed,
            startMs: offsetMs,
            confidence: nil,
            translationStatus: "none",
            language: nil,
            sourceLanguage: nil
        )
        append(entry)
        return true
    }

    public func replaceNotes(_ notes: [SessionNote]) {
        var first = notesSnapshot.count
        if !notes.starts(with: notesSnapshot) {
            liveEntries.removeAll { $0.speakerId == "note" }
            recent.removeAll()
            epoch = UUID()
            readerActivity.replaceNotes(at: nil)
            first = 0
        }
        notesSnapshot = notes
        for note in notes.dropFirst(first) {
            let text = note.kind == .note ? note.text ?? "" : "/" + note.label
            append(LiveEntry(speakerId: "note", text: text, startMs: note.offsetMs, confidence: nil,
                             translationStatus: "none", language: nil, sourceLanguage: nil,
                             id: UUID(uuidString: note.id) ?? UUID()))
        }
    }

    public func reset() {
        mic.reset()
        system.reset()
        systemStreamWentLive = false
        liveEntries = []
        readerActivity = .init()
        recent = []
        notesSnapshot = []
        epoch = UUID()
        revision = 0
    }

    public func prepareForReconnect() {
        mic.prepareForReconnect()
        system.prepareForReconnect()
    }

    public func restartStream(channel: String, atMs: Int) {
        switch channel {
        case "mic": mic.restartStream(atMs: atMs)
        case "system":
            system.restartStream(atMs: atMs)
            systemStreamWentLive = true
        default: break
        }
    }
}
