import Foundation

public struct GuideSpeakerAssignment: Codable, Equatable, Sendable {
    public let seat: GuideSeat?
    public let isModerator: Bool

    public init(seat: GuideSeat? = nil, isModerator: Bool = false) {
        self.seat = seat
        self.isModerator = isModerator
    }

    public var isEmpty: Bool {
        seat == nil && !isModerator
    }
}

/// Maps raw live speaker ids in memory. On disk, names and guide assignments
/// share the display-label keys used by the original speaker-names.json.
public struct SpeakerNameArchive: Codable, Equatable, Sendable {
    public let names: [String: String]
    public let assignments: [String: GuideSpeakerAssignment]

    public init(names: [String: String] = [:], assignments: [String: GuideSpeakerAssignment] = [:]) {
        var normalized: [String: String] = [:]
        for (key, value) in names {
            let raw = SpeakerLabelMapping.rawKey(forDisplayLabel: key) ?? key
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw != "self", !name.isEmpty {
                normalized[raw] = name
            }
        }
        self.names = normalized
        var roles: [String: GuideSpeakerAssignment] = [:]
        for (key, assignment) in assignments where !assignment.isEmpty {
            roles[SpeakerLabelMapping.rawKey(forDisplayLabel: key) ?? key] = assignment
        }
        self.assignments = roles
    }

    public var isEmpty: Bool {
        names.isEmpty && assignments.isEmpty
    }

    public var displayNames: [String: String] {
        var result = SpeakerLabelMapping.displayKeyedNames(names)
        for (raw, assignment) in assignments {
            guard let seat = assignment.seat, raw != "self" else { continue }
            result[SpeakerLabelMapping.displayLabel(forRawKey: raw) ?? raw] = seat.label
        }
        return result
    }

    public var guideSpeakers: [String: GuideSpeaker] {
        var speakers: [String: GuideSpeaker] = [:]
        for raw in Set(names.keys).union(assignments.keys) {
            let assignment = assignments[raw]
            let participant = assignment?.seat?.label ?? names[raw] ?? SpeakerLabelMapping.displayLabel(forRawKey: raw) ?? raw
            speakers[raw] = GuideSpeaker(
                participant: participant, isModerator: assignment?.isModerator ?? false, seatCode: assignment?.seat?.code
            )
        }
        return speakers
    }

    public init(from decoder: Decoder) throws {
        let entries = try decoder.singleValueContainer().decode([String: Entry].self)
        var names: [String: String] = [:]
        var assignments: [String: GuideSpeakerAssignment] = [:]
        for (key, value) in entries {
            names[key] = value.name
            assignments[key] = value.assignment
        }
        self.init(names: names, assignments: assignments)
    }

    public func encode(to encoder: Encoder) throws {
        var entries: [String: Entry] = [:]
        for raw in Set(names.keys).union(assignments.keys) {
            let key = SpeakerLabelMapping.displayLabel(forRawKey: raw) ?? raw
            entries[key] = Entry(name: names[raw], assignment: assignments[raw])
        }
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    private struct Entry: Codable {
        let name: String?
        let assignment: GuideSpeakerAssignment?

        init(name: String?, assignment: GuideSpeakerAssignment?) {
            self.name = name
            self.assignment = assignment
        }

        private enum CodingKeys: String, CodingKey { case name, seat, isModerator }

        init(from decoder: Decoder) throws {
            if let string = try? decoder.singleValueContainer().decode(String.self) {
                self.init(name: string, assignment: nil)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                name: container.decodeIfPresent(String.self, forKey: .name),
                assignment: GuideSpeakerAssignment(
                    seat: container.decodeIfPresent(GuideSeat.self, forKey: .seat),
                    isModerator: container.decodeIfPresent(Bool.self, forKey: .isModerator) ?? false
                )
            )
        }

        func encode(to encoder: Encoder) throws {
            guard let assignment else {
                var container = encoder.singleValueContainer()
                try container.encode(name)
                return
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(assignment.seat, forKey: .seat)
            try container.encode(assignment.isModerator, forKey: .isModerator)
        }
    }
}
