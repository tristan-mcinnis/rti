import SwiftUI

/// Tabbed hub view that hosts Live Transcript, Settings, and Logs. Ephemeral
/// build: there's no session library / corpus, so the only "Now" surface is
/// the live transcript.
struct SessionsControlView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case liveTranscript = "Live Transcript"
        case settings = "Settings"
        case logs = "Logs"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .liveTranscript: return "text.bubble.fill"
            case .settings:       return "gearshape.fill"
            case .logs:           return "doc.text.magnifyingglass"
            }
        }
    }

    @State private var selectedTab: Tab

    init(initialTab: Tab = .liveTranscript) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section("Now") {
                    sidebarRow(.liveTranscript)
                }
                Section("App") {
                    sidebarRow(.settings)
                    sidebarRow(.logs)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180)
            .safeAreaInset(edge: .bottom) {
                versionFooter
            }
        } detail: {
            contentForTab
                .safeAreaInset(edge: .top) {
                    SentinelMeetingBanner()
                }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                CommandPaletteSearchButton()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiShowLiveTranscript)) { _ in
            selectedTab = .liveTranscript
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiShowLogs)) { _ in
            selectedTab = .logs
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiSelectSessionsControlTab)) { notif in
            guard let tab = notif.object as? Tab else { return }
            selectedTab = tab
        }
    }

    private func sidebarRow(_ tab: Tab) -> some View {
        Label(tab.rawValue, systemImage: tab.icon)
            .tag(tab)
    }

    @ViewBuilder
    private var contentForTab: some View {
        switch selectedTab {
        case .liveTranscript:
            DebugConsoleView()
                .environment(SessionCoordinator.shared)

        case .settings:
            SettingsView(onClose: nil)

        case .logs:
            LogsView()
        }
    }

    /// Build / version footer pinned to the bottom of the sidebar.
    private var versionFooter: some View {
        VStack(spacing: 2) {
            Divider()
            Text(versionString)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "RTI \(v) (\(b))"
    }
}

/// Toolbar-resident search affordance that opens the command palette. Always
/// visible across every Sessions Control tab so search is never more than
/// one click (or ⌘K) away. Renders the "Search or ask anything…" pill —
/// purely a button; the actual query happens inside the palette.
@MainActor
private struct CommandPaletteSearchButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: openPalette) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Search or ask anything…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                HStack(spacing: 2) {
                    Text("⌘")
                    Text("K")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                )
            }
            .padding(.horizontal, 10)
            .frame(width: 360, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(isHovered ? 0.16 : 0.10))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Search sessions, actions, and settings (⌘K)")
        .keyboardShortcut("k", modifiers: .command)
    }

    private func openPalette() {
        NotificationCenter.default.post(name: .rtiToggleCommandPalette, object: nil)
    }
}

/// Slim banner shown while the external Meeting Sentinel tool is recording a
/// meeting (Step 1 of the RTI ⇄ Sentinel bridge). Collapses to nothing when
/// no meeting is live. Read-only awareness — no controls yet.
@MainActor
private struct SentinelMeetingBanner: View {
    @State private var monitor = MeetingSentinelMonitor.shared
    /// Ticks once a second so the elapsed time stays current.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if let meeting = monitor.liveMeeting {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Recording")
                    .font(.system(size: 12, weight: .semibold))
                Text(meeting.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(elapsedString(meeting.startedAt))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.red.opacity(0.10))
            .onReceive(tick) { now = $0 }
            .help("Meeting Sentinel is recording this meeting (\(meeting.audioFilePath))")
        }
    }

    private func elapsedString(_ start: Date) -> String {
        let total = Int(max(0, now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
