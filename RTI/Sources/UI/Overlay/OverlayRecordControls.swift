import RTICore
import SwiftUI

// MARK: - Visual context control

/// Quiet but explicit ambient-capture state. It appears only while a session
/// is live: Littlebird's low-friction context should never become invisible
/// surveillance. One click stops or resumes the screen trail immediately.
struct OverlayVisualContextButton: View {
    private let session = SessionCoordinator.shared
    private let trail = VisualContextTrail.shared
    @State private var hovering = false

    var body: some View {
        if session.isRunning {
            Button(action: act) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 28)
                    .background(Capsule(style: .continuous).fill(background))
                    .overlay(Capsule(style: .continuous).stroke(border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .hoverHighlight($hovering)
            .accessibilityLabel("Screen context")
            .accessibilityValue(statusText)
            .accessibilityHint(actionHint)
            .help("\(statusText) — \(actionHint)")
        }
    }

    private var icon: String {
        switch trail.state {
        case .disabled: "eye.slash"
        case .permissionRequired, .failed: "exclamationmark.triangle.fill"
        case .paused: "eye.slash.fill"
        default: trail.events.isEmpty ? "eye" : "eye.fill"
        }
    }

    private var tint: Color {
        switch trail.state {
        case .permissionRequired, .failed, .paused: .orange
        case .disabled: Color.overlayInk.opacity(0.38)
        case .capturing, .active: .blue
        default: Color.overlayInk.opacity(0.52)
        }
    }

    private var background: Color {
        switch trail.state {
        case .permissionRequired, .failed, .paused: Color.orange.opacity(0.12)
        case .capturing, .active: Color.blue.opacity(0.12)
        default: Color.overlayInk.opacity(hovering ? 0.08 : 0.045)
        }
    }

    private var border: Color {
        switch trail.state {
        case .permissionRequired, .failed, .paused: Color.orange.opacity(0.45)
        case .capturing, .active: Color.blue.opacity(0.35)
        default: Color.overlayInk.opacity(hovering ? 0.16 : 0.08)
        }
    }

    private var statusText: String {
        switch trail.state {
        case .disabled: "Screen context off"
        case .idle, .waiting: "Screen context ready"
        case .capturing: "Reading the active screen"
        case .active:
            "Screen context on · \(trail.events.count) visual \(trail.events.count == 1 ? "change" : "changes") captured"
        case .paused: "Screen context paused with the recording"
        case .permissionRequired: "Screen Recording access required"
        case .failed: trail.lastError ?? "Screen context unavailable"
        }
    }

    private var actionHint: String {
        switch trail.state {
        case .disabled: "Turn on one-minute active-screen OCR; images are discarded"
        case .permissionRequired: "Open Screen Recording settings"
        case .paused: "Resumes automatically with the recording"
        default: "Turn off screen context"
        }
    }

    private func act() {
        if trail.state == .permissionRequired {
            trail.retryPermissionOrOpenSettings(sessionStartedAt: session.startedAt)
        } else {
            trail.setEnabled(!trail.isEnabled, sessionStartedAt: trail.isEnabled ? nil : session.startedAt)
            if session.isPaused { trail.setPaused(true) }
        }
    }
}

// MARK: - Record control

/// Inline record control in the overlay header. Now phase-aware: instead of a
/// binary record/stop, it names every step of the lifecycle so the user always
/// knows what the app is doing — recording, paused, saving, generating the
/// summary, or done (Granola-style). Click is the forward action for the
/// current phase (start / finish / start-new); pause/resume and "open summary"
/// live in the small aux button beside it (`OverlaySessionAuxButton`).
struct OverlayRecordButton: View {
    private let coordinator = SessionCoordinator.shared

    @State private var hovering = false

