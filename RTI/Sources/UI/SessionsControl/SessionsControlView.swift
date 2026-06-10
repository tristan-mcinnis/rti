import SwiftUI

/// Tabbed hub view that hosts Live Transcript, Settings, and Logs. Ephemeral
/// build: there's no session library / corpus, so the only "Now" surface is
/// the live transcript.
struct SessionsControlView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case liveTranscript = "Live Transcript"
        case sessions = "Sessions"
        case settings = "Settings"
        case logs = "Logs"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .liveTranscript: return "text.bubble.fill"
            case .sessions:       return "clock.arrow.circlepath"
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
                Section("Library") {
                    sidebarRow(.sessions)
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
            LiveTranscriptView()
                .environment(SessionCoordinator.shared)

        case .sessions:
            SessionsBrowserView()

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

/// Slim banner shown while the external Meeting Sentinel tool is recording a
/// meeting (Step 1 of the RTI ⇄ Sentinel bridge). Collapses to nothing when
/// no meeting is live. Read-only awareness — no controls yet.
@MainActor
private struct SentinelMeetingBanner: View {
    @State private var monitor = MeetingSentinelMonitor.shared
    @State private var session = SessionCoordinator.shared
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
                Button("Brief") { WindowCoordinator.shared.showMeetingBrief() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Review the pre-meeting brief for this meeting")
                goLiveControl(meeting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.red.opacity(0.10))
            .onReceive(tick) { now = $0 }
            .help("Meeting Sentinel is recording this meeting (\(meeting.audioFilePath))")
        }
    }

    /// Right-hand control: "Go live" to overlay RTI's live intelligence on the
    /// meeting Sentinel is recording, or a live indicator once RTI is running.
    @ViewBuilder
    private func goLiveControl(_ meeting: SentinelMeeting) -> some View {
        if session.isRunning {
            Label("RTI live", systemImage: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Button {
                SessionCoordinator.shared.startSession(linkedTo: meeting)
                WindowCoordinator.shared.showOverlay()
            } label: {
                Text("Go live")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.red)
            .help("Start RTI's live transcript + assist overlay for this meeting")
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
