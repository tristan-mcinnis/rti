import Foundation

// What the overlay header says about the live session, as pure values
// (chat-surfaces.md section 8, "Live and cockpit surfaces"). The header
// draws a title over a state line that starts with a status dot and its
// word, and holds one live action on the right: the record chip.

/// The session phases the header shows. Mirrors `SessionCoordinator.Phase`
/// so the rules stay testable without the app.
public enum OverlayLivePhase: String, CaseIterable, Sendable {
    case idle, recording, paused, finishing, summarizing, done

    /// Capture is running (recording or paused).
    public var isLive: Bool { self == .recording || self == .paused }
}

/// The status dot's meaning. The view maps it to a house status token and
/// always draws the word beside it (never colour alone).
public enum OverlayStatusTone: Equatable, Sendable {
    /// `success`: ready, saved, notes ready.
    case ready
    /// `danger`: recording, the only live chroma.
    case recording
    /// `warning`: paused, saving, improving, or a failed upgrade.
    case busy
}

/// The leading mark inside the record chip.
public enum OverlayRecordLead: Equatable, Sendable {
    /// The record affordance: a `danger` dot.
    case recordDot
    /// Capture running: a `danger` square beside the clock.
    case liveMark
    /// A short save flush: a small spinner.
    case spinner
    /// A plain glyph, for "Open Notes".
    case glyph(String)
}

/// The record chip, the header's one live action.
public struct OverlayRecordChip: Equatable, Sendable {
    public let lead: OverlayRecordLead
    public let title: String
    /// Key caps drawn after the title. Empty when the chip's action has no key.
    public let keys: [String]
    /// The captured-time clock sits beside the lead mark.
    public let showsClock: Bool
    public let isEnabled: Bool
    public let accessibilityLabel: String
    public let help: String
}

/// Everything the header shows for one phase.
public struct OverlayShellStatus: Equatable, Sendable {
    public static let recordKeys = ["⌘", "⇧", "R"]

    public let phase: OverlayLivePhase
    /// The finished session has its notes (the summary file exists).
    public let summaryReady: Bool
    /// The post-processing line from the session, if any ("Upgrade failed ·
    /// audio retained").
    public let processingStatus: String?

    public init(phase: OverlayLivePhase, summaryReady: Bool = false, processingStatus: String? = nil) {
        self.phase = phase
        self.summaryReady = summaryReady
        self.processingStatus = processingStatus
    }

    // MARK: State line

    /// The word after the status dot.
    public var word: String {
        switch phase {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .finishing: return "Saving"
        case .summarizing: return nonEmpty(processingStatus) ?? "Improving transcript"
        case .done:
            if summaryReady { return "Notes ready" }
            return failedUpgradeStatus ?? "Session saved"
        }
    }

    public var tone: OverlayStatusTone {
        switch phase {
        case .idle: return .ready
        case .recording: return .recording
        case .paused, .finishing, .summarizing: return .busy
        case .done: return summaryReady || failedUpgradeStatus == nil ? .ready : .busy
        }
    }

    // MARK: Record chip

    public var recordChip: OverlayRecordChip {
        switch phase {
        case .recording, .paused:
            return OverlayRecordChip(
                lead: .liveMark,
                title: "Finish",
                keys: Self.recordKeys,
                showsClock: true,
                isEnabled: true,
                accessibilityLabel: "Finish recording",
                help: "Finish the recording and improve the transcript (⌘⇧R)"
            )
        case .finishing:
            return OverlayRecordChip(
                lead: .spinner,
                title: "Saving",
                keys: [],
                showsClock: false,
                isEnabled: false,
                accessibilityLabel: "Saving the recording",
                help: "Saving the audio…"
            )
        case .summarizing:
            return OverlayRecordChip(
                lead: .recordDot,
                title: "Record",
                keys: Self.recordKeys,
                showsClock: false,
                isEnabled: true,
                accessibilityLabel: "Start recording",
                help: "Start a new recording (⌘⇧R). The last one is still being improved."
            )
        case .done where summaryReady:
            return OverlayRecordChip(
                lead: .glyph("doc.text"),
                title: "Open Notes",
                keys: [],
                showsClock: false,
                isEnabled: true,
                accessibilityLabel: "Open notes",
                help: "Open the notes for this session. ⌘⇧R starts a new recording."
            )
        case .idle, .done:
            return OverlayRecordChip(
                lead: .recordDot,
                title: "Record",
                keys: Self.recordKeys,
                showsClock: false,
                isEnabled: true,
                accessibilityLabel: "Start recording",
                help: "Start recording (⌘⇧R)"
            )
        }
    }

    // MARK: Title

    /// The header title: the calendar event picked in Prepare, then the
    /// project, then "Live session" while capture runs, then the surface
    /// name. (The resolved archive title belongs to the Sessions window.)
    public static func title(calendarTitle: String?, projectName: String?, phase: OverlayLivePhase) -> String {
        if let calendarTitle = nonEmpty(calendarTitle) { return calendarTitle }
        if let projectName = nonEmpty(projectName) { return projectName }
        return phase.isLive ? "Live session" : "RTI"
    }

    // MARK: Private

    /// A post-processing line that reports a problem, not the normal
    /// "Session saved" or "Notes ready".
    private var failedUpgradeStatus: String? {
        guard let status = nonEmpty(processingStatus),
              status != "Session saved", status != "Notes ready" else { return nil }
        return status
    }

    private func nonEmpty(_ text: String?) -> String? { Self.nonEmpty(text) }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
