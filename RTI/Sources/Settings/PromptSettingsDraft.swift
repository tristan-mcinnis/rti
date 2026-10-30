import Observation
import RTICore

/// Prompt buffers stay separate per item; only Save changes the prompt store.
@Observable @MainActor
final class PromptSettingsDraft {
    var selection: PromptID = .systemDefault
    var texts: [PromptID: String] = [:]
    private var baselines: [PromptID: String] = [:]

    func prepare(_ id: PromptID, read: (PromptID) -> String) {
        if texts[id] == nil || texts[id] == baselines[id] { replace(id, with: read(id)) }
    }

    func isDirty(_ id: PromptID) -> Bool { texts[id] != baselines[id] }

    func replace(_ id: PromptID, with text: String) {
        texts[id] = text
        baselines[id] = text
    }

    func resetAll(read: (PromptID) -> String) {
        texts = [:]
        baselines = [:]
        replace(selection, with: read(selection))
    }
}
