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
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                List(selection: $selection) {
                    ForEach(store.modes) { mode in
                        HStack {
                            Text(mode.name)
                            if mode.id == store.activeModeId {
                                Spacer()
                                Text("Active").font(.system(size: 10)).foregroundStyle(.blue)
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
            .frame(width: 160)

            VStack(alignment: .leading, spacing: 10) {
                if selection != nil {
                    Text("Name").font(.system(size: 12, weight: .medium))
                    TextField("Mode name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    Text("System prompt").font(.system(size: 12, weight: .medium))
                    TextEditor(text: $prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                    Text("Reference text (prepended to every turn, capped at 8k chars)")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $reference)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                    HStack {
                        Button("Set Active") {
                            if let id = selection { store.activeModeId = id }
                        }
                        .disabled(selection == store.activeModeId)

                        Spacer()

                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                        }

                        Button("Save") { save() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Text("Select a mode to edit.")
                        .foregroundStyle(.secondary)
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

