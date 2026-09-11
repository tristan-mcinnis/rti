import RTICore
import XCTest

/// Pins the overlay's `esc` order: input method, layer, find bar, stream,
/// typed text, then nothing. It never hides the window.
final class OverlayEscapeOrderTests: XCTestCase {
    func test_nothingOpen_doesNothingAndLeavesTheWindowUp() {
        let action = OverlayEscapeOrder.action(for: OverlayEscapeState())
        XCTAssertEqual(action, .nothing)
        XCTAssertFalse(action.handlesKey)
    }

    func test_markedText_belongsToTheInputMethod() {
        let everything = OverlayEscapeState(
            hasMarkedText: true, isLayerOpen: true, isFindOpen: true, isStreaming: true, hasTypedText: true
        )
        XCTAssertEqual(OverlayEscapeOrder.action(for: everything), .passToInputMethod)
        XCTAssertFalse(OverlayEscapeOrder.action(for: everything).handlesKey)
    }

    func test_popsOneLayerAtATime_inTheHouseOrder() {
        var state = OverlayEscapeState(isLayerOpen: true, isFindOpen: true, isStreaming: true, hasTypedText: true)
        XCTAssertEqual(OverlayEscapeOrder.action(for: state), .closeLayer)

        state.isLayerOpen = false
        XCTAssertEqual(OverlayEscapeOrder.action(for: state), .closeFind)

        state.isFindOpen = false
        XCTAssertEqual(OverlayEscapeOrder.action(for: state), .stopStream)

        state.isStreaming = false
        XCTAssertEqual(OverlayEscapeOrder.action(for: state), .clearText)

        state.hasTypedText = false
        XCTAssertEqual(OverlayEscapeOrder.action(for: state), .nothing)
    }

    func test_aStreamStopsBeforeTypedTextClears_soAQueuedDraftSurvives() {
        let state = OverlayEscapeState(isStreaming: true, hasTypedText: true)
        XCTAssertEqual(OverlayEscapeOrder.action(for: state), .stopStream)
    }

    func test_everyActingStepHandlesTheKey() {
        for action in [OverlayEscapeAction.closeLayer, .closeFind, .stopStream, .clearText] {
            XCTAssertTrue(action.handlesKey, "\(action)")
        }
    }

    /// Every combination of the five flags gives one of the six actions, and
    /// none of them is a way to hide the window.
    func test_noCombinationHides() {
        for bits in 0..<32 {
            let state = OverlayEscapeState(
                hasMarkedText: bits & 1 != 0,
                isLayerOpen: bits & 2 != 0,
                isFindOpen: bits & 4 != 0,
                isStreaming: bits & 8 != 0,
                hasTypedText: bits & 16 != 0
            )
            let action = OverlayEscapeOrder.action(for: state)
            XCTAssertTrue(
                [.passToInputMethod, .closeLayer, .closeFind, .stopStream, .clearText, .nothing].contains(action),
                "\(state)"
            )
        }
    }
}
