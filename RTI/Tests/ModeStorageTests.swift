import RTICore
import XCTest

/// Pins ModeStorage's persistence + seeding behavior (the logic the app's
/// observable ModeStore delegates to): round-trip, malformed recovery, and the
/// launch-time builtin upgrade.
final class ModeStorageTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("modestorage-\(UUID().uuidString).json")
    }

    private func mode(_ id: String, builtin: Bool = false, prompt: String = "p") -> Mode {
        Mode(
            id: id,
            name: id,
            systemPrompt: prompt,
            isBuiltin: builtin,
            createdAt: Date(timeIntervalSince1970: 0),
            referenceText: nil
        )
    }

    func test_saveLoad_roundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let modes = [mode("a"), mode("b", builtin: true)]
        try ModeStorage.save(modes, to: url)
        XCTAssertEqual(ModeStorage.load(from: url), modes)
    }

    func test_load_missingFile_returnsNil() {
        XCTAssertNil(ModeStorage.load(from: tempURL()))
    }

    func test_load_malformedJSON_returnsNil() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "{ not valid json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(ModeStorage.load(from: url))
    }

    func test_builtinSeeds_haveExpectedIds() {
        let ids = ModeStorage.builtinSeeds().map(\.id)
        XCTAssertEqual(ids, ["builtin.meeting", "builtin.interview", "builtin.coding", "builtin.custom"])
    }

    func test_upgradingBuiltins_fromEmpty_addsAllSeeds() {
        let upgraded = ModeStorage.upgradingBuiltins(in: [])
        XCTAssertEqual(Set(upgraded.map(\.id)), Set(ModeStorage.builtinSeeds().map(\.id)))
    }

    func test_upgradingBuiltins_refreshesBuiltinPromptInPlace() {
        // A meeting builtin with a stale prompt should be refreshed to current.
        let stale = mode("builtin.meeting", builtin: true, prompt: "OLD PROMPT")
        let upgraded = ModeStorage.upgradingBuiltins(in: [stale])
        let meeting = upgraded.first { $0.id == "builtin.meeting" }
        XCTAssertNotNil(meeting)
        XCTAssertNotEqual(meeting?.systemPrompt, "OLD PROMPT")
    }

    func test_upgradingBuiltins_leavesUserModesUntouched() {
        let user = mode("user.123", builtin: false, prompt: "my custom prompt")
        let upgraded = ModeStorage.upgradingBuiltins(in: [user])
        let back = upgraded.first { $0.id == "user.123" }
        XCTAssertEqual(back, user) // prompt + every field preserved
    }
}
