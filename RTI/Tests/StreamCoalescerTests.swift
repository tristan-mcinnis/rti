import RTICore
import XCTest

/// Streamed deltas reach the answer in groups, and nothing is lost.
final class StreamCoalescerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    func testFirstDeltaIsWrittenAtOnce() {
        var coalescer = StreamCoalescer()
        XCTAssertEqual(coalescer.append("Hello", now: start), "Hello")
        XCTAssertEqual(coalescer.pending, "")
    }

    func testDeltasInsideTheIntervalWaitThenGoTogether() {
        var coalescer = StreamCoalescer()
        _ = coalescer.append("A", now: start)
        XCTAssertNil(coalescer.append("B", now: start.addingTimeInterval(0.02)))
        XCTAssertNil(coalescer.append("C", now: start.addingTimeInterval(0.05)))
        XCTAssertEqual(coalescer.append("D", now: start.addingTimeInterval(0.08)), "BCD")
    }

    func testParagraphBreakWritesAtOnce() {
        var coalescer = StreamCoalescer()
        _ = coalescer.append("One.", now: start)
        XCTAssertEqual(coalescer.append("\n\nTwo", now: start.addingTimeInterval(0.01)), "\n\nTwo")
        XCTAssertNil(coalescer.append("\n", now: start.addingTimeInterval(0.02)))
        XCTAssertEqual(coalescer.append("\nThree", now: start.addingTimeInterval(0.03)), "\n\nThree")
    }

    func testFlushReturnsEverythingSoTheJoinedTextIsComplete() {
        var coalescer = StreamCoalescer(interval: 3600)
        let deltas = ["The ", "answer ", "is ", "forty", "-two", "."]
        var written = ""
        for (index, delta) in deltas.enumerated() {
            written += coalescer.append(delta, now: start.addingTimeInterval(Double(index) * 0.001)) ?? ""
        }
        XCTAssertEqual(written, "The ", "only the first delta is written inside the interval")
        written += coalescer.flush(now: start.addingTimeInterval(1))
        XCTAssertEqual(written, deltas.joined())
        XCTAssertEqual(coalescer.flush(now: start.addingTimeInterval(2)), "")
    }

    func testResetDropsTheBufferAndWritesTheNextFirstDeltaAtOnce() {
        var coalescer = StreamCoalescer()
        _ = coalescer.append("old", now: start)
        _ = coalescer.append(" tail", now: start.addingTimeInterval(0.01))
        coalescer.reset()
        XCTAssertEqual(coalescer.pending, "")
        XCTAssertEqual(coalescer.append("new", now: start.addingTimeInterval(0.02)), "new")
    }
}
