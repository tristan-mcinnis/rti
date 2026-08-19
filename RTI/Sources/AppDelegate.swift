import AppKit
import RTICore
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let windows = WindowCoordinator.shared
    private let menu = MenuCoordinator()
    private let hotkeys = HotkeyCoordinator()
    private let onboarding = OnboardingWindowController()
    private var sessionObservationTask: Task<Void, Never>?
    /// Only the primary process may update the shared clean-exit marker. A
    /// duplicate launch exits immediately after activating the existing app;
    /// if it wrote this marker on the way out, the primary instance's crash
    /// watchdog would mistake a later crash for a deliberate quit.
    private var isPrimaryInstance = false

    /// Marker the crash watchdog reads: present = last exit was a clean quit
    /// (don't relaunch); absent while not running = crash (relaunch).
    private static let cleanExitFlag = NSString(string: "~/.local/state/rti/clean-exit").expandingTildeInPath

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running again — clear the clean-exit marker so the watchdog knows a
        // disappearance from here on is a crash, not a quit.
        try? FileManager.default.removeItem(atPath: Self.cleanExitFlag)

        guard ensureSingleInstance() else { return }
        isPrimaryInstance = true

        // Route RTICore's logs (CoreLog) into the app's log buffer via RTILog.
        CoreLog.installSink { message, category in
            RTILog.log(message, category: category)
        }

        CrashLog.install()
        CredentialStore.migrateLegacyIfNeeded()

        continueLaunch()
    }

    @MainActor private func continueLaunch() {
        // Clear any phantom system-audio aggregate devices left by a prior
        // crash before the first tap-based capture runs.
        if #available(macOS 14.2, *) {
            CoreAudioTapCapture.cleanupStaleDevices()
        }

        // Belt-and-suspenders: delete any orphan WAV left in temp by a crash.
        // Normal stops already delete it; the app keeps no audio.
        WAVWriter.sweepStaleRecordings()

        // A quit, crash, or network outage during the offline pass leaves a
        // durable marker beside retained audio. Resume those jobs on launch;
        // nothing is routed or indexed until an upgrade succeeds.
        Task { @MainActor in
            for session in SessionArchive.pendingAutomaticUpgrades() {
                do {
                    _ = try await TranscriptUpgradeService.upgrade(
                        session: session,
                        provider: AsyncTranscriptProviders.soniox
                    ) { _ in }
                    SessionArchive.clearAutomaticUpgradePending(in: session.url)
                } catch {
                    RTILog.log("pending transcript upgrade remains queued for \(session.url.lastPathComponent): \(error.localizedDescription)", category: "archive")
                }
            }
        }

        windows.install()

        let invisible = UserDefaults.standard.object(forKey: OverlayAppearanceDefaults.invisibilityKey) as? Bool ?? true
        windows.setSharingInvisible(invisible)

        // Opt-in live-analysis tasks (Notes / Discussion Guide / Auto-assist),
        // all off by default — see Settings -> "Live analysis".
        SessionCoordinator.shared.registerAnalysisTasks()

        menu.install()
        hotkeys.registerAll()

        sessionObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = SessionCoordinator.shared.isRunning
                        _ = SessionCoordinator.shared.phase
                    } onChange: {
                        continuation.resume()
                    }
                }
                self?.menu.refreshTitle()
            }
        }

        registerNotificationObservers()

        // Route "session saved" notification taps to reveal the folder in Finder.
        UNUserNotificationCenter.current().delegate = self

        if AppPermissions.microphone != .granted {
            // First run (or mic revoked): the permission card, then straight
            // into Settings to collect API keys.
            onboarding.show(onFinish: { [weak self] in
                self?.windows.showOverlay()
                NotificationCenter.default.post(name: .rtiOpenSettings, object: nil)
            })
        } else if !LLMProviders.activeHasKey || !STTProviders.activeHasKey {
            // Mic already granted, keys still missing: straight to Settings.
            windows.showOverlay()
            NotificationCenter.default.post(name: .rtiOpenSettings, object: nil)
        }
    }

    /// Notification-center observers registered at launch in one call site.
    /// Panel toggles route through `WindowCoordinator.shared` directly —
    /// no notification middleman.
    private func registerNotificationObservers() {
        let observers: [(NSNotification.Name, Selector)] = [
            (.rtiToggleOverlay, #selector(toggleOverlay)),
        ]
        for (name, sel) in observers {
            NotificationCenter.default.addObserver(self, selector: sel, name: name, object: nil)
        }
    }

    @objc private func toggleOverlay() { windows.toggleOverlay() }

    private func ensureSingleInstance() -> Bool {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.tristan.rti"
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if instances.count > 1 {
            instances.first(where: { $0 != NSRunningApplication.current })?.activate()
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let session = SessionCoordinator.shared
        guard session.phase != .idle, session.phase != .done else { return .terminateNow }
        let alert = NSAlert()
        if session.isRunning || session.phase == .finishing {
            alert.messageText = "Recording in progress"
            alert.informativeText = "RTI is still saving this recording. Quit only if you want to stop before processing is complete."
        } else {
            alert.messageText = "Transcript improvement in progress"
            alert.informativeText = "RTI has not yet generated or indexed the final notes. Wait for “Notes ready” before quitting."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard isPrimaryInstance else { return }
        SessionCoordinator.shared.emergencyShutdown()
        let dir = (Self.cleanExitFlag as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.cleanExitFlag, contents: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            windows.showOverlay()
        }
        return true
    }
}

// MARK: - Notification taps

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Present the "summary ready" banner even while RTI is frontmost, so its
    /// tap affordance is available without first backgrounding the app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Tapping "Saved: <title>" reveals that session's folder in Finder — RTI
    /// keeps no in-app reader for the archive by design.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let folderPath = response.notification.request.content.userInfo["sessionFolder"] as? String
        if let folderPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folderPath)])
        }
        completionHandler()
    }
}
