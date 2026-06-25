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
        VStack(alignment: .leading, spacing: 8) {
            header
            HSplitView {
                promptList
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
                PromptEditorView(id: selection)
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25))
            )
        }
        .padding(8)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prompts")
                    .font(.headline)
                Text("The instructions RTI sends the model for each action. Edits take effect on the next call; everything resets to the shipped default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Export defaults…", action: exportDefaults)
                .help("Write the shipped default prompts to a JSON file (keeps the offline prompt-lab in sync).")
            Button(role: .destructive) {
                showResetAllConfirm = true
            } label: {
                Text("Reset all")
            }
            .disabled(!store.hasAnyOverride)
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
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(id.title).font(.system(size: 13, weight: .semibold))
                Text(id.help).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.defaultChangedSinceEdit(id) {
                Label("The shipped default changed since you edited this. Reset to adopt the new default, or keep your version.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            ForEach(warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let assembled = assembledPreview {
                DisclosureGroup("Preview assembled prompt") {
                    Text(assembled)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
                }
                .font(.caption)
            }

            HStack {
                if store.isOverridden(id) {
                    Text("Edited").font(.caption).foregroundStyle(.blue)
                } else {
                    Text("Default").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset to default") {
                    store.reset(id)
                    text = store.text(id)
                }
                .disabled(!store.isOverridden(id))
                Button("Revert edits") { text = store.text(id) }
                    .disabled(!isDirty)
                Button("Save") { store.setOverride(id, text) }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
            }
        }
        .padding(10)
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
