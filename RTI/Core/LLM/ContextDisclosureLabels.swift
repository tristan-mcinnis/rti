import Foundation

/// Everything the composer's "Next answer uses" line may name, gathered from
/// the same state the send reads.
public struct ContextDisclosureInput: Equatable, Sendable {
    /// A live transcript with real text in it.
    public var hasLiveTranscript: Bool
    public var workstreamName: String?
    public var hasMeetingNote: Bool
    public var hasBrief: Bool
    public var glossaryEntryCount: Int
    /// A screenshot captured and waiting to be sent.
    public var hasPendingScreenCapture: Bool
    /// The ambient OCR trail a running recording adds to every turn.
    public var hasAmbientScreenRead: Bool
    /// The chat's retained sources, by name, when they are on the wire.
    public var retainedSourceNames: [String]
    /// A dated log handed over from the Chats library.
    public var datedSourceName: String?

    public init(
        hasLiveTranscript: Bool = false,
        workstreamName: String? = nil,
        hasMeetingNote: Bool = false,
        hasBrief: Bool = false,
        glossaryEntryCount: Int = 0,
        hasPendingScreenCapture: Bool = false,
        hasAmbientScreenRead: Bool = false,
        retainedSourceNames: [String] = [],
        datedSourceName: String? = nil
    ) {
        self.hasLiveTranscript = hasLiveTranscript
        self.workstreamName = workstreamName
        self.hasMeetingNote = hasMeetingNote
        self.hasBrief = hasBrief
        self.glossaryEntryCount = glossaryEntryCount
        self.hasPendingScreenCapture = hasPendingScreenCapture
        self.hasAmbientScreenRead = hasAmbientScreenRead
        self.retainedSourceNames = retainedSourceNames
        self.datedSourceName = datedSourceName
    }
}

/// The composer's context footnote, built from one input so the words and the
/// wire come from the same state. A screen entry appears exactly when a screen
/// block is sent, and a saved-source entry only when this chat's retained
/// archive is on the wire.
public enum ContextDisclosureLabels {
    public static let screenCaptureLabel = "Screen OCR"
    public static let ambientScreenLabel = "Screen OCR (ambient)"
    /// The composer's line for a turn whose attached sources keep the vault
    /// tools withheld. One string, so the controller's sentence and the render
    /// proof of it cannot drift apart.
    public static let vaultWithheldLine =
        "Vault search off while this chat uses attached sources. Choose Broader Search to search the vault."

    public static func make(_ input: ContextDisclosureInput) -> [String] {
        var labels: [String] = []
        if input.hasLiveTranscript { labels.append("Live transcript") }
        if let workstream = input.workstreamName, !workstream.isEmpty {
            labels.append(workstream)
        }
        if input.hasMeetingNote { labels.append("Meeting note") }
        if input.hasBrief { labels.append("Brief") }
        if input.glossaryEntryCount > 0 { labels.append("Glossary") }
        if let dated = input.datedSourceName, !dated.isEmpty { labels.append(dated) }
        if input.hasPendingScreenCapture { labels.append(screenCaptureLabel) }
        if input.hasAmbientScreenRead { labels.append(ambientScreenLabel) }
        if !input.retainedSourceNames.isEmpty {
            labels.append(savedSourcesLabel(input.retainedSourceNames))
        }
        return labels
    }

    /// "This chat's saved sources (report.pdf, photo.png)". At most two names,
    /// so the footnote stays one readable line.
    public static func savedSourcesLabel(_ names: [String]) -> String {
        let named = names.filter { !$0.isEmpty }
        guard !named.isEmpty else { return "This chat's saved sources" }
        let head = named.prefix(2).joined(separator: ", ")
        let rest = named.count - min(named.count, 2)
        return rest > 0
            ? "This chat's saved sources (\(head), and \(rest) more)"
            : "This chat's saved sources (\(head))"
    }
}
