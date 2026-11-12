import Darwin
import Foundation

/// An acknowledged user action on the audio timeline. A missing shownCodes
/// field leaves the previous exposure in place. An empty list explicitly clears it.
public struct SessionNote: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case note, marker, stimulus, correction }

    public struct Replacement: Codable, Equatable, Sendable {
        public var text: String
        public var shownCodes: [String]?
        public var shownItemIDs: [String]?
        public var offsetMs: Int?
        public var guideQuestionID: String?

        public init(text: String, shownCodes: [String]?, offsetMs: Int? = nil, guideQuestionID: String? = nil) {
            self.text = text
            self.shownCodes = shownCodes
            self.offsetMs = offsetMs
            self.guideQuestionID = guideQuestionID
        }
    }

    public var id: String
    public var kind: Kind
    public var offsetMs: Int
    public var text: String?
    public var leg: String
    public var guideQuestionID: String?
    public var shownCodes: [String]?
    public var shownItemIDs: [String]?
    public var revealed: Bool?
    public var packageRevision: String?
    public var sessionID: String?
    public var groupID: String?
    public var replaces: String?
    public var replacement: Replacement?

    public init(id: String = UUID().uuidString, kind: Kind, offsetMs: Int, text: String? = nil,
                leg: String = "local", guideQuestionID: String? = nil, shownCodes: [String]? = nil,
                revealed: Bool? = nil, packageRevision: String? = nil, sessionID: String? = nil,
                groupID: String? = nil, replaces: String? = nil, replacement: Replacement? = nil)
    {
        self.id = id
        self.kind = kind
        self.offsetMs = offsetMs
        self.text = text
        self.leg = leg
        self.guideQuestionID = guideQuestionID
        self.shownCodes = shownCodes
        self.revealed = revealed
        self.packageRevision = packageRevision
        self.sessionID = sessionID
        self.groupID = groupID
        self.replaces = replaces
        self.replacement = replacement
    }

    public var label: String {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("/") ? String(value.dropFirst()).trimmingCharacters(in: .whitespaces) : value
    }
}

public struct MarkerContext: Codable, Equatable, Sendable {
    public var startMs: Int?
    public var markerID: String?
    public var markerLabel: String?
    public var guideQuestionID: String?
    public var showEventID: String?
    public var shownItemIDs: [String]?
    public var shownCodes: [String]?
    public var packageRevision: String?
    public var revealRecorded = false

    public init() {}

    public var materialLabel: String {
        guard let shownCodes else { return "untracked" }
        return shownCodes.isEmpty ? "cleared" : shownCodes.joined(separator: " + ")
    }
}

public struct MarkerSpan: Codable, Equatable, Sendable {
    public let startMs: Int
    public let endMs: Int
    public let context: MarkerContext
}

public struct MarkerTimeline: Sendable {
    public let entries: [SessionNote]
    private let boundaries: [(Int, MarkerContext)]

    public init(events: [SessionNote]) {
        var originals: [SessionNote] = []
        var positions: [String: Int] = [:]
        var seen = Set<String>()
        for event in events where seen.insert(event.id).inserted {
            if event.kind == .correction {
                guard let target = event.replaces, let index = positions[target], let update = event.replacement else { continue }
                originals[index].text = update.text
                originals[index].shownCodes = update.shownCodes
                originals[index].shownItemIDs = update.shownItemIDs
                originals[index].guideQuestionID = update.guideQuestionID
                if let ms = update.offsetMs {
                    originals[index].offsetMs = ms
                }
                originals[index].revealed = event.revealed
                originals[index].packageRevision = event.packageRevision ?? originals[index].packageRevision
            } else {
                positions[event.id] = originals.count
                originals.append(event)
            }
        }
        entries = originals.enumerated().sorted {
            ($0.element.offsetMs, $0.offset) < ($1.element.offsetMs, $1.offset)
        }.map(\.element)
        var state = MarkerContext()
        var changes: [(Int, MarkerContext)] = []
        for event in entries where event.kind != .note {
            if event.kind == .marker {
                state.startMs = event.offsetMs
                state.markerID = event.id
                state.markerLabel = event.label
                state.guideQuestionID = event.guideQuestionID
            }
            if let codes = event.shownCodes {
                state.shownCodes = codes
                state.shownItemIDs = event.shownItemIDs
                state.showEventID = event.id
                state.packageRevision = event.packageRevision
                state.revealRecorded = state.revealRecorded || event.revealed == true
            }
            if changes.last?.0 == event.offsetMs {
                changes.removeLast()
            }
            changes.append((event.offsetMs, state))
        }
        boundaries = changes
    }

    public func context(at ms: Int) -> MarkerContext {
        var lo = 0, hi = boundaries.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if boundaries[mid].0 <= ms {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo == 0 ? MarkerContext() : boundaries[lo - 1].1
    }

    public func spans(through end: Int) -> [MarkerSpan] {
        boundaries.enumerated().map { index, pair in
            MarkerSpan(startMs: pair.0, endMs: index + 1 < boundaries.count ? boundaries[index + 1].0 : max(end, pair.0), context: pair.1)
        }
    }
}

/// A local locked append transaction. The caller receives success only after
/// fsync. Read and append share the lock, including repair of a torn last line.
public enum SessionMarkerJournal {
    public static let filename = "notes.jsonl"

    public static func read(in directory: URL) throws -> [SessionNote] {
        try access(in: directory, appending: nil)
    }

    @discardableResult
    public static func append(_ event: SessionNote, in directory: URL) throws -> [SessionNote] {
        try access(in: directory, appending: event)
    }

    private static func access(in directory: URL, appending event: SessionNote?) throws -> [SessionNote] {
        let url = directory.appendingPathComponent(filename)
        let fd = open(url.path, (event == nil ? O_RDONLY : O_RDWR | O_CREAT) | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            if event == nil, errno == ENOENT {
                return []
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              flock(fd, event == nil ? LOCK_SH : LOCK_EX) == 0 else { throw CocoaError(.fileReadUnknown) }
        defer { flock(fd, LOCK_UN) }
        let data = try file.readToEnd() ?? Data()
        let committed = data.lastIndex(of: 10).map { $0 + 1 } ?? 0
        let decoder = JSONDecoder()
        var events: [SessionNote] = []
        var saved: [String: SessionNote] = [:]
        for line in data.prefix(committed).split(separator: 10) {
            let record = try decoder.decode(SessionNote.self, from: line)
            if let previous = saved[record.id] {
                guard previous == record else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                saved[record.id] = record
                events.append(record)
            }
        }
        guard let event else { return events }
        if let existing = saved[event.id] {
            guard existing == event else { throw CocoaError(.fileWriteFileExists) }
            try file.synchronize()
            return events
        }
        guard !event.id.isEmpty, event.offsetMs >= 0,
              event.kind != .correction || (event.replaces.flatMap { saved[$0] }?.kind != .correction &&
                  event.replaces.flatMap { saved[$0] } != nil && event.replacement != nil)
        else { throw CocoaError(.fileWriteInvalidFileName) }
        if committed < data.count {
            try file.truncate(atOffset: UInt64(committed))
        }
        try file.seekToEnd()
        var bytes = try JSONEncoder().encode(event)
        bytes.append(10)
        try file.write(contentsOf: bytes)
        try file.synchronize()
        events.append(event)
        return events
    }
}
