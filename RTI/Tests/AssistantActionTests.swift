import RTICore
import XCTest

/// Pins the single `AssistantAction` catalogue that the ✦ menu, command palette,
/// global hotkeys, and ⌘⏎ remap all project from. Before this, the same action
/// was described in four separate registries that drifted; these assertions are
/// the guard that the one catalogue stays coherent.
final class AssistantActionTests: XCTestCase {

    func test_catalogue_idsAreUniqueAndExpected() {
        let ids = AssistantAction.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique")
        XCTAssertEqual(
            Set(ids),
            ["assist", "answerLatest", "sayNext", "followups", "keyTensions", "probe", "themes", "recap", "quickRecap", "summary"]
        )
    }

    func test_byID_resolvesAndMissesCleanly() {
        XCTAssertEqual(AssistantAction.byID("recap")?.label, "Recap")
        XCTAssertNil(AssistantAction.byID("nope"))
    }

    func test_everyAction_hasNonEmptyLabelPaletteTitleSymbol() {
        for a in AssistantAction.all {
            XCTAssertFalse(a.label.isEmpty, "\(a.id) label")
            XCTAssertFalse(a.paletteTitle.isEmpty, "\(a.id) paletteTitle")
            XCTAssertFalse(a.symbol.isEmpty, "\(a.id) symbol")
        }
    }

    func test_hotkeyDisplays_matchTheKnownBindings() {
        let expected: [String: String] = [
            "sayNext": "⌘⌥S", "followups": "⌘⌥F", "keyTensions": "⌘⌥T",
            "probe": "⌘⌥U", "themes": "⌘⌥E", "recap": "⌘⌥R", "summary": "⌘⌥M",
            "answerLatest": "⌘⌥Q",
        ]
        for (id, hint) in expected {
            XCTAssertEqual(AssistantAction.byID(id)?.hotkey?.display, hint, "hotkey for \(id)")
        }
        XCTAssertNil(AssistantAction.byID("assist")?.hotkey, "assist has no standalone hotkey")
        XCTAssertNil(AssistantAction.byID("quickRecap")?.hotkey, "quick recap rides the ⌘⏎ primary bind")
    }

    func test_quickRecap_isTheShippedPrimaryAction() {
        // The default ⌘⏎ binding is Quick recap (5 minutes, brief), not Assist.
        let quick = AssistantAction.byID("quickRecap")
        XCTAssertEqual(quick?.label, "Quick recap")
        XCTAssertEqual(quick?.paletteTitle, "Quick Recap (last 5 min)")
        XCTAssertTrue(quick?.primaryEligible ?? false)
    }

    func test_visibilityGates() {
        // Listener-research actions are listener-only and mode-gated.
        for id in ["keyTensions", "probe", "themes"] {
            let a = AssistantAction.byID(id)
            XCTAssertEqual(a?.listenerOnly, true, "\(id) listenerOnly")
            XCTAssertEqual(a?.modes, [.interview, .meeting, .other], "\(id) modes")
        }
        // Say-next is speaker-only (hidden when observing); the rest are always-on.
        XCTAssertEqual(AssistantAction.byID("sayNext")?.listenerOnly, false)
        XCTAssertNil(AssistantAction.byID("assist")?.listenerOnly)
        XCTAssertNil(AssistantAction.byID("recap")?.modes)
    }

    // MARK: - Primary-action migration

    func test_migration_movesOnlyTheOldShippedDefaults() {
        let quick = PrimaryActionMigration.quickRecapID
        XCTAssertEqual(PrimaryActionMigration.resolve(stored: nil, alreadyMigrated: false), quick)
        XCTAssertEqual(PrimaryActionMigration.resolve(stored: "assist", alreadyMigrated: false), quick)
        XCTAssertEqual(PrimaryActionMigration.resolve(stored: "answerLatest", alreadyMigrated: false), quick)
        // An explicit choice of anything else is kept.
        XCTAssertEqual(PrimaryActionMigration.resolve(stored: "recap", alreadyMigrated: false), "recap")
        XCTAssertEqual(PrimaryActionMigration.resolve(stored: "summary", alreadyMigrated: false), "summary")
    }

    func test_migration_runsOnceAndNeverRevertsALaterChoice() {
        let quick = PrimaryActionMigration.quickRecapID
        XCTAssertEqual(PrimaryActionMigration.resolve(stored: "assist", alreadyMigrated: true), "assist")
        XCTAssertEqual(PrimaryActionMigration.resolve(stored: "answerLatest", alreadyMigrated: true), "answerLatest")
        XCTAssertEqual(PrimaryActionMigration.resolve(stored: nil, alreadyMigrated: true), quick)
    }

    func test_primaryEligible_allInOrder() {
        // Every action is currently bindable to ⌘⏎, preserved in catalogue order.
        XCTAssertEqual(
            AssistantAction.primaryEligibleActions.map(\.id),
            AssistantAction.all.map(\.id)
        )
    }

    func test_hotkeyDisplay_includesShiftInConventionalOrder() {
        let hk = ActionHotkey(key: "X", modifiers: [.command, .option, .shift])
        XCTAssertEqual(hk.display, "⌘⌥⇧X")
    }
}
