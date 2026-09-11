import SwiftUI

/// RTI's preferences and diagnostics window (Providers, Modes, Prompts,
/// Glossary, Voices, General, Logs).
///
/// Shim during the house-style migration: past sessions moved to their own
/// window (`SessionsWindowController`), so this window no longer lists them.
/// `Tab.sessions` stays so existing callers compile; `WindowCoordinator`
/// sends it to the Sessions window. The settings shell (`SettingsView` in
/// `SettingsWindowController`) replaces this window when it lands.
struct SessionsControlView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case providers = "Providers"
        case modes = "Modes"
        case prompts = "Prompts"
        case glossary = "Glossary"
        case voices = "Voices"
        case general = "General"
        case logs = "Logs"

        var id: String { rawValue }

        enum Section { case meetings, preferences, support }

        var section: Section {
            switch self {
            case .sessions:                                        return .meetings
            case .providers, .modes, .prompts, .glossary, .voices, .general: return .preferences
            case .logs:                                            return .support
            }
        }

        var icon: String {
            switch self {
            case .sessions:       return "clock.arrow.circlepath"
            case .providers:      return "server.rack"
            case .modes:          return "square.stack.3d.up"
            case .prompts:        return "text.bubble"
            case .glossary:       return "character.book.closed"
            case .voices:         return "person.wave.2.fill"
            case .general:        return "gearshape.fill"
            case .logs:           return "doc.text.magnifyingglass"
            }
        }
    }

    @State private var selectedTab: Tab

    init(initialTab: Tab = .providers) {
        _selectedTab = State(initialValue: initialTab == .sessions ? .providers : initialTab)
    }

    var body: some View {
        NavigationSplitView {
            sessionsSidebar
        } detail: {
            // .id forces a full teardown/rebuild of the detail subtree per tab.
            // Without it, ScrollView-rooted tabs (Providers/Glossary/General/
            // Logs) mounted in the AX tree but never painted when swapped in —
            // only NSTableView-backed Lists (Modes/Prompts) rendered (2026-08-30).
            contentForTab
                .id(selectedTab)
        }
        // Chrome is ink, never the system accent; toggles are ink too.
        .tint(RTIDesign.Color.textPrimary)
        .toggleStyle(SlateToggleStyle())
        .background(RTIDesign.Color.appBackground)
        .onReceive(NotificationCenter.default.publisher(for: .rtiShowLogs)) { _ in
            selectedTab = .logs
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiSelectSessionsControlTab)) { notif in
            guard let tab = notif.object as? Tab, tab != .sessions else { return }
            selectedTab = tab
        }
    }

    private var sessionsSidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: RTIDesign.Spacing.xs + 2) {
                SlateIconTile(systemName: "waveform", size: RTIDesign.Control.chip, glyphSize: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text("RTI")
                        .font(RTIDesign.Font.label)
                        .foregroundStyle(RTIDesign.Color.textPrimary)
                    SlateSectionLabel(text: "Preferences")
                }
            }
            .padding(.horizontal, RTIDesign.Spacing.md)
            .padding(.top, RTIDesign.Spacing.md)

            // Derived from Tab.allCases so a newly added tab can never be
            // silently missing from the sidebar (bitten 2026-08-30: Voices
            // existed in the enum + content switch but not in this list).
            sidebarSection("Preferences", tabs: Tab.allCases.filter { $0.section == .preferences })
            sidebarSection("Support", tabs: Tab.allCases.filter { $0.section == .support })

            Spacer(minLength: 0)
            versionFooter
        }
        .frame(minWidth: 196, idealWidth: RTIDesign.Layout.settingsRail, maxWidth: 232,
               maxHeight: .infinity, alignment: .topLeading)
        .background(RTIDesign.Color.trackBackground)
    }

    private func sidebarSection(_ title: String, tabs: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SlateSectionLabel(text: title)
                .padding(.horizontal, RTIDesign.Spacing.md)

            VStack(spacing: RTIDesign.Spacing.xxs - 1) {
                ForEach(tabs) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: RTIDesign.Spacing.sm) {
                            SlateIconTile(systemName: tab.icon, glyphSize: 13)
                            Text(tab.rawValue)
                                .font(RTIDesign.Font.label)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selectedTab == tab ? RTIDesign.Color.textPrimary : RTIDesign.Color.textSecondary)
                        .padding(.horizontal, RTIDesign.Spacing.xs + 2)
                        .frame(height: RTIDesign.Control.railRow)
                        .slateRaisedTile(selectedTab == tab, cornerRadius: RTIDesign.Radius.row)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTab == tab ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, RTIDesign.Spacing.sm)
        }
    }

    @ViewBuilder
    private var contentForTab: some View {
        switch selectedTab {
        case .sessions, .providers:
            ProvidersTab()
        case .modes:
            ModesTab()
        case .prompts:
            PromptsTab()
        case .glossary:
            GlossaryTab()
        case .voices:
            VoicesTab()
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
                .font(RTIDesign.Font.micro)
                .foregroundStyle(RTIDesign.Color.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RTIDesign.Spacing.md)
                .padding(.bottom, RTIDesign.Spacing.xs + 2)
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "RTI \(v) (\(b))"
    }
}
