import Foundation
import RTICore
import XCTest

/// Perf fix 7: one alternation regex per pinned stimulus package. All codes
/// and text are invented.
final class StimulusCodeMatcherTests: XCTestCase {
    func testMatchesWholeCodesOnly() {
        let matcher = StimulusCodeMatcher(codes: ["A1", "A12", "B2", "not a code", "C"])
        XCTAssertEqual(matcher.codes, ["A1", "A12", "B2"])
        XCTAssertEqual(matcher.mentioned(in: "我更喜欢A12，不是A1。"), ["A1", "A12"])
        XCTAssertEqual(matcher.mentioned(in: "XA1 and A1B and B23"), [], "a code inside a longer token is not a mention")
        XCTAssertEqual(matcher.mentioned(in: "b2 is not B2"), ["B2"], "codes are case-sensitive")
        XCTAssertEqual(matcher.mentioned(in: "B2, B2 again"), ["B2"])
        XCTAssertEqual(StimulusCodeMatcher(codes: []).mentioned(in: "A1"), [])
    }

    func testThirtyCodesOverAHundredTurnsStaysFast() {
        let codes = (1 ... 30).map { "\(["A", "B", "C"][$0 % 3])\($0)" }
        let matcher = StimulusCodeMatcher(codes: codes)
        let turns = (0 ..< 100).map { "第\($0)个回答：我觉得\(codes[$0 % 30])比较好，因为它的包装看起来更清爽，也更像早餐会喝的东西。" }
        var best = Double.infinity
        for _ in 0 ..< 5 {
            let start = ContinuousClock.now
            let found = turns.map(matcher.mentioned(in:))
            let elapsed = ContinuousClock.now - start
            XCTAssertEqual(found.filter { $0.count == 1 }.count, 100)
            best = min(best, Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        // Target under 2 ms (perf fix 7). The bound leaves room for a busy
        // CI machine; the old code compiled about 3,000 regexes here.
        XCTAssertLessThan(best, 10, "best of five took \(best) ms")
    }
}