    var body: some View {
        Button(action: primaryAction) {
            glyph
                .frame(width: 30, height: 28)
            .background(background)
            .overlay(Capsule(style: .continuous).stroke(borderColor, lineWidth: 1))
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(coordinator.phase == .finishing)
        .hoverHighlight($hovering)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(helpText)
        .help(helpText)
    }

    private var accessibilityLabel: String {
        switch coordinator.phase {
        case .idle: "Start recording"
        case .recording: "Finish and summarize recording"
        case .paused: "Finish and summarize paused recording"
        case .finishing: "Saving session"
        case .summarizing: "Generating summary"
        case .done: coordinator.summaryURL != nil ? "Open notes in Sessions" : "Start a new recording"
        }
    }

    private func primaryAction() {
        // Once the summary has landed, the "Notes ready" control reads as a
        // notes button — so it opens the notes in the Sessions browser rather
        // than starting a new recording (that moved to the aux button beside
        // it). Every other phase: toggleSession handles start/finish.
        if coordinator.phase == .done, let url = coordinator.summaryURL {
            WindowCoordinator.shared.showSession(folder: url.deletingLastPathComponent().lastPathComponent)
            return
        }
        coordinator.toggleSession()
    }

    @ViewBuilder
    private var glyph: some View {
        switch coordinator.phase {
        case .recording:
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(red: 1.0, green: 0.27, blue: 0.27))
                .frame(width: 8, height: 8)
        case .paused:
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.orange)
                .frame(width: 8, height: 8)
        case .finishing, .summarizing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
                .frame(width: 9, height: 9)
        case .done:
            Image(systemName: coordinator.summaryURL != nil ? "checkmark.circle.fill" : "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(coordinator.summaryURL != nil ? Color.green.opacity(0.9) : Color.overlayInk.opacity(0.55))
        case .idle:
            Circle()
                .fill(Color(red: 1.0, green: 0.27, blue: 0.27).opacity(0.85))
                .frame(width: 7, height: 7)
        }
    }

    private var background: some View {
        ZStack {
            Capsule(style: .continuous).fill(Color.overlayInk.opacity(hovering ? 0.08 : 0.045))
            switch coordinator.phase {
            case .recording:
                Capsule(style: .continuous).fill(Color(red: 1.0, green: 0.20, blue: 0.20).opacity(0.12))
            case .paused:
                Capsule(style: .continuous).fill(Color.orange.opacity(0.10))
            default:
                EmptyView()
            }
        }
    }

    private var borderColor: Color {
        switch coordinator.phase {
        case .recording: Color(red: 1.0, green: 0.30, blue: 0.30).opacity(0.45)
        case .paused: Color.orange.opacity(0.5)
        default: Color.overlayInk.opacity(hovering ? 0.16 : 0.08)
        }
    }

    private var helpText: String {
        switch coordinator.phase {
        case .idle: "Start recording (⌘⇧R)"
        case .recording: "Finish & summarize (⌘⇧R)"
        case .paused: "Finish & summarize (⌘⇧R) — currently paused"
        case .finishing: "Saving the session…"
        case .summarizing: "Generating the summary in the background — click to start a new recording"
        case .done: coordinator.summaryURL != nil
            ? "Notes ready — click to open them in Sessions. Start a new recording with the button beside this (⌘⇧R)"
            : "Session saved. Click to start a new recording (⌘⇧R)"
        }
    }
}

/// Small companion button beside the record control. Pause/resume while a
/// session is live; "open summary" once notes are ready. Only shown when it has
/// something to do, so the header stays uncluttered when idle.
struct OverlaySessionAuxButton: View {
    private let coordinator = SessionCoordinator.shared
    @State private var hovering = false

    private enum Kind { case pause, resume, newRecording, none }

    private var kind: Kind {
        switch coordinator.phase {
        case .recording: .pause
        case .paused: .resume
        // Notes are ready: the primary control now opens them, so this companion
        // becomes the way to start the next recording.
        case .done: coordinator.summaryURL != nil ? .newRecording : .none
        default: .none
        }
    }

    var body: some View {
        if kind != .none {
            Button(action: act) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 28)
                .background(Capsule(style: .continuous).fill(Color.overlayInk.opacity(hovering ? 0.08 : 0.045)))
                .overlay(Capsule(style: .continuous).stroke(Color.overlayInk.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .hoverHighlight($hovering)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(help)
            .help(help)
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .pause: "Pause recording"
        case .resume: "Resume recording"
        case .newRecording: "Start a new recording"
        case .none: ""
        }
    }

    private var icon: String {
        switch kind {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .newRecording: "record.circle"
        case .none: ""
        }
    }

    private var tint: Color {
        switch kind {
        case .resume: Color.green.opacity(0.9)
        case .newRecording: Color(red: 1.0, green: 0.27, blue: 0.27).opacity(0.9)
        default: Color.overlayInk.opacity(0.7)
        }
    }

    private var help: String {
        switch kind {
        case .pause: "Pause (⌘⇧P) — stops transcribing, keeps the connection live so resume is instant"
        case .resume: "Resume recording (⌘⇧P)"
        case .newRecording: "Start a new recording (⌘⇧R)"
        case .none: ""
        }
    }

    private func act() {
        switch kind {
        case .pause, .resume: coordinator.togglePause()
        case .newRecording: coordinator.toggleSession()
        case .none: break
        }
    }
}
