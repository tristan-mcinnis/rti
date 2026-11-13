import RTICore
import SwiftUI
import HouseDesign

// MARK: - Visual context control

/// What the eye menu's project rows do: set or clear the picked project's
/// own screenshot choice for one call type. They never touch the Settings
/// default (`ScreenshotPolicy.global`).
enum OverlayScreenshotChoice {
    @MainActor
    static func apply(_ mode: ScreenshotMode?, policy: ScreenshotPolicy, project: String, callType: CallType) {
        policy.setOverride(mode, project: project, callType: callType)
    }
}

/// The header's screenshot menu (2026-11-13). Each value has one home: the
/// default for every call is Settings > General (the menu names it and
/// links there), and the picked project's own choice for this call type is
/// set here and nowhere else. Shown before and during a call, so the project
/// choice can be set ahead of Record; "Auto" names automatic capture only
/// while it runs.
struct OverlayVisualContextButton: View {
    let isLive: Bool
    private let trail = VisualContextTrail.shared
    private let policy = ScreenshotPolicy.shared
    private let context = MeetingContextStore.shared
    private let callTypes = CallTypeStore.shared

    var body: some View {
        Menu {
            Section("Screenshots: \(policy.effective.title)") {
                Text(Self.defaultLine(policy.global))
                Button("Change Default in Settings…") { WindowCoordinator.shared.openSettings(pane: .general) }
            }
            if let project = policy.project {
                Section(Self.projectSectionTitle(project: context.workstreamName, callType: callTypes.active)) {
                    Button {
                        OverlayScreenshotChoice.apply(nil, policy: policy, project: project, callType: callTypes.active)
                    } label: {
                        checked("Use default (\(policy.global.title))", policy.projectOverride == nil)
                    }
                    ForEach(ScreenshotMode.allCases) { mode in
                        Button {
                            OverlayScreenshotChoice.apply(mode, policy: policy, project: project, callType: callTypes.active)
                        } label: {
                            checked(mode.title, policy.projectOverride == mode)
                        }
                    }
                }
                .disabled(policy.global == .off)
            } else {
                Text("Pick a project on Prepare to give it its own choice")
            }
            if trail.state == .permissionRequired {
                Button("Open Screen Recording Settings") { trail.openScreenRecordingSettings() }
            }
        } label: {
            SlateChip(stroked: true, emphasised: false) {
                Image(systemName: policy.effective == .off ? "eye.slash" : "eye")
                if isLive, policy.effective == .automatic {
                    Text(trail.state == .paused ? "Paused" : "Auto")
                }
            }
            .font(House.TypeToken.meta)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Screenshots")
        .accessibilityValue(status)
        .help("Screenshots: \(status). \(policy.project == nil ? "The default is in Settings." : "Set this project's own choice, or change the default in Settings.")")
    }

    /// The read-only default line: Settings owns it. When it is Off, it
    /// wins over every project's choice, and the line says so.
    static func defaultLine(_ global: ScreenshotMode) -> String {
        global == .off ? "Default: Off for every call (project choices wait)" : "Default: \(global.title)"
    }

    /// The project section's header: whose calls the choice covers.
    static func projectSectionTitle(project: String?, callType: CallType) -> String {
        let name = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "This project's \(callType.name) calls" : "\(name): \(callType.name) calls"
    }

    @ViewBuilder
    private func checked(_ title: String, _ isOn: Bool) -> some View {
        if isOn {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var status: String {
        if trail.state == .permissionRequired { return "Screen Recording permission required" }
        if trail.state == .failed { return trail.lastError ?? "Capture unavailable" }
        if isLive, trail.state == .paused { return "Automatic capture paused" }
        if policy.projectOverride != nil, policy.global != .off { return "\(policy.effective.title) for this project" }
        return policy.effective.title
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
        }
    }

    private var elapsedAccessibilityValue: String {
        guard chip.showsClock else { return "" }
        return TimeFormat.elapsed(session.elapsed(at: Date()))
    }

    private func primaryAction() {
        session.toggleSession()
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
/// session is live. Only shown when it has something to do, so the header stays uncluttered when idle.
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
