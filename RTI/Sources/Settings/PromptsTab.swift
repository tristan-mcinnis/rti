import RTICore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Prompts

/// Settings tab that surfaces every tunable prompt (`PromptID`) for editing,
/// with per-prompt and global "reset to defaults". Edits persist in
/// `PromptStore`; the running app reads them on the next call.
struct PromptsTab: View {
    @State private var selection: PromptID = .systemDefault
    @State private var showResetAllConfirm = false
    private var store = PromptStore.shared

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Prompt Library")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.hasAnyOverride {
                        SettingsStatusLabel(text: "Edited", systemImage: "pencil.circle.fill", color: .blue)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)

                promptList
            }
            .frame(minWidth: 230, idealWidth: 250, maxWidth: 310)
            .background(.thinMaterial)

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                Divider()
                PromptEditorView(id: selection)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .background(SettingsSurfaceBackground())
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Prompts")
                    .font(.system(size: 14, weight: .semibold))
                Text("Edits take effect on the next call. Reset returns to the shipped default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: false)
            }
            Spacer()

            HStack(spacing: 8) {
                Button("Export Defaults…", action: exportDefaults)
                    .help("Write the shipped default prompts to a JSON file (keeps the offline prompt-lab in sync).")
                Button(role: .destructive) {
                    showResetAllConfirm = true
                } label: {
                    Text("Reset All")
                }
                .disabled(!store.hasAnyOverride)
            }
            .controlSize(.small)
            .confirmationDialog(
                "Reset every prompt to its shipped default? Your edits will be lost.",
                isPresented: $showResetAllConfirm, titleVisibility: .visible
            ) {
                Button("Reset all prompts", role: .destructive) { store.resetAll() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var promptList: some View {
        List(selection: $selection) {
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
                                    .foregroundStyle(.orange)
                                    .help("The shipped default changed since you edited this.")
                            } else if store.isOverridden(id) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
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

    private func exportDefaults() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "rti-prompt-defaults.json"
        panel.message = "Save the shipped default prompts (for scripts/prompt-lab)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportDefaults(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The editor pane for a single prompt: a local buffer with Save / Revert /
/// Reset, a live warning when an edit drops a required token, and (for the
/// composed recap leaves) a preview of the fully assembled prompt.
private struct PromptEditorView: View {
    let id: PromptID
    @State private var text: String = ""
    private var store = PromptStore.shared

    init(id: PromptID) {
        self.id = id
    }

    private var isDirty: Bool {
        text != store.text(id)
    }

    private var warnings: [String] {
        store.warnings(for: id, candidate: text)
    }

    var body: some View {
        SettingsPage(maxWidth: 820) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard(id.title, detail: id.help) {
                    VStack(alignment: .leading, spacing: 10) {
                        if store.defaultChangedSinceEdit(id) {
                            SettingsStatusLabel(text: "The shipped default changed since you edited this.", systemImage: "exclamationmark.triangle.fill", color: .orange)
                        }

                        TextEditor(text: $text)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 280)
                            .settingsEditorBorder()

                        ForEach(warnings, id: \.self) { w in
                            SettingsStatusLabel(text: w, systemImage: "exclamationmark.octagon.fill", color: .red)
                        }
                    }
                }

                if let assembled = assembledPreview {
                    SettingsCard("Preview Assembled Prompt") {
                        Text(assembled)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    if store.isOverridden(id) {
                        SettingsStatusLabel(text: "Edited", systemImage: "pencil.circle.fill", color: .blue)
                    } else {
                        SettingsStatusLabel(text: "Default", systemImage: "checkmark.circle", color: .secondary)
                    }
                    Spacer()
                    Button("Reset to Default") {
                        store.reset(id)
                        text = store.text(id)
                    }
                    .disabled(!store.isOverridden(id))
                    Button("Revert Edits") { text = store.text(id) }
                        .disabled(!isDirty)
                    Button("Save") { store.setOverride(id, text) }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!isDirty)
                }
            }
        }
        .onAppear { text = store.text(id) }
        .onChange(of: id) { _, newID in text = store.text(newID) }
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
