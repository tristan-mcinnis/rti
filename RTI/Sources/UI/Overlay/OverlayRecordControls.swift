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

/// Optional project context. Unclassified meetings remain valid and flow into
/// the same meeting library and Neon index without a project declaration.
struct OverlayProjectPicker: View {
    private let context = MeetingContextStore.shared
    @State private var hovering = false

    private var selectedName: String? {
        context.workstreamItem?.isProject == true ? context.workstreamName : nil
    }

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
        return selectedName == nil ? Color.overlayInk.opacity(0.52) : Color.blue.opacity(0.9)
    }

    private var background: Color {
        if selectedName != nil { return Color.blue.opacity(0.10) }
        return Color.overlayInk.opacity(hovering ? 0.08 : 0.045)
    }

    private var border: Color {
        if selectedName != nil { return Color.blue.opacity(0.30) }
        return Color.overlayInk.opacity(hovering ? 0.16 : 0.08)
    }

    private var helpText: String {
        if let name = selectedName {
            return "This recording files to \(name) — click to change"
        }
        return "Optionally file this meeting to a project"
    }
}

// MARK: - Record control

/// RTI is the single recording path: live transcript now, improved transcript
/// and notes automatically after Finish.
struct OverlayRecordButton: View {
    private let session = SessionCoordinator.shared

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
        .disabled(session.phase == .finishing)
        .hoverHighlight($hovering)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(helpText)
        .help(helpText)
    }

    private var accessibilityLabel: String {
        switch session.phase {
        case .idle, .done: "Start recording"
        case .recording, .paused: "Finish recording"
        case .finishing, .summarizing: "Processing recording"
        }
    }

    private func primaryAction() {
        if session.phase == .done, let url = session.summaryURL {
            WindowCoordinator.shared.showSession(folder: url.deletingLastPathComponent().lastPathComponent)
        } else {
            session.toggleSession()
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if session.phase == .finishing || session.phase == .summarizing {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
                .frame(width: 9, height: 9)
        } else if session.phase == .recording || session.phase == .paused {
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
            if session.phase == .recording || session.phase == .paused {
                Capsule(style: .continuous).fill(Color(red: 1.0, green: 0.20, blue: 0.20).opacity(0.12))
            }
        }
    }

    private var borderColor: Color {
        (session.phase == .recording || session.phase == .paused)
            ? Color(red: 1.0, green: 0.30, blue: 0.30).opacity(0.45)
            : Color.overlayInk.opacity(hovering ? 0.16 : 0.08)
    }

    private var helpText: String {
        switch session.phase {
        case .idle: "Start recording (⌘⇧R)"
        case .recording, .paused: "Finish recording and improve transcript (⌘⇧R)"
        case .finishing: "Saving audio…"
        case .summarizing: session.postProcessingStatus ?? "Improving transcript…"
        case .done: session.summaryURL == nil ? "Session saved" : "Notes ready"
        }
    }
}

/// Small companion button beside the record control. Pause/resume while a
/// session is live; "open summary" once notes are ready. Only shown when it has
/// something to do, so the header stays uncluttered when idle.
struct OverlaySessionAuxButton: View {
    private let session = SessionCoordinator.shared
    @State private var hovering = false

    private enum Kind { case pause, resume, none }

    private var kind: Kind {
        switch session.phase {
        case .recording: .pause
        case .paused: .resume
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
        case .none: ""
        }
    }

    private var icon: String {
        switch kind {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .none: ""
        }
    }

    private var tint: Color {
        switch kind {
        case .resume: Color.green.opacity(0.9)
        default: Color.overlayInk.opacity(0.7)
        }
    }

    private var help: String {
        switch kind {
        case .pause: "Pause recording (⌘⇧P)"
        case .resume: "Resume recording (⌘⇧P)"
        case .none: ""
        }
    }

    private func act() {
        switch kind {
        case .pause, .resume: session.togglePause()
        case .none: break
        }
    }
}
