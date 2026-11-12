import RTICore
import XCTest

final class LiveRailPacerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let pacer = LiveRailPacer.standard

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func item(_ text: String, _ lane: LiveRailItem.Lane = .now, arrived: TimeInterval = 0) -> LiveRailItem {
        LiveRailItem(id: UUID(), text: text, lane: lane, arrivedAt: at(arrived))
    }

    // MARK: - admit

    func testAdmitTable() {
        struct Row {
            let name: String
            let now: TimeInterval
            let lastAdmit: TimeInterval?
            let selfSpoke: TimeInterval?
            let callType: CallType
            let admits: Bool
            let retry: TimeInterval?
        }
        let rows: [Row] = [
            Row(name: "first item goes straight in", now: 0, lastAdmit: nil, selfSpoke: nil, callType: .client,
                admits: true, retry: nil),
            Row(name: "spacing holds the next item", now: 30, lastAdmit: 0, selfSpoke: nil, callType: .client,
                admits: false, retry: 60),
            Row(name: "spacing has passed", now: 60, lastAdmit: 0, selfSpoke: nil, callType: .client,
                admits: true, retry: nil),
            Row(name: "own speech holds on a client call", now: 100, lastAdmit: 0, selfSpoke: 98, callType: .client,
                admits: false, retry: 102),
            Row(name: "hold has passed", now: 102, lastAdmit: 0, selfSpoke: 98, callType: .client,
                admits: true, retry: nil),
            Row(name: "no hold on a research call", now: 100, lastAdmit: 0, selfSpoke: 99, callType: .research,
                admits: true, retry: nil),
            Row(name: "later of spacing and hold wins", now: 50, lastAdmit: 0, selfSpoke: 58, callType: .client,
                admits: false, retry: 62),
        ]
        for row in rows {
            let candidate = item("Ask about the renewal date")
            let result = pacer.admit(
                candidates: [candidate], dismissed: [], now: at(row.now),
                lastAdmitAt: row.lastAdmit.map(at), selfSpokeAt: row.selfSpoke.map(at), callType: row.callType
            )
            XCTAssertEqual(result.admitted, row.admits ? candidate.id : nil, row.name)
            XCTAssertEqual(result.retryAt, row.retry.map(at), row.name)
        }
    }

    func testAdmitTakesTheNewestPassFirstAndSkipsDismissedRepeats() {
        let repeatOfDismissed = item("  Ask about the BUDGET. ")
        let older = item("Ask who signs off", arrived: 1)
        let newerFirst = item("Recall the Q3 number", arrived: 2)
        let newerSecond = item("Say the renewal price", arrived: 2)
        let result = pacer.admit(
            candidates: [repeatOfDismissed, older, newerFirst, newerSecond],
            dismissed: [LiveRailPacer.normalized("ask about the budget")],
            now: at(10), lastAdmitAt: nil, selfSpokeAt: nil, callType: .client
        )
        XCTAssertEqual(result.admitted, newerFirst.id, "the newest pass, and its first card")
        XCTAssertEqual(result.duplicatesOfDismissed, [repeatOfDismissed.id])
        XCTAssertEqual(result.stale, [], "nothing is older than staleAfter yet")
    }

    func testAdmitDropsCandidatesOlderThanStaleAfterOnlyWhenANewerOneWaits() {
        let old = item("Old pass card", arrived: 0)
        let fresh = item("Fresh pass card", arrived: 95)
        let both = pacer.admit(candidates: [old, fresh], dismissed: [], now: at(100), lastAdmitAt: nil,
                               selfSpokeAt: nil, callType: .client)
        XCTAssertEqual(both.admitted, fresh.id)
        XCTAssertEqual(both.stale, [old.id])

        let alone = pacer.admit(candidates: [old], dismissed: [], now: at(100), lastAdmitAt: nil,
                                selfSpokeAt: nil, callType: .client)
        XCTAssertEqual(alone.admitted, old.id, "with nothing newer waiting, an old card can still show")
        XCTAssertEqual(alone.stale, [])
    }

    func testAdmitSkipsAFullyPinnedLane() {
        let say = item("Say this")
        let flag = item("Flag this", .threads)
        let result = pacer.admit(candidates: [say, flag], dismissed: [], now: at(0), lastAdmitAt: nil,
                                 selfSpokeAt: nil, callType: .client, fullLanes: [.now])
        XCTAssertEqual(result.admitted, flag.id)
    }

    func testNormalizedIgnoresCaseSpacingAndClosingPunctuation() {
        XCTAssertEqual(LiveRailPacer.normalized("  Ask   about the Budget?"), "ask about the budget")
        XCTAssertEqual(LiveRailPacer.normalized("问一下预算。"), LiveRailPacer.normalized("问一下预算"))
    }

    // MARK: - Board

    func testBoardShowsAtMostOneItemPerSpacing() {
        var board = LiveRailBoard()
        board.offer([item("A"), item("B"), item("C")])
        XCTAssertEqual(board.advance(now: at(0), callType: .client), at(60))
        XCTAssertEqual(board.nowItems.map(\.text), ["A"])
        XCTAssertEqual(board.waitingCount, 2)
        XCTAssertEqual(board.advance(now: at(30), callType: .client), at(60))
        XCTAssertEqual(board.nowItems.map(\.text), ["A"])
        board.advance(now: at(60), callType: .client)
        XCTAssertEqual(board.nowItems.map(\.text), ["B", "A"])
    }

    func testCapFadesTheOldestNowItem() {
        var pacer = LiveRailPacer()
        pacer.spacing = 0
        pacer.fadeAfter = 10000
        var board = LiveRailBoard(pacer: pacer)
        board.offer(["One", "Two", "Three", "Four"].map { item($0) })
        for second in 0 ..< 4 {
            board.advance(now: at(TimeInterval(second)), callType: .research)
        }
        XCTAssertEqual(board.nowItems.map(\.text), ["Four", "Three", "Two"])
        XCTAssertEqual(board.earlier.map(\.text), ["One"])
    }

    func testThreadsCapIsTwo() {
        var pacer = LiveRailPacer()
        pacer.spacing = 0
        var board = LiveRailBoard(pacer: pacer)
        board.offer(["F1", "F2", "F3"].map { item($0, .threads) })
        for second in 0 ..< 3 {
            board.advance(now: at(TimeInterval(second)), callType: .client)
        }
        XCTAssertEqual(board.threadItems.map(\.text), ["F3", "F2"])
    }

    func testUnpinnedItemsFadeAfterFourMinutesAndPinnedNever() {
        var pacer = LiveRailPacer()
        pacer.spacing = 0
        var board = LiveRailBoard(pacer: pacer)
        let keep = item("Pinned point")
        let fade = item("Passing point")
        board.offer([keep, fade])
        board.advance(now: at(0), callType: .client)
        board.advance(now: at(1), callType: .client)
        board.pin(keep.id)
        XCTAssertEqual(board.advance(now: at(100), callType: .client), at(241))

        board.advance(now: at(241), callType: .client)
        XCTAssertEqual(board.state(of: fade.id), .expired)
        XCTAssertEqual(board.earlier.map(\.text), ["Passing point"])
        board.advance(now: at(10000), callType: .client)
        XCTAssertEqual(board.state(of: keep.id), .pinned)
        XCTAssertNil(board.advance(now: at(10001), callType: .client), "nothing left to wake for")
    }

    func testPinnedItemsSurviveTheCap() {
        var pacer = LiveRailPacer()
        pacer.spacing = 0
        var board = LiveRailBoard(pacer: pacer)
        let pinned = item("Keep me")
        board.offer([pinned])
        board.advance(now: at(0), callType: .client)
        board.pin(pinned.id)
        board.offer(["B", "C", "D", "E"].map { item($0, arrived: 1) })
        for second in 1 ... 4 {
            board.advance(now: at(TimeInterval(second)), callType: .client)
        }
        XCTAssertEqual(board.state(of: pinned.id), .pinned)
        XCTAssertTrue(board.nowItems.contains { $0.id == pinned.id })
        XCTAssertEqual(board.nowItems.count, 3, "a pinned item counts toward the cap of 3")
        XCTAssertEqual(board.nowItems.map(\.text), ["E", "D", "Keep me"])
    }

    func testPinnedThreadsCountTowardTheirCapAndAFullyPinnedLaneWaits() {
        var pacer = LiveRailPacer()
        pacer.spacing = 0
        var board = LiveRailBoard(pacer: pacer)
        let first = item("F1", .threads)
        let second = item("F2", .threads)
        board.offer([first, second])
        board.advance(now: at(0), callType: .client)
        board.advance(now: at(1), callType: .client)
        board.pin(first.id)
        board.pin(second.id)
        let waiting = item("F3", .threads, arrived: 2)
        board.offer([waiting])
        board.advance(now: at(3), callType: .client)
        XCTAssertEqual(board.threadItems.count, 2)
        XCTAssertEqual(board.state(of: waiting.id), .new, "a lane full of pins admits nothing")
        board.dismiss(first.id)
        board.advance(now: at(4), callType: .client)
        XCTAssertEqual(board.state(of: waiting.id), .shown)
        XCTAssertEqual(board.threadItems.count, 2)
    }

    func testANewerPassGoesFirstAndOlderCardsGoStale() {
        var board = LiveRailBoard()
        board.offer(["A1", "A2", "A3"].map { item($0, arrived: 0) })
        board.advance(now: at(0), callType: .client)
        board.offer(["B1", "B2"].map { item($0, arrived: 50) })
        board.advance(now: at(60), callType: .client)
        XCTAssertEqual(board.nowItems.map(\.text), ["B1", "A1"], "the card about what was just said goes first")
        board.advance(now: at(120), callType: .client)
        XCTAssertEqual(board.nowItems.map(\.text), ["B2", "B1", "A1"])
        XCTAssertEqual(Set(board.earlier.map(\.text)), ["A2", "A3"], "cards 2 minutes old faded unseen")
        XCTAssertTrue(board.earlier.allSatisfy { $0.shownAt == nil })
    }

    func testStaleCandidatesNeverShow() {
        var board = LiveRailBoard()
        board.offer([item("A"), item("Old news")])
        board.advance(now: at(0), callType: .client)
        board.advance(now: at(240), callType: .client)
        XCTAssertNil(board.items.first { $0.text == "Old news" }?.shownAt)
        XCTAssertEqual(board.items.first { $0.text == "Old news" }?.state, .expired)
    }

    func testDismissedItemsNeverComeBack() {
        var pacer = LiveRailPacer()
        pacer.spacing = 0
        var board = LiveRailBoard(pacer: pacer)
        let first = item("Ask about the budget")
        board.offer([first])
        board.advance(now: at(0), callType: .client)
        board.dismiss(first.id)
        XCTAssertTrue(board.nowItems.isEmpty)

        board.offer([item("ask about the budget."), item("Something new")])
        board.advance(now: at(5), callType: .client)
        board.advance(now: at(6), callType: .client)
        XCTAssertEqual(board.nowItems.map(\.text), ["Something new"])
        XCTAssertEqual(board.items.filter { LiveRailPacer.normalized($0.text) == "ask about the budget" }.count, 1)
    }

    func testPinnedThenDismissedAndExpiredCannotBePinned() {
        var pacer = LiveRailPacer()
        pacer.spacing = 0
        var board = LiveRailBoard(pacer: pacer)
        let card = item("Point")
        board.offer([card])
        board.advance(now: at(0), callType: .client)
        board.pin(card.id)
        board.dismiss(card.id)
        XCTAssertEqual(board.state(of: card.id), .dismissed)
        board.pin(card.id)
        XCTAssertEqual(board.state(of: card.id), .dismissed)
    }

    func testOwnSpeechHoldsAdmissionOnClientCallsOnly() {
        for (callType, shows) in [(CallType.client, false), (.research, true)] {
            var board = LiveRailBoard()
            board.noteSelfSpeech(at: at(9))
            board.offer([item("Say the renewal price")])
            board.advance(now: at(10), callType: callType)
            XCTAssertEqual(!board.nowItems.isEmpty, shows, "\(callType)")
        }
    }

    func testAnExplicitRequestShowsItsFirstCardAtOnceAndTheRestWait() {
        var board = LiveRailBoard()
        board.offer([item("Earlier card")])
        board.advance(now: at(0), callType: .client)
        board.noteSelfSpeech(at: at(9))
        board.offer([item("Asked A", arrived: 10), item("Asked B", arrived: 10), item("Flag C", .threads, arrived: 10)])
        let next = board.advance(now: at(10), callType: .client, explicit: true)
        XCTAssertEqual(board.nowItems.map(\.text), ["Asked A", "Earlier card"], "skips the spacing and the speech hold")
        XCTAssertEqual(board.requestedID, board.nowItems.first?.id)
        XCTAssertEqual(board.waitingCount(in: .now), 1)
        XCTAssertEqual(board.waitingCount(in: .threads), 1)
        XCTAssertEqual(next, at(70), "the rest wait for the normal spacing")
        board.advance(now: at(30), callType: .client)
        XCTAssertEqual(board.nowItems.count, 2, "a plain advance still keeps the spacing")
    }

    func testAnExplicitRequestStillSkipsDismissedRepeatsAndFullLanes() {
        let dismissed = item("Say the price")
        var board = LiveRailBoard()
        board.offer([dismissed])
        board.advance(now: at(0), callType: .client)
        board.dismiss(dismissed.id)
        board.offer([item("say the price.", arrived: 5)])
        board.advance(now: at(5), callType: .client, explicit: true)
        XCTAssertTrue(board.nowItems.isEmpty)
        XCTAssertNil(board.requestedID)
    }

    func testOnlySurfacedItemsCountAsSeenAndResetClearsAll() {
        var pacer = LiveRailPacer()
        pacer.spacing = 0
        var board = LiveRailBoard(pacer: pacer)
        board.offer([item("A"), item("B")])
        board.advance(now: at(0), callType: .client)
        XCTAssertEqual(board.surfaced.map(\.text), ["A"], "B still waits: not surfaced")
        board.advance(now: at(2), callType: .client)
        XCTAssertEqual(board.surfaced.map(\.text), ["A", "B"])
        board.reset()
        XCTAssertTrue(board.items.isEmpty)
        XCTAssertTrue(board.surfaced.isEmpty)
        XCTAssertNil(board.lastAdmitAt)
        XCTAssertEqual(board.pacer, pacer, "reset keeps the pacer's limits")
    }

    func testACardThatFadedUnseenCanComeBackButASeenOneCannot() {
        var board = LiveRailBoard()
        board.offer([item("Seen card"), item("Unseen card")])
        board.advance(now: at(0), callType: .client)
        board.advance(now: at(240), callType: .client)
        XCTAssertEqual(board.items.first { $0.text == "Unseen card" }?.state, .expired)
        XCTAssertNil(board.items.first { $0.text == "Unseen card" }?.shownAt)
        XCTAssertEqual(board.surfaced.map(\.text), ["Seen card"], "a card that expired unseen was never surfaced")

        XCTAssertFalse(board.repeatsKnownItem("unseen card."), "never shown: a later pass may offer it again")
        XCTAssertTrue(board.repeatsKnownItem("seen card"), "shown, then faded: still a repeat")

        board.offer([item("Unseen card", arrived: 250), item("Seen card", arrived: 250)])
        XCTAssertEqual(board.items.filter { $0.state == .new }.map(\.text), ["Unseen card"])
        XCTAssertTrue(board.repeatsKnownItem("Unseen card"), "a waiting card is not offered twice")
        board.offer([item("Unseen card", arrived: 251)])
        XCTAssertEqual(board.waitingCount, 1)
        board.advance(now: at(300), callType: .client)
        XCTAssertEqual(board.nowItems.map(\.text), ["Unseen card"], "the returned card shows")
    }

    func testOneOfferSkipsItsOwnRepeats() {
        var board = LiveRailBoard()
        board.offer([item("Same"), item("same.")])
        XCTAssertEqual(board.waitingCount, 1)
    }
}
