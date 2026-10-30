import XCTest
import RTICore

/// Every store here is fake or memory-only; no real credentials or defaults are used.
@MainActor
final class SettingsDraftWorkflowTests: XCTestCase {
    @MainActor private final class ProviderFixture {
        var snapshot = ProviderSettingsDraft.Snapshot(providerID: "deepseek", keys: ["soniox": "stored-fixture-key"])
        var writes: [(String, String)] = []
        var selectedProviders: [String] = []
        var rejectsWrites = false
        var dependencies: ProviderSettingsDraft.Dependencies {
            .init(read: { self.snapshot }, writeKey: { account, value in
                self.writes.append((account, value))
                if !self.rejectsWrites { self.snapshot.keys[account] = value }
            }, selectProvider: {
                self.selectedProviders.append($0)
                self.snapshot.providerID = $0
            })
        }
    }

    func testProviderDraftSurvivesPageAndPaneRemountWithoutSaving() {
        let fixture = ProviderFixture()
        let draft = ProviderSettingsDraft(dependencies: fixture.dependencies)
        let navigation = SettingsNavigation(providerDraft: draft)
        draft.loadIfNeeded()
        draft.selectedLLMProviderId = "openai"
        draft.keyValues["soniox"] = "unsaved-fixture-key"
        navigation.pane = .modes
        navigation.pane = .providers
        navigation.providerDraft.loadIfNeeded()
        XCTAssertEqual(draft.selectedLLMProviderId, "openai")
        XCTAssertEqual(draft.keyValues["soniox"], "unsaved-fixture-key")
        XCTAssertTrue(draft.hasUnsavedChanges)
        XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertTrue(fixture.selectedProviders.isEmpty)
        XCTAssertEqual(fixture.snapshot.providerID, "deepseek")
    }

    func testProviderSaveVerifiesChangedKeysBeforeCommittingSelection() {
        let fixture = ProviderFixture()
        let draft = ProviderSettingsDraft(dependencies: fixture.dependencies)
        draft.loadIfNeeded()
        draft.selectedLLMProviderId = "openai"
        draft.keyValues["soniox"] = "  new-fixture-key  "
        draft.save()
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(fixture.snapshot.keys["soniox"], "new-fixture-key")
        XCTAssertEqual(fixture.selectedProviders, ["openai"])
        XCTAssertTrue(draft.saved)
        XCTAssertFalse(draft.hasUnsavedChanges)
        XCTAssertNil(draft.saveError)
    }

    func testFailedKeySaveKeepsDraftAndDoesNotSwitchProvider() {
        let fixture = ProviderFixture()
        fixture.rejectsWrites = true
        let draft = ProviderSettingsDraft(dependencies: fixture.dependencies)
        draft.loadIfNeeded()
        draft.selectedLLMProviderId = "openai"
        draft.keyValues["soniox"] = "retry-fixture-key"
        draft.save()
        XCTAssertNotNil(draft.saveError)
        XCTAssertFalse(draft.saved)
        XCTAssertTrue(draft.hasUnsavedChanges)
        XCTAssertEqual(draft.keyValues["soniox"], "retry-fixture-key")
        XCTAssertTrue(fixture.selectedProviders.isEmpty)
    }

