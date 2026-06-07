import SwiftUI

/// One place to ground the assistant in *this* meeting: a quick editable
/// context note (who/what/status — fed to the LLM, never saved) plus the
/// pre-meeting brief from your Hermes vault if one exists. Stays true to the
/// ephemeral fork — no projects, no persistence.
struct ContextPanelView: View {
    @State private var briefs: [MeetingBrief] = []
    @State private var selected: MeetingBrief?
    @State private var briefContent: String = ""

    var body: some View {
        FloatingPanelChrome(
            title: "Context",
            opacityKey: contextPanelOpacityKey,
            defaultOpacity: floatingPanelDefaultOpacity,
            panelID: .context
        ) {
            VStack(alignment: .leading, spacing: 10) {
                contextEditor
                Divider()
                briefSection
            }
            .padding(16)
            .onAppear(perform: loadBriefs)
        }
    }

    // MARK: - Editable meeting context

    private var contextEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What's this meeting about?")
                .font(.system(size: 13, weight: .semibold))
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { MeetingContextStore.shared.context },
                    set: { MeetingContextStore.shared.context = $0 }
                ))
                .font(.system(size: 12))
                .frame(height: 84)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10)))
                if MeetingContextStore.shared.context.isEmpty {
                    Text("e.g. Client: Acme. Project: Q3 launch — behind schedule. Goal: agree a new date.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            Text("Fed to the assistant so its suggestions are grounded. Held in memory only — never saved.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pre-meeting brief

    @ViewBuilder
    private var briefSection: some View {
        HStack {
            Text("Pre-meeting brief")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if briefs.count > 1 {
                Picker("", selection: $selected) {
                    ForEach(briefs) { brief in
                        Text(brief.title).tag(Optional(brief))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .onChange(of: selected) { _, new in
                    briefContent = new.map(MeetingBriefStore.content) ?? ""
                }
            }
        }
        if briefs.isEmpty {
            Text("No brief found. Hermes' Meeting Prep job writes these to your vault before a call.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView {
                RTIMarkdown(briefContent, style: .panel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func loadBriefs() {
        briefs = MeetingBriefStore.recentBriefs()
        selected = briefs.first
        briefContent = selected.map(MeetingBriefStore.content) ?? ""
    }
}
