import RTICore
import SwiftUI

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
