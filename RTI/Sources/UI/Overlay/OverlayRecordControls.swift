import RTICore
import SwiftUI

// MARK: - Visual context control

/// Quiet but explicit ambient-capture state. It appears only while a session
/// is live: Littlebird's low-friction context should never become invisible
/// surveillance. One click stops or resumes the screen trail immediately.
struct OverlayVisualContextButton: View {
    /// Capture is running (the header's phase).
    let isLive: Bool

    private let session = SessionCoordinator.shared
    private let trail = VisualContextTrail.shared
    @State private var hovering = false

    var body: some View {
        if isLive {
            Button(action: act) {
                SlateChip(stroked: true, emphasised: false) {
                    Image(systemName: icon)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(tint)
                }
                .slateRaisedTile(false, cornerRadius: House.Radius.sm, hovering: hovering)
            }
            .buttonStyle(.plain)
            .hoverHighlight($hovering)
            .accessibilityLabel("Screen context")
            .accessibilityValue(statusText)
            .accessibilityHint(actionHint)
            .help("\(statusText). \(actionHint).")
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

    /// Status is the only chroma a chip may carry, and it is paired with the
    /// accessibility value + tooltip, never colour alone.
    private var tint: Color {
        switch trail.state {
        case .permissionRequired, .failed, .paused: House.ColorToken.warning
        case .disabled: Color.overlayInkTertiary
        default: Color.overlayInkSecondary
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
    /// The widest the project name draws in the chip before it truncates.
    /// Not a token yet: half the chat rail.
    private static let nameMaxWidth = House.Layout.chatRail / 2

    /// The header allows the name before a recording, at its standard
    /// width; not at 600 and not while capture runs.
    var allowsName = true

    private let context = MeetingContextStore.shared
    @State private var hovering = false

    private var selectedName: String? {
        context.workstreamItem?.isProject == true ? context.workstreamName : nil
    }

    /// The header title already shows the project when no calendar event is
    /// picked; the chip then draws its glyph only (the name stays in the
    /// tooltip and for VoiceOver).
    private var showsName: Bool {
        guard allowsName, selectedName != nil else { return false }
        let calendarTitle = context.calendarMeeting?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !calendarTitle.isEmpty
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
            SlateChip(emphasised: selectedName != nil) {
                Image(systemName: selectedName == nil ? "folder.badge.questionmark" : "folder.fill")
                    .font(House.TypeToken.meta)
                if showsName, let name = selectedName {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: Self.nameMaxWidth, alignment: .leading)
                }
            }
            .slateRaisedTile(false, cornerRadius: House.Radius.sm, hovering: hovering)
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

    private var helpText: String {
        if let name = selectedName {
            return "This recording files to \(name). Click to change."
        }
        return "File this meeting to a project (optional)"
    }
}

// MARK: - Record control

/// The header's one live action (chat-surfaces.md section 8): a labelled chip
/// with its key caps. While capture runs it carries the registered recording
/// chip, a `danger` mark plus the captured-time clock, the only chroma on
/// screen. RTI is the single recording path: live transcript now, improved
/// transcript and notes automatically after Finish.
struct OverlayRecordButton: View {
    let status: OverlayShellStatus
    /// The action's word ("Finish"). The header drops it for a live chip
    /// at the minimum width; it stays in the help and for VoiceOver.
    var showsTitle = true
    /// The key caps. The header drops them at the minimum width and while
    /// the clock shows; the key stays in the help text.
    var showsKeys = true

    private let session = SessionCoordinator.shared
    @State private var hovering = false

    private var chip: OverlayRecordChip { status.recordChip }

    var body: some View {
        Button(action: primaryAction) {
            HStack(spacing: House.Spacing.xs) {
                lead
                if chip.showsClock {
                    OverlayRecordClock()
                }
                if showsTitle {
                    Text(chip.title)
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if showsKeys, !chip.keys.isEmpty {
                    KeyCapGroup(keys: chip.keys)
                }
            }
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: House.Control.chip)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .fill(hovering && chip.isEnabled ? House.ColorToken.hoverFill : House.ColorToken.chipFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!chip.isEnabled)
        .hoverHighlight($hovering)
        .accessibilityLabel(chip.accessibilityLabel)
        .accessibilityValue(elapsedAccessibilityValue)
        .accessibilityHint(chip.help)
        .help(chip.help)
    }

    @ViewBuilder
    private var lead: some View {
        switch chip.lead {
        case .recordDot:
            SlateStatusDot(color: House.ColorToken.danger, size: House.Spacing.xs)
        case .liveMark:
            RoundedRectangle(cornerRadius: House.Radius.xs / 2, style: .continuous)
                .fill(House.ColorToken.danger)
                .frame(width: House.Spacing.xs, height: House.Spacing.xs)
                .accessibilityHidden(true)
        case .spinner:
            ProgressView()
                .controlSize(.mini)
                .frame(width: House.Spacing.md, height: House.Spacing.md)
        case let .glyph(name):
            Image(systemName: name)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textSecondary)
        }
    }

    private var elapsedAccessibilityValue: String {
        guard chip.showsClock else { return "" }
        return TimeFormat.elapsed(session.elapsed(at: Date()))
    }

    private func primaryAction() {
        if status.phase == .done, status.summaryReady, let url = session.summaryURL {
            WindowCoordinator.shared.showSession(folder: url.deletingLastPathComponent().lastPathComponent)
        } else {
            session.toggleSession()
        }
    }
}

/// The captured-time clock. Its one-second tick lives in this small leaf so
/// it never re-renders the header around it.
private struct OverlayRecordClock: View {
    private let session = SessionCoordinator.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(TimeFormat.elapsed(session.elapsed(at: context.date)))
                .font(House.TypeToken.label)
                .monospacedDigit()
                .foregroundStyle(House.ColorToken.textPrimary)
        }
    }
}

/// Small companion button beside the record control. Pause/resume while a
/// session is live; "open summary" once notes are ready. Only shown when it has
/// something to do, so the header stays uncluttered when idle.
struct OverlaySessionAuxButton: View {
    /// The header's phase.
    let phase: OverlayLivePhase

    private let session = SessionCoordinator.shared
    @State private var hovering = false

    private enum Kind { case pause, resume, none }

    private var kind: Kind {
        switch phase {
        case .recording: .pause
        case .paused: .resume
        default: .none
        }
    }

    var body: some View {
        if kind != .none {
            Button(action: act) {
                SlateChip {
                    Image(systemName: icon)
                        .font(.system(size: House.TypeToken.Size.caption, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .slateRaisedTile(false, cornerRadius: House.Radius.sm, hovering: hovering)
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
        case .resume: House.ColorToken.success
        default: Color.overlayInkSecondary
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
