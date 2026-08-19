import Foundation
import Observation

/// Session-scoped speaker rename map: raw speaker id (`self`, `room_1`,
/// `remote_1`, ...) -> a user-given display name. Reset at the start of
/// every new session (names don't carry across meetings). `SpeakerLabels
/// .displayName` consults this first so a rename in the live transcript
/// takes effect everywhere immediately; `SessionArchive` reads `names` at
/// stop time to write both `speaker-names.json` and a named `transcript.md`.
@Observable @MainActor
final class SpeakerNameStore {
    static let shared = SpeakerNameStore()

    private(set) var names: [String: String] = [:]

    private init() {}

    func name(for rawLabel: String) -> String? {
        names[rawLabel]
    }

    func rename(_ rawLabel: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: rawLabel)
        } else {
            names[rawLabel] = trimmed
        }
    }

    /// Clear at the start of a new session.
    func reset() {
        names = [:]
    }
}
