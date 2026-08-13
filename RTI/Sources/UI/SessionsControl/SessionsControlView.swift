import SwiftUI

/// RTI's durable workspace: completed meetings, preferences, and diagnostics.
/// The live transcript intentionally lives only in the overlay, avoiding two
/// competing places to follow an active meeting.
struct SessionsControlView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case providers = "Providers"
        case modes = "Modes"
        case prompts = "Prompts"
        case glossary = "Glossary"
        case general = "General"
        case logs = "Logs"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .sessions:       return "clock.arrow.circlepath"
            case .providers:      return "server.rack"
            case .modes:          return "square.stack.3d.up"
            case .prompts:        return "text.bubble"
            case .glossary:       return "character.book.closed"
            case .general:        return "gearshape.fill"
            case .logs:           return "doc.text.magnifyingglass"
            }
        }
    }

    @State private var selectedTab: Tab

    init(initialTab: Tab = .sessions) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView {
            sessionsSidebar
        } detail: {
            contentForTab
                .safeAreaInset(edge: .top) {
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiShowLogs)) { _ in
            selectedTab = .logs
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiSelectSessionsControlTab)) { notif in
            guard let tab = notif.object as? Tab else { return }
            selectedTab = tab
        }
    }

    private var sessionsSidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(RTIDesign.Color.accentBg)
                        .frame(width: 36, height: 36)
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RTIDesign.Color.accentText)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("RTI")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Library & preferences")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RTIDesign.Color.textSecondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)

            sidebarSection("Meetings", tabs: [.sessions])
            sidebarSection("Preferences", tabs: [.providers, .modes, .prompts, .glossary, .general])
            sidebarSection("Support", tabs: [.logs])

            Spacer(minLength: 0)
            versionFooter
        }
        .frame(minWidth: 196, idealWidth: 212, maxWidth: 232, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func sidebarSection(_ title: String, tabs: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(RTIDesign.Color.textTertiary)
                .padding(.horizontal, 18)

            VStack(spacing: 4) {
                ForEach(tabs) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 18)
                            Text(tab.rawValue)
                                .font(.system(size: 14, weight: selectedTab == tab ? .semibold : .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selectedTab == tab ? RTIDesign.Color.textPrimary : RTIDesign.Color.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selectedTab == tab ? RTIDesign.Color.cardBackground : Color.clear)
                                .shadow(
                                    color: selectedTab == tab ? .black.opacity(0.05) : .clear,
                                    radius: 3,
                                    y: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private var contentForTab: some View {
        switch selectedTab {
        case .sessions:
            SessionsBrowserView()

        case .providers:
            ProvidersTab()
        case .modes:
            ModesTab()
        case .prompts:
            PromptsTab()
        case .glossary:
            GlossaryTab()
        case .general:
            GeneralTab()

        case .logs:
            LogsView()
        }
    }

    /// Build / version footer pinned to the bottom of the sidebar.
    private var versionFooter: some View {
        VStack(spacing: 6) {
            Divider()
            Text(versionString)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
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
    // No Combine timer — the per-instance Timer.publish subscription pattern
    // segfaulted in OverlayRecordButton (stale SubscriptionView on teardown);
    // the elapsed label uses TimelineView so SwiftUI owns the clock.

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
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedString(meeting.startedAt, now: context.date))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
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

    private func elapsedString(_ start: Date, now: Date) -> String {
        let total = Int(max(0, now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
