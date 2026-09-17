import RTICore
import XCTest

/// The composer's keyboard contract (chat-surfaces.md section 3 and 4 "Keys";
/// RTI plan section 2 and 6 "Chinese input").
final class ComposerKeyRouterTests: XCTestCase {
    private func route(
        _ key: ComposerKey,
        _ modifiers: ComposerKeyModifiers = [],
        _ context: ComposerKeyContext = ComposerKeyContext()
    ) -> ComposerKeyResult {
        ComposerKeyRouter.route(key, modifiers: modifiers, context: context)
    }

    // MARK: - IME (marked text)

    func test_markedText_ownsEveryKey() {
        // Pinyin: Return commits the syllable, esc cancels it. Neither may
        // send, stop, clear, or close anything.
        let composing = ComposerKeyContext(hasMarkedText: true, layer: .mention, isStreaming: true, draft: "ni")
        for key: ComposerKey in [.returnKey, .escape, .tab, .backTab, .upArrow, .downArrow, .backspace, .leftArrow] {
            XCTAssertEqual(route(key, [], composing), .passThrough, "\(key)")
        }
        XCTAssertEqual(route(.returnKey, .command, composing), .passThrough)
    }

    // MARK: - Return

    func test_shiftCommandAOpensAttachmentsWithoutTakingSelectAll() {
        XCTAssertEqual(route(.a, [.command, .shift]), .toggleAttachments)
        XCTAssertEqual(route(.a, .command), .passThrough)
        XCTAssertEqual(route(.a, [.command, .shift], ComposerKeyContext(hasMarkedText: true)), .passThrough)
    }

    func test_shiftCommandSOpensAttachmentsAsQuickLaunchDoes() {
        // Quick Launch binds its attach chooser to ⇧⌘S, so the hand reaches
        // for it in RTI's composer too.
        XCTAssertEqual(route(.s, [.command, .shift]), .toggleAttachments)
        XCTAssertEqual(route(.s, .command), .passThrough)
        XCTAssertEqual(route(.s, [.command, .shift], ComposerKeyContext(hasMarkedText: true)), .passThrough)
    }

    func test_readingOrFailedAttachmentsBlockSendAndQueue() {
        for status in [ComposerAttachmentStatus.reading, .failed] {
            XCTAssertEqual(route(.returnKey, [], ComposerKeyContext(draft: "Review this", attachmentStatus: status)), .consume)
            XCTAssertEqual(route(.returnKey, [], ComposerKeyContext(isStreaming: true, draft: "Review this", attachmentStatus: status)), .consume)
            XCTAssertEqual(route(.escape, [], ComposerKeyContext(isStreaming: true, attachmentStatus: status)), .stopStream)
        }
    }

    func test_return_sendsTypedText() {
        XCTAssertEqual(route(.returnKey, [], ComposerKeyContext(draft: "What did we decide?")), .submit)
    }

    func test_return_onEmptyField_doesNothing() {
        XCTAssertEqual(route(.returnKey, [], ComposerKeyContext(draft: "   ")), .consume)
    }

    func test_return_sendsChipsOnTheirOwn() {
        XCTAssertEqual(route(.returnKey, [], ComposerKeyContext(hasAttachments: true)), .submit)
    }

    func test_shiftOrOptionReturn_startsANewLine() {
        XCTAssertEqual(route(.returnKey, .shift, ComposerKeyContext(draft: "line one")), .passThrough)
        XCTAssertEqual(route(.returnKey, .option, ComposerKeyContext(draft: "line one")), .passThrough)
    }

    func test_commandReturn_runsThePrimaryAction() {
        XCTAssertEqual(route(.returnKey, .command), .runPrimary)
        XCTAssertEqual(route(.returnKey, .command, ComposerKeyContext(draft: "typed")), .runPrimary)
    }

    func test_return_duringStream_queuesTheDraft() {
        let context = ComposerKeyContext(isStreaming: true, draft: "and the budget?")
        XCTAssertEqual(route(.returnKey, [], context), .queue)
        XCTAssertEqual(route(.returnKey, [], ComposerKeyContext(isStreaming: true)), .consume)
    }

    func test_return_inNoteMode_writesTheNoteEvenWhileStreaming() {
        let context = ComposerKeyContext(isStreaming: true, isNoteMode: true, draft: "Pricing agreed")
        XCTAssertEqual(route(.returnKey, [], context), .submit)
        XCTAssertEqual(route(.returnKey, [], ComposerKeyContext(isNoteMode: true, hasAttachments: true)), .consume,
                       "a note needs text; chips alone are not a note")
    }

