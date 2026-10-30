import SwiftUI
import RTICore
import HouseDesign

// MARK: - Modes

struct ModesTab: View {
    /// The mode store the pane edits. Defaults to the shared store so
    /// production is unchanged; a render proof passes an in-memory one.
    var modeStore: ModeStore = .shared
    private var store: ModeStore { modeStore }
    @Bindable var draft: ModeSettingsDraft = ModeSettingsDraft()

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Modes")
                    .font(.system(size: House.TypeToken.Size.meta, weight: .semibold))
                    .foregroundStyle(RTIDesign.Color.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)

                List(selection: $draft.selection) {
                    ForEach(store.modes) { mode in
                        HStack(spacing: 8) {
                            Text(mode.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if mode.id == store.activeModeId {
                                Text("Active")
                                    .font(.system(size: House.TypeToken.Size.micro, weight: .medium))
                                    .foregroundStyle(RTIDesign.Color.textSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(RTIDesign.Color.chipFill))
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
                            draft.selection = newId
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New mode")

                    Button {
                        guard let id = draft.selection,
                              let mode = store.modes.first(where: { $0.id == id }),
                              !mode.isBuiltin else { return }
                        store.deleteMode(id: id)
                        draft.selection = store.activeModeId ?? store.modes.first?.id
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(draft.selection.flatMap { id in store.modes.first { $0.id == id } }?.isBuiltin ?? true)
                    .help("Delete mode (built-in modes cannot be deleted)")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            .background(RTIDesign.Color.trackBackground)

            SettingsPage(maxWidth: 720) {
                if draft.selection != nil {
                    VStack(alignment: .leading, spacing: House.Spacing.xl) {
                        SettingsCard("Mode Identity", detail: "The name appears in the overlay and command surfaces.") {
                            TextField("Mode name", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                        }

                        SettingsCard("System Prompt", detail: "Baseline behavior for this mode. Keep it short, specific, and operational.") {
                            TextEditor(text: $draft.prompt)
                                .font(RTIDesign.Font.code)
                                .frame(minHeight: 150)
                                .settingsEditorBorder()
                        }

                        SettingsCard("Reference Text", detail: "Prepended to every turn and capped at 8k characters. Useful for stable project or client context.") {
                            TextEditor(text: $draft.reference)
                                .font(RTIDesign.Font.code)
                                .frame(minHeight: 110)
                                .settingsEditorBorder()
                        }

                        if let error = draft.saveError {
                            SettingsStatusLabel(text: error, systemImage: "exclamationmark.triangle", color: House.ColorToken.danger)
                        }

                        HStack(spacing: House.Spacing.xs) {
                            Button("Set Active") {
                                if let id = draft.selection { store.activeModeId = id }
                            }
                            .disabled(draft.selection == store.activeModeId)

                            Spacer()

                            if draft.hasUnsavedChanges {
                                SettingsStatusLabel(text: "Unsaved changes", systemImage: "pencil", color: House.ColorToken.textSecondary)
                            } else if draft.saved {
                                SettingsStatusLabel(text: "Saved", systemImage: "checkmark.circle.fill", color: RTIDesign.Color.success)
                            }

                            Button("Revert Edits") { draft.revert() }
                                .disabled(!draft.hasUnsavedChanges)
                            Button("Save Mode") { draft.save() }
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
        .onAppear { draft.prepare(store: store) }
    }
}
