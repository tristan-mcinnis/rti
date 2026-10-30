import Foundation
import Observation

/// Per-mode unsaved buffers survive both settings navigation and item changes.
@Observable @MainActor
final class ModeSettingsDraft {
    private struct Fields: Equatable {
        var name: String
        var prompt: String
        var reference: String
    }

    var selection: String? {
        didSet {
            guard selection != oldValue else { return }
            if let oldValue { drafts[oldValue] = fields }
            loadSelection()
        }
    }
    var name = "" { didSet { clearFeedback() } }
    var prompt = "" { didSet { clearFeedback() } }
    var reference = "" { didSet { clearFeedback() } }
    private(set) var saved = false
    private(set) var saveError: String?
    private var drafts: [String: Fields] = [:]
    private var baselines: [String: Fields] = [:]
    private var store: ModeStore?

    var hasUnsavedChanges: Bool {
        guard let selection, let baseline = baselines[selection] else { return false }
        return fields != baseline
    }

    func prepare(store: ModeStore) {
        if self.store !== store {
            selection = nil
            drafts = [:]
            baselines = [:]
            self.store = store
        }
        if selection == nil { selection = store.activeModeId ?? store.modes.first?.id }
        else if !hasUnsavedChanges { loadSelection() }
    }

    func revert() {
        guard let selection else { return }
        drafts[selection] = nil
        loadSelection()
    }

    func save() {
        guard let selection, let store else { return }
        clearFeedback()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            saveError = "Enter a mode name before saving."
            return
        }
        guard store.update(id: selection, name: trimmedName, systemPrompt: prompt, referenceText: reference) else {
            saveError = "Could not save this mode. Your edits are kept here. Check the modes file is writable, then save again."
            return
        }
        name = trimmedName
        baselines[selection] = fields
        drafts[selection] = fields
        saved = true
    }

    private func clearFeedback() {
        saved = false
        saveError = nil
    }

    private var fields: Fields { Fields(name: name, prompt: prompt, reference: reference) }

    private func loadSelection() {
        guard let selection, let mode = store?.modes.first(where: { $0.id == selection }) else { return }
        let stored = Fields(name: mode.name, prompt: mode.systemPrompt, reference: mode.referenceText ?? "")
        let cached = drafts[selection]
        let value: Fields
        if let cached, cached != baselines[selection] { value = cached }
        else { value = stored }
        baselines[selection] = stored
        name = value.name
        prompt = value.prompt
        reference = value.reference
    }
}
