import AppKit
import SwiftUI

/// Owns every window in the app. Centralises presentation policy so
/// AppDelegate doesn't need to know about `NSWindow` or `NSHostingView`.
@MainActor
final class WindowCoordinator {
    private var overlayController: OverlayWindowController?
    private var topWidget: TopWidgetWindowController?
    private var sessionsControl: SessionsControlWindowController?
    private var onboarding: OnboardingWindowController?
    private var shortcutsController: ShortcutsWindowController?
    private var commandPalette: CommandPaletteWindowController?
    private var notesPanel: NotesPanelWindowController?
    private var dossiersPanel: DossiersPanelWindowController?

    var overlayIsVisible: Bool { overlayController?.isVisible ?? false }
    var topWidgetIsVisible: Bool { topWidget?.isVisible ?? false }
    var notesPanelIsVisible: Bool { notesPanel?.isVisible ?? false }
    var dossiersPanelIsVisible: Bool { dossiersPanel?.isVisible ?? false }

    func install(onOpenSettings: @Sendable @escaping () -> Void) {
        shortcutsController = ShortcutsWindowController()
        sessionsControl = SessionsControlWindowController()

        let controller = OverlayWindowController(onOpenSettings: onOpenSettings)
        overlayController = controller

        let actions = TopWidgetWindowController.Actions(
            onOpenChat: { [weak self] in self?.showOverlay() },
            onOpenSessionHome: { [weak self] in self?.showSessionsControl(tab: .sessions) },
            onToggleOverlay: { [weak self] in self?.toggleOverlay() },
            onCaptureScreen: { ScreenshotManager.shared.captureAndAttach() },
            onToggleInvisibility: { [weak self] in self?.toggleInvisibility() },
            onOpenSettings: onOpenSettings,
            onShowLiveTranscript: { [weak self] in self?.showSessionsControl(tab: .liveTranscript) },
            onShowLogs: { [weak self] in self?.showSessionsControl(tab: .logs) },
            onShowSessionHistory: { [weak self] in self?.showSessionsControl(tab: .sessions) },
            onOpenCurrentSessionDetail: { [weak self] in
                if let id = SessionCoordinator.shared.currentSessionId {
                    self?.openSessionDetail(for: id)
                } else {
                    self?.showSessionsControl(tab: .sessions)
                }
            },
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

        commandPalette = CommandPaletteWindowController()

        notesPanel = NotesPanelWindowController()
        dossiersPanel = DossiersPanelWindowController()
    }

    func setSharingInvisible(_ invisible: Bool) {
        overlayController?.setSharingInvisible(invisible)
        topWidget?.setSharingInvisible(invisible)
        notesPanel?.setSharingInvisible(invisible)
        dossiersPanel?.setSharingInvisible(invisible)
    }

    /// Toggle the persisted invisibility flag and apply it to both windows.
    /// Mirrors AppDelegate.toggleInvisibility so the right-click pill menu
    /// can drive it without reaching through more layers.
    private func toggleInvisibility() {
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

    func showSessionInSessionsControl(id: String) {
        sessionsControl?.show(sessionId: id)
    }

    // MARK: - Legacy convenience wrappers used by AppDelegate / menu

    func showDebugConsole() { showSessionsControl(tab: .liveTranscript) }
    func toggleDebugConsole() { showSessionsControl(tab: .liveTranscript) }
    func openSettings() { showSessionsControl(tab: .settings) }
    func showSessionHistory() { showSessionsControl(tab: .sessions) }
    func openSessionDetail(for id: String) { showSessionInSessionsControl(id: id) }

    // MARK: - Shortcuts

    func showShortcuts() { shortcutsController?.show() }

    // MARK: - Command Palette

    func toggleCommandPalette() { commandPalette?.toggle() }

    // MARK: - Analysis Panels

    func showNotesPanel() { notesPanel?.show() }
    func hideNotesPanel() { notesPanel?.hide() }
    func toggleNotesPanel() { notesPanel?.toggle() }

    func showDossiersPanel() { dossiersPanel?.show() }
    func hideDossiersPanel() { dossiersPanel?.hide() }
    func toggleDossiersPanel() { dossiersPanel?.toggle() }

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
