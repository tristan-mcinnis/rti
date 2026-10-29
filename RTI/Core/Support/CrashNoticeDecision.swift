import Foundation

/// Decides whether the launch after a crash shows the "RTI crashed" notice.
/// The app drops a clean-exit marker on a normal quit and removes it at every
/// launch, so a missing marker at launch means the last run did not quit
/// normally (signal, trap, force-unwrap or uncaught exception).
public enum CrashNoticeDecision {
    /// - previousExitWasClean: the clean-exit marker existed at launch.
    /// - onboardingNeeded: first run (or cleared keys); onboarding owns the
    ///   screen and a fresh install has no marker either.
    public static func shouldShow(previousExitWasClean: Bool, onboardingNeeded: Bool) -> Bool {
        !previousExitWasClean && !onboardingNeeded
    }
}
