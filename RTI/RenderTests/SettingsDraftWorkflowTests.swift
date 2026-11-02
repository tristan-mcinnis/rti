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
        navigation.pane = .prompts
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
