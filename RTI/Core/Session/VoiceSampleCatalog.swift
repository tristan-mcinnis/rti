import Foundation

/// Decodes `speaker-profiles.py samples --json` — the enrolled voice-sample
/// inventory behind Settings › Voices. RTI only reviews this catalog; every
/// mutation goes back through the vault CLI, which stays the single writer.
public struct VoiceSampleCatalog: Codable, Sendable {
    public struct Sample: Codable, Sendable, Identifiable, Hashable {
        public let id: Int
        public let name: String
        public let source: String?
        public let created: String?
        /// Absolute path of the audio file the clip came from, when resolvable.
        public let audio: String?
        /// File offset (seconds) of the enrolled window; nil for legacy samples
        /// stored before windows were recorded.
        public let offset: Double?
        public let duration: Double?
        public let playable: Bool?
        /// Session folder name (e.g. "2026-08-28 070051") when derivable.
        public let session: String?
        public let label: String?

        public var canAudition: Bool { (playable ?? false) && audio != nil }
    }

    public let samples: [Sample]

    /// Samples grouped by person, people sorted by name, samples by id.
    public var byPerson: [(name: String, samples: [Sample])] {
        Dictionary(grouping: samples, by: \.name)
            .map { (name: $0.key, samples: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.name < $1.name }
    }
}
