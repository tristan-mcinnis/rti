import Foundation

/// Reader for `speaker-suggestions.json`, the per-session output of the
/// vault-side voice-profile matcher (`speaker-profiles.py suggest`). RTI never
/// generates or applies these — the vault pipeline writes them, and the app
/// only surfaces them as prefill hints in the post-hoc speaker rename editor.
public struct SpeakerSuggestions: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let label: String
        public let leg: String?
        public let clips: Int?
        public let suggestion: String?
        public let score: Double?
        public let band: String?

        public var isAccept: Bool { band == "accept" && suggestion != nil }
        public var isMaybe: Bool { band == "maybe" && suggestion != nil }
    }

    public let speakers: [Entry]

    public static let filename = "speaker-suggestions.json"

    public static func load(fromSessionDir dir: URL) -> SpeakerSuggestions? {
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeakerSuggestions.self, from: data)
    }

    public func entry(for label: String) -> Entry? {
        speakers.first { $0.label == label }
    }
}
