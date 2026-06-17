import AppKit
import RTICore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let windows = WindowCoordinator.shared
    private let menu = MenuCoordinator()
    private let hotkeys = HotkeyCoordinator()
    private let onboarding = OnboardingWindowController()
    private var sessionObservationTask: Task<Void, Never>?

    /// Marker the crash watchdog reads: present = last exit was a clean quit
    /// (don't relaunch); absent while not running = crash (relaunch).
    private static let cleanExitFlag = NSString(string: "~/.local/state/rti/clean-exit").expandingTildeInPath

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running again — clear the clean-exit marker so the watchdog knows a
        // disappearance from here on is a crash, not a quit.
        try? FileManager.default.removeItem(atPath: Self.cleanExitFlag)

        guard ensureSingleInstance() else { return }

        // Route RTICore's logs (CoreLog) into the app's log buffer via RTILog.
        CoreLog.installSink { message, category in
            RTILog.log(message, category: category)
        }

        CrashLog.install()
        CredentialStore.migrateLegacyIfNeeded()

        // Wake the Neon search compute now so the first vault search of the
        // session doesn't pay the serverless cold-start.
        VaultSearchCLI.warmUp()

        continueLaunch()
    }

    @MainActor private func continueLaunch() {
        _ = ModeStore.shared

        // Clear any phantom system-audio aggregate devices left by a prior
        // crash before the first tap-based capture runs.
        if #available(macOS 14.2, *) {
            CoreAudioTapCapture.cleanupStaleDevices()
        }

        // Belt-and-suspenders: delete any orphan WAV left in temp by a crash.
        // Normal stops already delete it; the app keeps no audio.
        WAVWriter.sweepStaleRecordings()

        // Follow the external Meeting Sentinel tool's recording state so the
        // UI can surface when a meeting is being recorded outside RTI.
        MeetingSentinelMonitor.shared.start()

        // Register the periodic real-time analysis tasks (notes,
        // discussion-guide matching). They only fire while a session runs and
        // self-gate on their Settings toggles.
        SessionCoordinator.shared.registerAnalysisTasks()

        windows.install(onOpenSettings: { [weak self] in
            Task { @MainActor [weak self] in self?.windows.openSettings() }
        })

        let invisible = UserDefaults.standard.object(forKey: OverlayAppearanceDefaults.invisibilityKey) as? Bool ?? true
        windows.setSharingInvisible(invisible)

        // Build the shared command registry once. Menu, hotkeys, and the
        // command palette all consume this same list.
        let commands = CommandBuilder.buildCommands(
            windows: windows,
            session: SessionCoordinator.shared,
            llm: LLMController.shared,
            modes: ModeStore.shared
        )

        CommandRegistry.shared.replaceAll(commands)

        // Menu: dynamic state providers for items whose titles change.
        menu.currentSessionIdProvider = { SessionCoordinator.shared.currentSessionId }
        menu.isRunningProvider = { SessionCoordinator.shared.isRunning }
        menu.smartModeProvider = { LLMController.shared.smartMode }
        menu.invisibilityProvider = { UserDefaults.standard.object(forKey: OverlayAppearanceDefaults.invisibilityKey) as? Bool ?? true }
        menu.install(commands: commands)

        hotkeys.registerAll(commands: commands)

        sessionObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = SessionCoordinator.shared.isRunning
                    } onChange: {
                        continuation.resume()
                    }
                }
                self?.menu.refreshTitle()
            }
        }

        registerNotificationObservers()

        if CredentialStore.deepseek == nil || CredentialStore.soniox == nil {
            // First run (or keys cleared): guide setup instead of cold-dropping
            // into Settings.
            onboarding.show()
        } else {
            // Quiet update check on normal launches — silent unless a newer
            // build has been published.
            UpdateChecker.checkInBackground()
        }
    }

    /// Notification-center observers registered at launch in one call site.
    /// Panel toggles route through `WindowCoordinator.shared` directly —
    /// no notification middleman.
    private func registerNotificationObservers() {
        let observers: [(NSNotification.Name, Selector)] = [
            (.rtiToggleOverlay, #selector(toggleOverlay)),
            (.rtiClearChat, #selector(clearChat)),
        ]
        for (name, sel) in observers {
            NotificationCenter.default.addObserver(self, selector: sel, name: name, object: nil)
        }
    }

    @objc private func toggleOverlay() { windows.toggleOverlay() }
    @objc private func clearChat() { Self.clearChatNow() }

    /// Clear the current session's chat immediately — no confirmation modal.
    /// The chat is ephemeral (no persisted history) and the live transcript is
    /// untouched, so a blocking "Are you sure?" alert was pure friction; clearing
    /// is now a single click / keystroke. Static so `CommandPaletteFactory` can
    /// reference it without a live AppDelegate instance.
    static func clearChatNow() {
        LLMController.shared.clear()
        NotificationCenter.default.post(name: .rtiHideAuxiliaryPanels, object: nil)
    }

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
        guard SessionCoordinator.shared.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Recording in progress"
        alert.informativeText = "RTI is currently recording a session. Quitting will stop the recording, flush the WAV file, and finalize the session."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop & Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
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