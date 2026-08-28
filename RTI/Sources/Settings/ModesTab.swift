import SwiftUI
import RTICore

// MARK: - Modes

struct ModesTab: View {
    private let store = ModeStore.shared
    @State private var selection: String?
    @State private var name = ""
    @State private var prompt = ""
    @State private var reference = ""
    @State private var saved = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Modes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)

                List(selection: $selection) {
                    ForEach(store.modes) { mode in
                        HStack(spacing: 8) {
                            Text(mode.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if mode.id == store.activeModeId {
                                Text("Active")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.blue.opacity(0.10)))
                            }
                        }
                        .tag(Optional(mode.id))
                    }
                }
                HStack(spacing: 4) {
                    Button {
                        if let newId = store.addMode(
                            name: "New Mode",
                            systemPrompt: "You are RTI, a real-time intelligence assistant. Keep responses short and actionable."
                        ) {
                            selection = newId
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New mode")

                    Button {
                        guard let id = selection,
                              let mode = store.modes.first(where: { $0.id == id }),
                              !mode.isBuiltin else { return }
                        store.deleteMode(id: id)
                        selection = store.activeModeId ?? store.modes.first?.id
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection.flatMap { id in store.modes.first { $0.id == id } }?.isBuiltin ?? true)
                    .help("Delete mode (built-in modes cannot be deleted)")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            .background(Color(nsColor: .controlBackgroundColor))

            SettingsPage(maxWidth: 720) {
                if selection != nil {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsCard("Mode Identity", detail: "The name appears in the overlay and command surfaces.") {
                            TextField("Mode name", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }

                        SettingsCard("System Prompt", detail: "Baseline behavior for this mode. Keep it short, specific, and operational.") {
                            TextEditor(text: $prompt)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 150)
                                .settingsEditorBorder()
                        }

                        SettingsCard("Reference Text", detail: "Prepended to every turn and capped at 8k characters. Useful for stable project or client context.") {
                            TextEditor(text: $reference)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 110)
                                .settingsEditorBorder()
                        }

                        HStack {
                            Button("Set Active") {
                                if let id = selection { store.activeModeId = id }
                            }
                            .disabled(selection == store.activeModeId)

                            Spacer()

                            if saved {
                                SettingsStatusLabel(text: "Saved", systemImage: "checkmark.circle.fill", color: .green)
                            }

                            Button("Save Mode") { save() }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                } else {
                    SettingsCard {
                        ContentUnavailableView("Select a Mode", systemImage: "square.stack.3d.up", description: Text("Choose a mode from the list to edit its behavior."))
                    }
                }
            }
        }
        .onAppear {
            if selection == nil { selection = store.activeModeId ?? store.modes.first?.id }
            loadSelection()
        }
        .onChange(of: selection) { _, _ in loadSelection() }
    }

    private func loadSelection() {
        guard let id = selection, let mode = store.modes.first(where: { $0.id == id }) else { return }
        name = mode.name
        prompt = mode.systemPrompt
        reference = mode.referenceText ?? ""
    }

    private func save() {
        guard let id = selection else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        store.update(id: id, name: trimmedName, systemPrompt: prompt, referenceText: reference)
        saved = true
        Task { try? await Task.sleep(for: .seconds(1.2)); await MainActor.run { saved = false } }
    }
}
