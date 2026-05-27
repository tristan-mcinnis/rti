import AppKit
import SwiftUI

/// Owns every window in the app. Centralises presentation policy so
/// AppDelegate doesn't need to know about `NSWindow` or `NSHostingView`.
@MainActor
final class WindowCoordinator {
    /// App-wide singleton so panel views, hotkeys, and stores can drive
    /// window state without threading a coordinator reference through every
    /// init. AppDelegate still calls `install` once at launch.
    static let shared = WindowCoordinator()

    private var overlayController: OverlayWindowController?
    private var topWidget: TopWidgetWindowController?
    private var sessionsControl: SessionsControlWindowController?
    private var meetingBrief: MeetingBriefWindowController?
    private var onboarding: OnboardingWindowController?
    private var shortcutsController: ShortcutsWindowController?
    /// Singleton floating panels. One entry per `FloatingPanelID` once
    /// `install(_:)` has run; adding a new panel kind is just a new enum
    /// case + spec rather than another stored property here.
    private var floatingPanels: [FloatingPanelID: FloatingPanelWindowController] = [:]

    var overlayIsVisible: Bool { overlayController?.isVisible ?? false }
    var topWidgetIsVisible: Bool { topWidget?.isVisible ?? false }
    func isPanelVisible(_ id: FloatingPanelID) -> Bool {
        floatingPanels[id]?.isVisible ?? false
    }

    func install(onOpenSettings: @Sendable @escaping () -> Void) {
        shortcutsController = ShortcutsWindowController()
        sessionsControl = SessionsControlWindowController()
        meetingBrief = MeetingBriefWindowController()

        let controller = OverlayWindowController(onOpenSettings: onOpenSettings)
        overlayController = controller

        let actions = TopWidgetWindowController.Actions(
            onOpenChat: { [weak self] in self?.showOverlay() },
            onToggleOverlay: { [weak self] in self?.toggleOverlay() },
            onCaptureScreen: { ScreenshotManager.shared.captureAndAttach() },
            onToggleInvisibility: { [weak self] in self?.toggleInvisibility() },
            onOpenSettings: onOpenSettings,
            onShowLiveTranscript: { [weak self] in self?.showSessionsControl(tab: .liveTranscript) },
            onShowLogs: { [weak self] in self?.showSessionsControl(tab: .logs) },
            onClearChat: { NotificationCenter.default.post(name: .rtiClearChat, object: nil) },
            onShowShortcuts: { [weak self] in self?.showShortcuts() },
            onShowAbout: { [weak self] in self?.showAbout() },
            onQuit: { NSApp.terminate(nil) }
        )
        let top = TopWidgetWindowController(actions: actions)
        topWidget = top

        // Attach pill as a child of the overlay BEFORE showing the overlay.
        // Child windows inherit visibility from the parent, so the pill
        // appears together with the overlay on the first show().
        controller.attachPill(top.nsWindow)
        controller.show()

        for id in FloatingPanelID.allCases {
            floatingPanels[id] = FloatingPanelWindowController(spec: id.spec)
        }

        NotificationCenter.default.addObserver(
            forName: .rtiHideAuxiliaryPanels,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for controller in self.floatingPanels.values { controller.hide() }
            }
        }
    }

    func setSharingInvisible(_ invisible: Bool) {
        overlayController?.setSharingInvisible(invisible)
        topWidget?.setSharingInvisible(invisible)
        for controller in floatingPanels.values { controller.setSharingInvisible(invisible) }
    }

    /// Toggle the persisted invisibility flag and apply it to every panel.
    func toggleInvisibility() {
        let key = "rti.invisible"
        let current = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        let next = !current
        UserDefaults.standard.set(next, forKey: key)
        setSharingInvisible(next)
    }

    // MARK: - Overlay

    func showOverlay() { overlayController?.show() }
    func hideOverlay() { overlayController?.hide() }
    func toggleOverlay() { overlayController?.toggle() }

    // MARK: - Top Widget (now child of overlay; its visibility tracks overlay)

    /// Toggling the pill is now an alias for toggling the overlay, since the
    /// pill is a child window — it has no independent visibility worth
    /// exposing. ⌘⇧B remains wired to this for muscle-memory continuity.
    func toggleTopWidget() { toggleOverlay() }

    // MARK: - Sessions Control (unified: Live Transcript, Sessions, Settings, Logs)

    func showSessionsControl(tab: SessionsControlView.Tab = .liveTranscript) {
        sessionsControl?.show(tab: tab)
    }

    /// Open the read-only pre-meeting brief browser (Hermes-authored briefs).
    func showMeetingBrief() {
        meetingBrief?.show()
    }

    // MARK: - Legacy convenience wrappers used by AppDelegate / menu

    func showDebugConsole() { showSessionsControl(tab: .liveTranscript) }
    func toggleDebugConsole() { showSessionsControl(tab: .liveTranscript) }
    func openSettings() { showSessionsControl(tab: .settings) }

    // MARK: - Shortcuts

    func showShortcuts() { shortcutsController?.show() }

    // MARK: - Floating panels

    func show(_ id: FloatingPanelID) { floatingPanels[id]?.show() }
    func hide(_ id: FloatingPanelID) { floatingPanels[id]?.hide() }
    func toggle(_ id: FloatingPanelID) { floatingPanels[id]?.toggle() }

    // MARK: - Onboarding

    func showOnboardingIfNeeded() -> Bool {
        guard !OnboardingDefaults.hasCompleted else { return false }
        let controller = OnboardingWindowController()
        controller.showIfNeeded()
        onboarding = controller
        return true
    }

    /// Reopen the onboarding window unconditionally — wired to the menubar
    /// "Show Welcome…" item so a user who skipped, or who needs to revisit
    /// permissions/keys, can always come back.
    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController()
        }
        onboarding?.show()
    }

    // MARK: - About

    func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Real-time meeting intelligence.\nAudio is transcribed by Soniox; transcripts and prompts are answered by your configured LLM provider. Everything else stays on this Mac.\n\nhttps://github.com/tristan-mcinnis/rti",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        )
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Tristan McInnis"
        ]
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