    func test_return_inAChooser_picksTheRow() {
        for layer: ComposerLayer in [.mention, .slash, .addContext] {
            XCTAssertEqual(route(.returnKey, [], ComposerKeyContext(layer: layer, draft: "@x")), .acceptChooser, "\(layer)")
        }
    }

    // MARK: - Escape

    func test_escape_popsOneLayerAtATime() {
        let all = ComposerKeyContext(layer: .mention, isStreaming: true, isQueued: true, draft: "typed")
        XCTAssertEqual(route(.escape, [], all), .closeLayer)

        var next = all
        next.layer = .none
        XCTAssertEqual(route(.escape, [], next), .stopStream, "the stream stops; the queued draft stays")

        next.isStreaming = false
        next.isQueued = false
        XCTAssertEqual(route(.escape, [], next), .clearDraft)

        next.draft = ""
        XCTAssertEqual(route(.escape, [], next), .consume, "a stray esc never hides the cockpit")
    }

    func test_escape_closesThePalette() {
        XCTAssertEqual(route(.escape, [], ComposerKeyContext(layer: .palette)), .closeLayer)
    }

    // MARK: - Arrows

    func test_arrows_moveTheChooser() {
        let context = ComposerKeyContext(layer: .slash, draft: "/re")
        XCTAssertEqual(route(.upArrow, [], context), .moveChooser(-1))
        XCTAssertEqual(route(.downArrow, [], context), .moveChooser(1))
    }

    func test_upArrow_onEmptyField_recallsTheLastQuestion() {
        XCTAssertEqual(route(.upArrow), .recallLastQuestion)
        XCTAssertEqual(route(.upArrow, [], ComposerKeyContext(draft: "a\nb")), .passThrough, "with text it moves the caret")
        XCTAssertEqual(route(.downArrow), .passThrough)
    }

    // MARK: - Palette

    func test_commandK_togglesThePalette() {
        XCTAssertEqual(route(.k, .command), .togglePalette)
        XCTAssertEqual(route(.k, .command, ComposerKeyContext(layer: .palette)), .togglePalette)
        XCTAssertEqual(route(.k), .passThrough, "a plain k is typing")
        XCTAssertEqual(route(.k, [.command, .shift]), .passThrough)
    }

    // MARK: - Tab and the chip strip

    func test_tab_completesAChooser_elseMovesFocus() {
        XCTAssertEqual(route(.tab, [], ComposerKeyContext(layer: .mention, draft: "@on")), .acceptChooser)
        XCTAssertEqual(route(.tab), .moveFocus(forward: true))
        XCTAssertEqual(route(.backTab), .moveFocus(forward: false))
    }

    func test_backTab_entersTheStripWhenChipsExist() {
        XCTAssertEqual(route(.backTab, [], ComposerKeyContext(hasAttachments: true)), .enterStrip)
        XCTAssertEqual(route(.backTab, [], ComposerKeyContext(hasOtherChips: true)), .enterStrip, "a screen chip too")
    }

    func test_screenChipAlone_doesNotSendOnReturn() {
        // A screen read rides with the next question or the primary action;
        // it is not a question on its own.
        XCTAssertEqual(route(.returnKey, [], ComposerKeyContext(hasOtherChips: true)), .consume)
        XCTAssertEqual(route(.backspace, [], ComposerKeyContext(hasOtherChips: true)), .removeNewestChip)
    }

    func test_backspace_inEmptyField_removesTheNewestChip() {
        XCTAssertEqual(route(.backspace, [], ComposerKeyContext(hasAttachments: true)), .removeNewestChip)
        XCTAssertEqual(route(.backspace, [], ComposerKeyContext(draft: "x", hasAttachments: true)), .passThrough)
        XCTAssertEqual(route(.backspace), .passThrough)
    }

    func test_strip_arrowsBackspaceAndLeave() {
        let strip = ComposerKeyContext(hasAttachments: true, isStripFocused: true)
        XCTAssertEqual(route(.leftArrow, [], strip), .moveStrip(-1))
        XCTAssertEqual(route(.rightArrow, [], strip), .moveStrip(1))
        XCTAssertEqual(route(.backspace, [], strip), .removeFocusedChip)
        XCTAssertEqual(route(.escape, [], strip), .leaveStrip(alsoPassThrough: false))
        XCTAssertEqual(route(.tab, [], strip), .leaveStrip(alsoPassThrough: false))
        XCTAssertEqual(route(.other, [], strip), .leaveStrip(alsoPassThrough: true), "typing goes back to the field")
        XCTAssertEqual(route(.returnKey, [], strip), .leaveStrip(alsoPassThrough: true))
    }
}
