import RTICore
import XCTest

/// A render proof or test can never change the user's live call type.
@MainActor
final class CallTypeStoreIsolationTests: XCTestCase {
    func testAMemoryOnlyStoreLeavesTheLiveChoiceAlone() {
        let key = CallTypeDefaults.activeKey
        let live = UserDefaults.standard.string(forKey: key)
        let store = CallTypeStore.inMemory(.research)
        XCTAssertEqual(store.active, .research)
        store.active = .personal
        XCTAssertEqual(store.active, .personal)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), live)
    }

    func testChoosingAResearchCallTurnsListeningOnAndOthersOff() {
        let store = CallTypeStore.inMemory()
        let controller = LLMController.shared
        let before = controller.listenerMode
        defer { controller.listenerMode = before }
        CommandBuilder.switchCallType(to: .research, callTypes: store, llm: controller)
        XCTAssertTrue(controller.listenerMode)
        CommandBuilder.switchCallType(to: .client, callTypes: store, llm: controller)
        XCTAssertFalse(controller.listenerMode)
    }
}
