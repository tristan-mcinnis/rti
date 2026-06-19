import SwiftUI

@main
struct RTIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Swift 6 runtime regression: swift_task_isCurrentExecutor() ABORTS
        // (SIGABRT in objc_fatal) instead of returning a best-effort answer
        // when it can't confirm the main executor during an AppKit teardown
        // layout pass — crashing RTI at session end as the overlay re-lays-out
        // the "Notes ready" bar (OverlayMicControl.body re-eval via
        // NSHostingView.layout()). Our code is correct (AppKit delivers hover
        // and layout on main); the check is a false positive. Revert it to the
        // non-fatal legacy behaviour. Runs before the first body eval, so it's
        // set before the runtime first reads it. The shipped .app gets the same
        // via LSEnvironment in Info.plist; this covers Xcode/terminal launches,
        // which ignore LSEnvironment.
        setenv("SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE", "legacy", 1)
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}
