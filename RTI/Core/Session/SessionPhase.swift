import Foundation

/// The session lifecycle as an explicit state machine. Every phase is
/// something the UI can name to the user:
///
///   idle → recording ⇄ paused → finishing → upgrading → done → (idle/recording)
///
/// `paused` keeps the Soniox socket warm (fed silence) so resume is instant.
/// `finishing` is the brief post-stop flush window; `upgrading` is the
/// automatic offline transcript upgrade running; `done` is the frozen, saved
/// state. Starting a new session is allowed from `upgrading` onward.
///
/// Lives in RTICore (as `SessionCoordinator.Phase`, its original spelling) so
/// pure policy over the phase — `MenuStatusTick` — is testable without the app
/// module.
public enum SessionPhase: Equatable, Sendable {
    case idle, recording, paused, finishing, upgrading, done
}
