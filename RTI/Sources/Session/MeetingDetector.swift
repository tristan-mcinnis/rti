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

    /// Bundle id → display name for the meeting apps we react to on launch.
    /// Browser-based meetings (Google Meet) aren't here: there's no app
    /// launch to observe. Slack huddles are in-app and equally invisible.
    /// Those gaps are covered by the camera-activation signal below.
    private static let meetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
    ]

    /// Bundle id → display name for apps that can host a *camera* meeting.
    /// A live camera alone is ambiguous (Photo Booth, a selfie); we only
    /// react when one of these is running, which makes "camera on" a strong
    /// "in a call" signal. Browsers are included because Google Meet / Teams
    /// web / Webex web all run in them — the cases launch-detection misses.
    private static let cameraMeetingApps: [String: String] = [
        // Native conferencing
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
        // Browsers (web meetings)
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
    ]

    private let camera = CameraActivityMonitor()

    /// Cooldown so toggling the camera doesn't re-prompt in a tight loop.
    /// A "Not now" sticks for the current camera-on stretch because we only
    /// react to the off→on transition, but this also guards rapid flaps.
    private var lastCameraPromptAt: Date?

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

        camera.onCameraStateChanged = { [weak self] active in
            guard active else { return }
            self?.cameraBecameActive()
        }
        camera.start()
    }

    /// A camera just turned on. If a meeting-capable app is running and we're
    /// not already recording, treat it as a meeting starting. This is what
    /// catches Google Meet, Teams-web, and Slack huddles — none of which
    /// fire an app-launch we can observe.
    private func cameraBecameActive() {
        guard UserDefaults.standard.object(forKey: MeetingDetectionDefaults.enabledKey) as? Bool ?? true else { return }
        guard !SessionCoordinator.shared.isRunning else { return }

        // Debounce rapid camera flaps.
        if let last = lastCameraPromptAt, Date().timeIntervalSince(last) < 60 { return }

        guard let appName = runningCameraMeetingAppName() else {
            RTILog.log("camera active but no meeting-capable app running — ignoring", category: "meeting")
            return
        }

        lastCameraPromptAt = Date()
        RTILog.log("camera active with \(appName) running", category: "meeting")

        if UserDefaults.standard.bool(forKey: MeetingDetectionDefaults.autoStartKey) {
            SessionCoordinator.shared.startSession()
            return
        }
        promptToRecord(title: "Camera active in \(appName)")
    }

    /// Display name of a running app that can host a camera meeting, if any.
    private func runningCameraMeetingAppName() -> String? {
        for app in NSWorkspace.shared.runningApplications {
            if let bundleId = app.bundleIdentifier,
               let name = Self.cameraMeetingApps[bundleId] {
                return name
            }
        }
        return nil
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

        promptToRecord(title: "\(name) is starting")
    }

    private func promptToRecord(title: String) {
        let alert = NSAlert()
        alert.messageText = title
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
