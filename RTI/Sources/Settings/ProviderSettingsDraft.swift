import Foundation
import Observation

/// The Settings navigation owns this draft. Leaving a page never commits keys.
@Observable @MainActor
final class ProviderSettingsDraft {
    struct Snapshot: Equatable {
        var providerID: String
        var keys: [String: String]
    }

    struct Dependencies {
        var read: @MainActor () -> Snapshot
        var writeKey: @MainActor (_ account: String, _ value: String) -> Void
        var selectProvider: @MainActor (String) -> Void

        static var live: Dependencies {
            Dependencies(read: {
                var keys = Dictionary(uniqueKeysWithValues: LLMProviders.all.map {
                    ($0.keychainAccount, CredentialStore.value(for: $0.keychainAccount) ?? "")
                })
                keys["soniox"] = CredentialStore.soniox ?? ""
                return Snapshot(providerID: LLMProviders.activeId, keys: keys)
            }, writeKey: { account, value in
                if account == "soniox" { CredentialStore.setSoniox(value) }
                else { CredentialStore.setValue(value, for: account) }
            }, selectProvider: {
                LLMProviders.activeId = $0
                STTProviders.activeId = STTProviders.soniox.id
            })
        }
    }

    var selectedLLMProviderId = "" { didSet { clearFeedback() } }
    var keyValues: [String: String] = [:] { didSet { clearFeedback() } }
    private(set) var saved = false
    private(set) var saveError: String?
    private var baseline: Snapshot?
    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) { self.dependencies = dependencies }

    var hasUnsavedChanges: Bool {
        guard let baseline else { return false }
        return selectedLLMProviderId != baseline.providerID || normalized(keyValues) != normalized(baseline.keys)
    }

    func loadIfNeeded() {
        guard baseline == nil || !hasUnsavedChanges else { return }
        replaceDraft(with: dependencies.read())
    }

    func discardChanges() { replaceDraft(with: dependencies.read()) }

    func save() {
        guard let baseline else { return }
        clearFeedback()
        let keys = normalized(keyValues)
        let previousKeys = normalized(baseline.keys)
        let changed = Set(keys.keys).union(previousKeys.keys).filter { keys[$0, default: ""] != previousKeys[$0, default: ""] }
        for account in changed { dependencies.writeKey(account, keys[account, default: ""]) }
        let verified = dependencies.read()
        guard changed.allSatisfy({ normalized(verified.keys)[$0, default: ""] == keys[$0, default: ""] }) else {
            saveError = "Could not save all provider keys. Your edits are kept here. Check the credentials file is writable, then save again."
            return
        }
        let changedProvider = selectedLLMProviderId != baseline.providerID
        let requestedProvider = selectedLLMProviderId
        if changedProvider { dependencies.selectProvider(requestedProvider) }
        let committed = dependencies.read()
        guard !changedProvider || committed.providerID == requestedProvider else {
            saveError = "Could not save the selected provider. Your edits are kept here. Try saving again."
            return
        }
        replaceDraft(with: committed)
        saved = true
    }

    private func replaceDraft(with snapshot: Snapshot) {
        selectedLLMProviderId = snapshot.providerID
        keyValues = snapshot.keys
        baseline = snapshot
        clearFeedback()
    }

    private func clearFeedback() {
        saved = false
        saveError = nil
    }

    private func normalized(_ keys: [String: String]) -> [String: String] {
        keys.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
