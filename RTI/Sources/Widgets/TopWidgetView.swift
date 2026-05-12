import SwiftUI

/// Recording-first pill anchored to the top-right corner of the screen.
///
/// • Click toggles recording. Idle shows a soft dot + "Record" label; while
///   recording, the pill paints a red wash, the dot pulses, and a live
///   monospaced timer ticks. After stop, the final duration is shown frozen
///   until the next session starts.
/// • Right-click reveals a context menu: start/stop, open the chat overlay
///   below the widget, or jump into the Sessions Control window.
/// • Smart Mode shows as a small green capsule next to the pill.
struct TopWidgetView: View {
    let actions: TopWidgetWindowController.Actions

    @ObservedObject private var coordinator = SessionCoordinator.shared
    @ObservedObject private var llm = LLMController.shared
    @ObservedObject private var modes = ModeStore.shared

    @State private var now = Date()
    @State private var hovering = false

    // Half-second tick keeps the displayed timer fresh without burning CPU
    // on a sub-second redraw — TimeFormat.elapsed quantises to seconds anyway.
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            pillButton
            if llm.smartMode {
                smartBadge
            }
        }
        .padding(4)
        .onReceive(tick) { _ in
            if coordinator.isRunning { now = Date() }
        }
    }

    // MARK: - Pill

    private var pillButton: some View {
        Button(action: { coordinator.toggleSession() }) {
            HStack(spacing: 7) {
                indicatorDot
                primaryLabel
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(pillBackground)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(coordinator.isRunning
              ? "Click to stop recording • Right-click for menu"
              : "Click to record • Right-click for menu")
        .contextMenu { menuContents }
    }

    @ViewBuilder
    private var indicatorDot: some View {
        if coordinator.isRunning {
            PulsingRedDot()
        } else {
            Circle()
                .fill(Color.white.opacity(coordinator.endedAt != nil ? 0.30 : 0.50))
                .frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private var primaryLabel: some View {
        if coordinator.isRunning {
            DotMatrixText(text: elapsedLabel,
                          dot: 1.4,
                          spacing: 0.6,
                          gap: 1.4,
                          color: .white,
                          dim: Color.white.opacity(0.08))
        } else if let frozen = postRecordingLabel {
            DotMatrixText(text: frozen,
                          dot: 1.4,
                          spacing: 0.6,
                          gap: 1.4,
                          color: Color.white.opacity(0.55),
                          dim: Color.white.opacity(0.06))
        } else {
            Text("Record")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .kerning(0.2)
        }
    }

    private var smartBadge: some View {
        Text("Smart")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(red: 0.0, green: 0.733, blue: 0.498))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color(red: 0.0, green: 0.733, blue: 0.498).opacity(0.14))
            )
    }

    private var pillBackground: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(coordinator.isRunning ? 0.78 : 0.65))
            if coordinator.isRunning {
                Capsule(style: .continuous)
                    .fill(Color(red: 1.0, green: 0.20, blue: 0.20).opacity(0.16))
            }
        }
    }

    private var borderColor: Color {
        if coordinator.isRunning {
            return Color(red: 1.0, green: 0.30, blue: 0.30).opacity(0.45)
        }
        return Color.white.opacity(hovering ? 0.20 : 0.10)
    }

    private var elapsedLabel: String {
        guard let started = coordinator.startedAt else { return "0:00" }
        return TimeFormat.elapsed(now.timeIntervalSince(started))
    }

    private var postRecordingLabel: String? {
        guard let started = coordinator.startedAt, let ended = coordinator.endedAt else { return nil }
        return TimeFormat.elapsed(ended.timeIntervalSince(started))
    }

    // MARK: - Right-click menu

    /// Right-click menu items. Mirrors the menubar so the widget is a
    /// one-stop entry point: session controls, navigation, modes, recents,
    /// state toggles, then settings/help/quit.
    @ViewBuilder
    private var menuContents: some View {
        Button(coordinator.isRunning ? "Stop Recording" : "Start Recording") {
            coordinator.toggleSession()
        }
        Button(coordinator.isRunning || coordinator.endedAt != nil
               ? "View Session Detail"
               : "View Session Detail (no active session)") {
            actions.onOpenCurrentSessionDetail()
        }
        .disabled(coordinator.currentSessionId == nil && coordinator.endedAt == nil)

        Divider()

        Button("Show Chat Panel  ⌘\\") { actions.onToggleOverlay() }
        Button("Live Transcript  ⌘⌥T") { actions.onShowLiveTranscript() }
        Button("Sessions…  ⌘⇧S") { actions.onShowSessionHistory() }
        Button("Logs") { actions.onShowLogs() }

        recentSessionsMenu

        Divider()

        Button("Capture Screen  ⌘⇧H") { actions.onCaptureScreen() }
        Button("Clear Current Chat") { actions.onClearChat() }

        Divider()

        Button(llm.smartMode ? "Disable Smart Mode" : "Enable Smart Mode") {
            llm.smartMode.toggle()
        }
        Button(invisibilityIsOn ? "Show on Screen Capture" : "Hide from Screen Capture") {
            actions.onToggleInvisibility()
        }

        modesMenu

        Divider()

        Button("Settings…  ⌘,") { actions.onOpenSettings() }
        Button("Keyboard Shortcuts…") { actions.onShowShortcuts() }
        Button("About RTI") { actions.onShowAbout() }

        Divider()

        Button("Quit RTI") { actions.onQuit() }
    }

    /// Modes submenu — mirrors the menubar's mode picker. Active mode is
    /// checkmarked; tap any other to switch immediately.
    @ViewBuilder
    private var modesMenu: some View {
        Menu("Modes") {
            ForEach(modes.modes) { mode in
                Button {
                    modes.activeModeId = mode.id
                } label: {
                    if mode.id == modes.activeModeId {
                        Label(mode.name, systemImage: "checkmark")
                    } else {
                        Text(mode.name)
                    }
                }
            }
        }
    }

    /// Recent sessions submenu. Lazy-loads the last 10 the first time the
    /// user opens the context menu (and on subsequent opens; SwiftUI rebuilds
    /// the menu each time, so this is cheap).
    @ViewBuilder
    private var recentSessionsMenu: some View {
        Menu("Recent Sessions") {
            let sessions = SessionCoordinator.shared.recentSessions(limit: 10)
            if sessions.isEmpty {
                Button("No sessions yet") {}.disabled(true)
            } else {
                let currentId = coordinator.currentSessionId
                let fmt: DateFormatter = {
                    let f = DateFormatter()
                    f.dateStyle = .short
                    f.timeStyle = .short
                    return f
                }()
                ForEach(sessions, id: \.id) { s in
                    let label = "\(fmt.string(from: s.startedAt))\(s.id == currentId ? "  •" : "")"
                    Button(label) {
                        NotificationCenter.default.post(name: .openSessionDetail, object: s.id)
                    }
                }
            }
        }
    }

    /// Mirror the same key (`rti.invisible`) AppDelegate uses, defaulting to
    /// the same `true` so the menu label tracks runtime state without
    /// reaching back through closures.
    private var invisibilityIsOn: Bool {
        UserDefaults.standard.object(forKey: "rti.invisible") as? Bool ?? true
    }
}

/// Self-contained pulsing red indicator. Owns its animation state so each
/// time the parent shows it (i.e. each new recording), the oscillation
/// restarts cleanly via onAppear → withAnimation(repeatForever).
private struct PulsingRedDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.27, blue: 0.27))
            .frame(width: 8, height: 8)
            .shadow(color: Color(red: 1.0, green: 0.27, blue: 0.27).opacity(on ? 0.85 : 0.20),
                    radius: on ? 4 : 1)
            .scaleEffect(on ? 1.0 : 0.65)
            .opacity(on ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}
