import Foundation

/// What runs after a recording stops (2026-11-20). The after-call transcript
/// pays for speaker labels and a better read of names and Mandarin terms;
/// it is not worth it for a private call or a test blip.
public enum AfterCallPlan: Equatable, Sendable {
    /// Upgrade the transcript, then write the meeting note from it.
    case upgrade
    /// No upgrade: write the meeting note from the live transcript.
    case liveNote
    /// Neither: too short to be a meeting.
    case nothing

    /// Recordings shorter than this are a test or a false start.
    public static let minimumSeconds: TimeInterval = 120

    public static func decide(callType: CallType, audioSeconds: TimeInterval) -> AfterCallPlan {
        if audioSeconds < minimumSeconds {
            return .nothing
        }
        return callType == .personal ? .liveNote : .upgrade
    }

    /// One line for the status after Stop, or nil when the upgrade runs.
    public var statusLine: String? {
        switch self {
        case .upgrade: nil
        case .liveNote: "Personal call: no transcript upgrade; the meeting note uses the live transcript."
        case .nothing: "Under two minutes: no transcript upgrade or meeting note."
        }
    }
}
