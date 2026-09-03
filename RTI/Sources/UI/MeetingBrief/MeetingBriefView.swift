import SwiftUI

/// Browses the vault's pre-meeting briefs (authored by Hermes "Meeting Prep")
/// for on-demand review. List of recent briefs on the left, rendered Markdown
/// on the right. Read-only — RTI never writes briefs.
struct MeetingBriefView: View {
    @State private var briefs: [MeetingBrief] = []
    @State private var selected: MeetingBrief?
    @State private var content: String = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                ForEach(briefs) { brief in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(brief.displayTitle)
                            .font(RTIDesign.Font.label)
                            .lineLimit(2)
                        if let date = brief.datePrefix {
                            Text(date).font(RTIDesign.Font.micro).foregroundStyle(RTIDesign.Color.textSecondary)
                        }
                    }
                    .tag(brief)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 240)
            .overlay {
                if briefs.isEmpty { emptyState }
            }
            .toolbar {
                ToolbarItem {
                    Button(action: reload) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload briefs from the vault")
                }
            }
        } detail: {
            ScrollView {
                RTIMarkdown(content, style: .panel)
                    .padding(RTIDesign.Spacing.lg - 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RTIDesign.Color.appBackground)
        }
        .background(RTIDesign.Color.appBackground)
        // Chrome is ink, never the system accent.
        .tint(RTIDesign.Color.textPrimary)
        .onAppear(perform: reload)
        .onChange(of: selected) { _, newValue in
            content = newValue.map(MeetingBriefStore.content) ?? ""
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: House.TypeToken.Size.display, weight: .regular))
                .foregroundStyle(RTIDesign.Color.textTertiary)
            Text("No briefs found")
                .font(RTIDesign.Font.label)
            Text("Hermes' Meeting Prep job writes briefs into the vault. They'll appear here once generated.")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private func reload() {
        briefs = MeetingBriefStore.recentBriefs()
        if selected == nil || !briefs.contains(where: { $0 == selected }) {
            selected = briefs.first
        }
        content = selected.map(MeetingBriefStore.content) ?? ""
    }
}
