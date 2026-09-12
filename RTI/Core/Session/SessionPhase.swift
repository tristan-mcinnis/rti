import Foundation

/// The session lifecycle as an explicit state machine. Every phase is
/// something the UI can name to the user:
///
///   idle → recording ⇄ paused → finishing → summarizing → done → (idle/recording)
///
/// `paused` keeps the Soniox socket warm (fed silence) so resume is instant.
/// `finishing` is the brief post-stop flush window; `summarizing` is the
/// end-of-session auto-summary running; `done` is the frozen, summary-ready
/// state. Starting a new session is allowed from `summarizing` onward.
///
/// Lives in RTICore (as `SessionCoordinator.Phase`, its original spelling) so
/// pure policy over the phase — `MenuStatusTick` — is testable without the app
/// module.
public enum SessionPhase: Equatable, Sendable {
    case idle, recording, paused, finishing, summarizing, done
}
