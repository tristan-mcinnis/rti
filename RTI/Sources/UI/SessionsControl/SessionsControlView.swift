import SwiftUI

/// RTI's durable workspace: completed meetings, preferences, and diagnostics.
/// The live transcript intentionally lives only in the overlay, avoiding two
/// competing places to follow an active meeting.
struct SessionsControlView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case providers = "Providers"
        case general = "General"
        case logs = "Logs"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .sessions:       return "clock.arrow.circlepath"
            case .providers:      return "server.rack"
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
            sidebarSection("Preferences", tabs: [.providers, .general])
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

