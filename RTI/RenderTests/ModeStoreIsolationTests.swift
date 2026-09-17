import RTICore
import XCTest

/// The memory-only `ModeStore` a render proof passes into `OverlayPanelView`.
///
/// These prove the isolation without reading or writing ANY live file or
/// preference: a memory-only store touches neither `modes.json` nor the
/// shared `UserDefaults`, so a render proof can never change the user's live
/// modes or active-mode choice.
@MainActor
final class ModeStoreIsolationTests: XCTestCase {

    func testInMemoryStoreIsMemoryOnlyAndHasTheBuiltins() {
        let store = ModeStore.inMemory()
        XCTAssertTrue(store.isMemoryOnly)
        XCTAssertFalse(store.modes.isEmpty, "the built-in seeds are present in memory")
        XCTAssertNotNil(store.activeMode, "the isolated active mode resolves")
    }

    func testInMemoryStoreUsesAnIsolatedActiveMode() {
        let store = ModeStore.inMemory(activeModeId: "builtin.interview")
        XCTAssertEqual(store.activeModeId, "builtin.interview")
        XCTAssertEqual(store.activeMode?.id, "builtin.interview")

        // Changing it is in-memory only; no default is written.
        store.activeModeId = "builtin.coding"
        XCTAssertEqual(store.activeMode?.id, "builtin.coding")
    }

    func testInMemoryMutatorsStayInMemoryAndReloadDoesNotReadDisk() {
        let store = ModeStore.inMemory(activeModeId: "builtin.meeting")
        let meeting = try! XCTUnwrap(store.modes.first { $0.id == "builtin.meeting" })

        store.update(id: meeting.id, name: "Renamed in memory", systemPrompt: "edited", referenceText: nil)
        XCTAssertEqual(store.modes.first { $0.id == meeting.id }?.name, "Renamed in memory")

        let added = try! XCTUnwrap(store.addMode(name: "Proof mode", systemPrompt: "proof prompt"))
        XCTAssertTrue(store.modes.contains { $0.id == added })

        store.deleteMode(id: added)
        XCTAssertFalse(store.modes.contains { $0.id == added })

        // `reload()` is a no-op for a memory-only store: it does NOT re-read a
        // file, so the in-memory edit survives. A disk-backed reload would
        // revert "Renamed in memory" to the shipped name.
        store.reload()
        XCTAssertEqual(store.modes.first { $0.id == meeting.id }?.name, "Renamed in memory")
    }

    func testInMemoryStoreHonoursCallerSuppliedModes() {
        let custom = Mode(
            id: "user.proof",
            name: "Proof",
            systemPrompt: "proof",
            isBuiltin: false,
            createdAt: Date(),
            referenceText: nil
        )
        let store = ModeStore.inMemory(modes: [custom], activeModeId: "user.proof")
        XCTAssertEqual(store.activeMode?.id, "user.proof")
        XCTAssertTrue(store.modes.contains { $0.id == "user.proof" })
    }
}
