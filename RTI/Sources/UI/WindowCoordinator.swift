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
    private var sessionsControl: SessionsControlWindowController?
    private var meetingBrief: MeetingBriefWindowController?
    /// Singleton floating panels. One entry per `FloatingPanelID` once
    /// `install(_:)` has run; adding a new panel kind is just a new enum
    /// case + spec rather than another stored property here.
    private var floatingPanels: [FloatingPanelID: FloatingPanelWindowController] = [:]

    var overlayIsVisible: Bool { overlayController?.isVisible ?? false }
    func isPanelVisible(_ id: FloatingPanelID) -> Bool {
        floatingPanels[id]?.isVisible ?? false
    }

    func install(onOpenSettings: @Sendable @escaping () -> Void) {
        sessionsControl = SessionsControlWindowController()
        meetingBrief = MeetingBriefWindowController()

        let controller = OverlayWindowController(onOpenSettings: onOpenSettings)
        overlayController = controller
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
        for controller in floatingPanels.values { controller.setSharingInvisible(invisible) }
    }

    /// Toggle the persisted invisibility flag and apply it to every panel.
    func toggleInvisibility() {
        let key = OverlayAppearanceDefaults.invisibilityKey
        let current = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        let next = !current
        UserDefaults.standard.set(next, forKey: key)
        setSharingInvisible(next)
    }

    // MARK: - Overlay

    func showOverlay() { overlayController?.show() }
    func hideOverlay() { overlayController?.hide() }
    func toggleOverlay() { overlayController?.toggle() }

    // MARK: - Sessions Control (unified: Live Transcript, Sessions, Settings, Logs)

    func showSessionsControl(tab: SessionsControlView.Tab = .liveTranscript) {
        sessionsControl?.show(tab: tab)
    }

    /// Open the read-only pre-meeting brief browser (Hermes-authored briefs).
    func showMeetingBrief() {
        meetingBrief?.show()
    }

    // MARK: - Convenience wrappers used by AppDelegate / menu

    func showLiveTranscript() { showSessionsControl(tab: .liveTranscript) }
    func openSettings() { showSessionsControl(tab: .settings) }

    // MARK: - Floating panels

    func show(_ id: FloatingPanelID) { floatingPanels[id]?.show() }
    func hide(_ id: FloatingPanelID) { floatingPanels[id]?.hide() }
    func toggle(_ id: FloatingPanelID) { floatingPanels[id]?.toggle() }

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
