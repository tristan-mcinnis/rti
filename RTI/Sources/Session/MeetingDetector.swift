import AppKit
import Foundation

/// Watches for known meeting apps launching and offers to start an RTI
/// recording. Launch detection is a proxy for "a meeting is starting" —
/// it fires when the app process appears, not when a call is actually
/// joined (joining state isn't observable without per-app window
/// inspection). Good enough to prompt; the user confirms.
///
/// Default behaviour is to *prompt* (Start / Not now), never to record
/// silently — recording a meeting carries consent weight. An opt-in
/// `autoStart` setting skips the prompt for users who want it.
@MainActor
final class MeetingDetector {
    static let shared = MeetingDetector()

    /// Bundle id → display name for the meeting apps we react to.
    /// Browser-based meetings (Google Meet) aren't here: there's no app
    /// launch to observe. Slack huddles are in-app and equally invisible.
    private static let meetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
    ]

    /// Process ids we've already reacted to, so a single launch prompts
    /// once even if the app posts multiple notifications, and a user who
    /// says "Not now" isn't nagged again for that same running instance.
    private var handledPIDs = Set<pid_t>()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    @objc private func appLaunched(_ note: Notification) {
        guard UserDefaults.standard.object(forKey: MeetingDetectionDefaults.enabledKey) as? Bool ?? true else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier,
              let name = Self.meetingApps[bundleId] else { return }

        let pid = app.processIdentifier
        guard !handledPIDs.contains(pid) else { return }
        handledPIDs.insert(pid)

        // Already capturing — nothing to offer.
        guard !SessionCoordinator.shared.isRunning else { return }

        RTILog.log("Meeting app detected: \(name) (\(bundleId))", category: "meeting")

        if UserDefaults.standard.bool(forKey: MeetingDetectionDefaults.autoStartKey) {
            SessionCoordinator.shared.startSession()
            return
        }

        promptToRecord(appName: name)
    }

    private func promptToRecord(appName: String) {
        let alert = NSAlert()
        alert.messageText = "\(appName) is starting"
        alert.informativeText = "Start an RTI recording for this meeting?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Not Now")

        // LSUIElement app: bring the alert forward so it isn't lost behind
        // the meeting window.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SessionCoordinator.shared.startSession()
        }
    }
}
