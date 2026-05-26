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
                    Text(brief.title)
                        .font(.system(size: 12))
                        .lineLimit(2)
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
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: selected) { _, newValue in
            content = newValue.map(MeetingBriefStore.content) ?? ""
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No briefs found")
                .font(.system(size: 13, weight: .semibold))
            Text("Hermes' Meeting Prep job writes briefs into the vault. They'll appear here once generated.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
