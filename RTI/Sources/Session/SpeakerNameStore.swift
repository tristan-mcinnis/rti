import Foundation
import Observation
import RTICore

/// One session-scoped mapping for names, guide roster seats and moderator roles.
@Observable @MainActor
final class SpeakerNameStore {
    static let shared = SpeakerNameStore()

    private(set) var enteredNames: [String: String] = [:]
    private(set) var guideAssignments: [String: GuideSpeakerAssignment] = [:]

    private init() {}

    var names: [String: String] {
        var result = enteredNames
        for (raw, assignment) in guideAssignments {
            if let seat = assignment.seat { result[raw] = seat.label }
        }
        return result
    }

    var guideSpeakers: [String: GuideSpeaker] {
        SpeakerNameArchive(names: enteredNames, assignments: guideAssignments).guideSpeakers
    }

    func name(for rawLabel: String) -> String? {
        enteredNames[rawLabel]
    }

    func rename(_ rawLabel: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        enteredNames[rawLabel] = trimmed.isEmpty ? nil : trimmed
        if GuideSessionController.shared.isActive { GuideSessionController.shared.remapSpeakers() }
    }

    func assign(_ assignment: GuideSpeakerAssignment, to rawLabel: String) {
        guideAssignments[rawLabel] = assignment.isEmpty ? nil : assignment
        GuideSessionController.shared.remapSpeakers()
    }

    func reset() {
        enteredNames = [:]
        guideAssignments = [:]
    }
}