    func testDiscardRestoresStoredSettingsAndCleanDraftRefreshesExternalChanges() {
        let fixture = ProviderFixture()
        let draft = ProviderSettingsDraft(dependencies: fixture.dependencies)
        draft.loadIfNeeded()
        draft.selectedLLMProviderId = "openai"
        draft.discardChanges()
        XCTAssertEqual(draft.selectedLLMProviderId, "deepseek")
        XCTAssertFalse(draft.hasUnsavedChanges)
        fixture.snapshot.providerID = "openrouter"
        draft.loadIfNeeded()
        XCTAssertEqual(draft.selectedLLMProviderId, "openrouter")
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testModeEditsSurviveNavigationAndChangingItemsUntilSaveOrRevert() throws {
        let store = ModeStore.inMemory()
        let draft = ModeSettingsDraft()
        draft.prepare(store: store)
        let originalID = try XCTUnwrap(draft.selection)
        let originalName = draft.name
        let otherID = try XCTUnwrap(store.modes.first { $0.id != originalID }?.id)
        draft.name = "Unsaved fixture name"
        draft.prompt = "Unsaved fixture instructions"
        draft.reference = "Unsaved fixture reference"
        draft.prepare(store: store)
        draft.selection = otherID
        draft.selection = originalID
        XCTAssertEqual(draft.name, "Unsaved fixture name")
        XCTAssertEqual(draft.prompt, "Unsaved fixture instructions")
        XCTAssertEqual(draft.reference, "Unsaved fixture reference")
        XCTAssertEqual(store.modes.first { $0.id == originalID }?.name, originalName)
        draft.save()
        XCTAssertEqual(store.modes.first { $0.id == originalID }?.name, "Unsaved fixture name")
        draft.name = "Discard this edit"
        draft.revert()
        XCTAssertEqual(draft.name, "Unsaved fixture name")
        XCTAssertFalse(draft.hasUnsavedChanges)
    }

    func testFailedModeWriteKeepsStoredModeUnchangedAndDraftDirtyUntilRetry() throws {
        enum WriteFailure: Error { case refused }
        var rejectsWrite = true
        var attempts = 0
        var persistedName: String?
        let store = ModeStore.inMemory(writer: { modes in
            attempts += 1
            if rejectsWrite { throw WriteFailure.refused }
            persistedName = modes.first { $0.id == "builtin.meeting" }?.name
        })
        let draft = ModeSettingsDraft()
        draft.prepare(store: store)
        let id = try XCTUnwrap(draft.selection)
        let original = try XCTUnwrap(store.modes.first { $0.id == id })
        draft.name = "Retry fixture mode"
        draft.prompt = "Keep this unsaved fixture prompt"
        draft.save()
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(draft.saveError)
        XCTAssertFalse(draft.saved)
        XCTAssertTrue(draft.hasUnsavedChanges)
        XCTAssertEqual(store.modes.first { $0.id == id }, original)
        draft.prepare(store: store)
        XCTAssertEqual(draft.name, "Retry fixture mode")
        XCTAssertEqual(draft.prompt, "Keep this unsaved fixture prompt")
        rejectsWrite = false
        draft.save()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(persistedName, "Retry fixture mode")
        XCTAssertNil(draft.saveError)
        XCTAssertTrue(draft.saved)
        XCTAssertFalse(draft.hasUnsavedChanges)
        XCTAssertEqual(store.modes.first { $0.id == id }?.name, "Retry fixture mode")
    }

    func testPromptDraftsStayPerItemAndExplicitRevertAndResetDiscardThem() {
        let draft = PromptSettingsDraft()
        let first = PromptID.systemDefault
        let second = PromptID.recapBrief
        let read: (PromptID) -> String = { "Stored fixture \($0.rawValue)" }
        draft.prepare(first, read: read)
        draft.texts[first] = "Unsaved prompt fixture"
        draft.selection = second
        draft.prepare(second, read: read)
        draft.selection = first
        draft.prepare(first, read: read)
        XCTAssertEqual(draft.texts[first], "Unsaved prompt fixture")
        XCTAssertTrue(draft.isDirty(first))
        draft.replace(first, with: read(first))
        XCTAssertFalse(draft.isDirty(first))
        draft.selection = second
        draft.texts[second] = "Another unsaved fixture"
        draft.resetAll(read: read)
        XCTAssertEqual(draft.selection, second)
        XCTAssertEqual(draft.texts[second], read(second), "The still-visible editor must show its stored default immediately")
        XCTAssertFalse(draft.isDirty(second))
        XCTAssertNil(draft.texts[first], "Other unsaved buffers must be discarded by the confirmed Reset All")
    }
}
