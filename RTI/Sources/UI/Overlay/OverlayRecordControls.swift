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

// MARK: - Project routing picker

/// Compact project dropdown beside the record button, so a recording is routed
/// to its vault project at the moment of capture instead of orphaned in the
/// generic meetings pool. The selection flows through the existing pipe:
/// MeetingContextStore → SentinelCommandBuilder start/stop --project →
/// `<stem>.meeting.json` → the /meeting skill. Picking mid-recording works;
/// the slug is passed again at stop.
struct OverlayProjectPicker: View {
    private let context = MeetingContextStore.shared
    private let control = MeetingControlCoordinator.shared
    @State private var hovering = false

    private var selectedName: String? {
        context.workstreamItem?.isProject == true ? context.workstreamName : nil
    }

    /// Recording with no project selected is the failure mode this control
    /// exists to prevent — surface it.
    private var unrouted: Bool { control.isRecording && selectedName == nil }

    var body: some View {
        let projects = VaultWorkstreamStore.projects()
        Menu {
            if projects.isEmpty {
                Text("No projects found in the vault")
            }
            ForEach(projects) { item in
                Button {
                    context.selectWorkstream(item)
                } label: {
                    if item.id == context.workstreamItem?.id {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
            if selectedName != nil {
                Divider()
                Button("No project") { context.clearWorkstream() }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: selectedName == nil ? "folder.badge.questionmark" : "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                if let name = selectedName {
                    Text(name)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 96, alignment: .leading)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, selectedName == nil ? 0 : 7)
            .frame(minWidth: 30)
            .frame(height: 28)
            .background(Capsule(style: .continuous).fill(background))
            .overlay(Capsule(style: .continuous).stroke(border, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight($hovering)
        .accessibilityLabel("Meeting project")
        .accessibilityValue(selectedName ?? "No project selected")
        .help(helpText)
    }

    private var tint: Color {
        if unrouted { return .orange }
        return selectedName == nil ? Color.overlayInk.opacity(0.52) : Color.blue.opacity(0.9)
    }

    private var background: Color {
        if unrouted { return Color.orange.opacity(0.12) }
        if selectedName != nil { return Color.blue.opacity(0.10) }
        return Color.overlayInk.opacity(hovering ? 0.08 : 0.045)
    }

    private var border: Color {
        if unrouted { return Color.orange.opacity(0.45) }
        if selectedName != nil { return Color.blue.opacity(0.30) }
        return Color.overlayInk.opacity(hovering ? 0.16 : 0.08)
    }

    private var helpText: String {
        if let name = selectedName {
            return "This recording files to \(name) — click to change"
        }
        return unrouted
            ? "Recording has NO project — pick one so it files itself"
            : "Pick the project this meeting belongs to"
    }
}

// MARK: - Record control

/// Sentinel is the default meeting path. RTI live intelligence is an explicit
/// escalation exposed by the companion button once the durable recording runs.
struct OverlayRecordButton: View {
    private let control = MeetingControlCoordinator.shared

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
        .disabled(control.isBusy)
        .hoverHighlight($hovering)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(helpText)
        .help(helpText)
    }

    private var accessibilityLabel: String {
        control.isRecording ? "Stop recording and process" : "Record meeting with Sentinel"
    }

    private func primaryAction() {
        control.toggleRecording()
    }

    @ViewBuilder
    private var glyph: some View {
        if control.isBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
                .frame(width: 9, height: 9)
        } else if control.isRecording {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(red: 1.0, green: 0.27, blue: 0.27))
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(Color(red: 1.0, green: 0.27, blue: 0.27).opacity(0.85))
                .frame(width: 7, height: 7)
        }
    }

    private var background: some View {
        ZStack {
            Capsule(style: .continuous).fill(Color.overlayInk.opacity(hovering ? 0.08 : 0.045))
            if control.isRecording {
                Capsule(style: .continuous).fill(Color(red: 1.0, green: 0.20, blue: 0.20).opacity(0.12))
            }
        }
    }

    private var borderColor: Color {
        control.isRecording
            ? Color(red: 1.0, green: 0.30, blue: 0.30).opacity(0.45)
            : Color.overlayInk.opacity(hovering ? 0.16 : 0.08)
    }

    private var helpText: String {
        if control.isBusy { return control.statusMessage ?? "Meeting Sentinel is working…" }
        return control.isRecording
            ? "Stop Sentinel recording and process the definitive transcript (⌘⇧R)"
            : "Record this meeting with Sentinel (⌘⇧R)"
    }
}

/// Small companion button beside the record control. Pause/resume while a
/// session is live; "open summary" once notes are ready. Only shown when it has
/// something to do, so the header stays uncluttered when idle.
struct OverlaySessionAuxButton: View {
    private let session = SessionCoordinator.shared
    private let control = MeetingControlCoordinator.shared
    @State private var hovering = false

    private enum Kind { case goLive, pause, resume, none }

    private var kind: Kind {
        switch session.phase {
        case .recording: .pause
        case .paused: .resume
        case .finishing, .summarizing: .none
        default: control.isRecording ? .goLive : .none
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
        case .goLive: "Go live with RTI"
        case .pause: "Pause recording"
        case .resume: "Resume recording"
        case .none: ""
        }
    }

    private var icon: String {
        switch kind {
        case .goLive: "sparkles"
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .none: ""
        }
    }

    private var tint: Color {
        switch kind {
        case .goLive: Color.blue.opacity(0.9)
        case .resume: Color.green.opacity(0.9)
        default: Color.overlayInk.opacity(0.7)
        }
    }

    private var help: String {
        switch kind {
        case .goLive: "Add RTI's provisional live transcript and intelligence"
        case .pause: "Pause RTI live intelligence (⌘⇧P); Sentinel keeps recording"
        case .resume: "Resume RTI live intelligence (⌘⇧P)"
        case .none: ""
        }
    }

    private func act() {
        switch kind {
        case .goLive: control.toggleLiveIntelligence()
        case .pause, .resume: session.togglePause()
        case .none: break
        }
    }
}
