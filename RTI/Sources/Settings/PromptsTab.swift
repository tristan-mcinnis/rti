import RTICore
import SwiftUI
import UniformTypeIdentifiers
import HouseDesign

// MARK: - Prompts

/// Settings tab that surfaces every tunable prompt (`PromptID`) for editing,
/// with per-prompt and global "reset to defaults". Edits persist in
/// `PromptStore`; the running app reads them on the next call.
struct PromptsTab: View {
    @Bindable var draft: PromptSettingsDraft
    @State private var showResetAllConfirm = false
    private var store = PromptStore.shared

    init(draft: PromptSettingsDraft = PromptSettingsDraft()) { self.draft = draft }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: House.Spacing.xs) {
                libraryHeader
                    .padding(.horizontal, House.Spacing.sm)
                    .padding(.top, House.Spacing.sm)

                promptList
            }
            .frame(minWidth: 230, idealWidth: 250, maxWidth: 310)
            .background(RTIDesign.Color.trackBackground)

            PromptEditorView(id: draft.selection, draft: draft)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsSurfaceBackground())
        }
    }

    /// The pane's title and caption come from the shared Settings header,
    /// so this column carries only the library label and its one action.
    private var libraryHeader: some View {
        HStack(spacing: House.Spacing.xs) {
            Text("Prompt Library")
                .font(.system(size: House.TypeToken.Size.meta, weight: .semibold))
                .foregroundStyle(RTIDesign.Color.textSecondary)
            Spacer()
            if store.hasAnyOverride {
                SettingsStatusLabel(text: "Edited", systemImage: "pencil.circle.fill", color: RTIDesign.Color.textSecondary)
            }
            Button("Reset All", role: .destructive) { showResetAllConfirm = true }
                .controlSize(.small)
                .disabled(!store.hasAnyOverride)
                .confirmationDialog(
                    "Reset every prompt to its shipped default? Your edits will be lost.",
                    isPresented: $showResetAllConfirm, titleVisibility: .visible
                ) {
                    Button("Reset all prompts", role: .destructive) { store.resetAll(); draft.resetAll(read: store.text) }
                    Button("Cancel", role: .cancel) {}
                }
        }
    }

    private var promptList: some View {
        List(selection: $draft.selection) {
            ForEach(PromptID.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(PromptID.allCases.filter { $0.group == group }, id: \.self) { id in
                        HStack(spacing: 6) {
                            Text(id.title)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if store.defaultChangedSinceEdit(id) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(RTIDesign.Color.warning)
                                    .help("The shipped default changed since you edited this.")
                            } else if store.isOverridden(id) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(RTIDesign.Color.textSecondary)
                                    .help("Edited — overrides the default.")
                            }
                        }
                        .tag(id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

}

/// The editor pane for a single prompt: a local buffer with Save / Revert /
/// Reset, a live warning when an edit drops a required token, and (for the
/// composed recap leaves) a preview of the fully assembled prompt.
private struct PromptEditorView: View {
    let id: PromptID
    @Bindable var draft: PromptSettingsDraft
    private var text: String { draft.texts[id] ?? store.text(id) }
    private var store = PromptStore.shared

    init(id: PromptID, draft: PromptSettingsDraft) {
        self.id = id
        self.draft = draft
    }

    private var textBinding: Binding<String> {
        Binding(get: { text }, set: { draft.texts[id] = $0 })
    }

    private var isDirty: Bool {
        text != store.text(id)
    }

    private var warnings: [String] {
        store.warnings(for: id, candidate: text)
    }

    var body: some View {
        SettingsPage(maxWidth: 820) {
            VStack(alignment: .leading, spacing: House.Spacing.xl) {
                SettingsCard(id.title, detail: id.help) {
                    VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                        if store.defaultChangedSinceEdit(id) {
                            SettingsStatusLabel(text: "The shipped default changed since you edited this.", systemImage: "exclamationmark.triangle.fill", color: RTIDesign.Color.warning)
                        }

                        TextEditor(text: textBinding)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 280)
                            .settingsEditorBorder()

                        ForEach(warnings, id: \.self) { w in
                            SettingsStatusLabel(text: w, systemImage: "exclamationmark.octagon.fill", color: RTIDesign.Color.danger)
                        }
                    }
                }

                if let assembled = assembledPreview {
                    SettingsCard("Preview Assembled Prompt") {
                        Text(assembled)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(RTIDesign.Color.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: House.Spacing.xs) {
                    if store.isOverridden(id) {
                        SettingsStatusLabel(text: "Edited", systemImage: "pencil.circle.fill", color: RTIDesign.Color.textSecondary)
                    } else {
                        SettingsStatusLabel(text: "Default", systemImage: "checkmark.circle", color: RTIDesign.Color.textSecondary)
                    }
                    Spacer()
                    Button("Reset") {
                        store.reset(id)
                        draft.replace(id, with: store.text(id))
                    }
                    .help("Return this prompt to the shipped default.")
                    .disabled(!store.isOverridden(id))
                    Button("Revert Edits") { draft.replace(id, with: store.text(id)) }
                        .disabled(!isDirty)
                    Button("Save") { store.setOverride(id, text); draft.replace(id, with: store.text(id)) }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!isDirty)
                }
                .controlSize(.small)
            }
            // The split has no pane header above it, so the first card keeps
            // the same inset from the top edge as the list column's header.
            .padding(.top, House.Spacing.sm)
        }
        .onAppear { draft.prepare(id, read: store.text) }
        .onChange(of: id) { _, newID in draft.prepare(newID, read: store.text) }
    }

    /// For recap leaves, show the fully composed prompt so the user sees what
    /// actually ships (the leaf is only a fragment).
    private var assembledPreview: String? {
        let resolve: PromptComposer.Resolver = { $0 == id ? text : store.text($0) }
        switch id {
        case .recapBrief: return PromptComposer.recap(.brief, resolve: resolve)
        case .recapStandard: return PromptComposer.recap(.standard, resolve: resolve)
        case .recapDetailed: return PromptComposer.recap(.detailed, resolve: resolve)
        case .recapLanguageRule: return PromptComposer.recap(.standard, resolve: resolve)
        default: return nil
        }
    }
}
