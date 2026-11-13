import RTICore
import XCTest

/// Log lines reach the daily file in batches: one write per day file per
/// flush, not one open, seek, write and close per line.
final class LogFileBatchTests: XCTestCase {
    func testLinesAreWrittenInOneBatchPerDay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rti-logbatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let batch = LogFileBatch(queue: DispatchQueue(label: "test.logbatch")) { day in
            dir.appendingPathComponent("rti-\(day).log")
        }
        for index in 0 ..< 200 {
            batch.enqueue("line \(index)\n", day: index < 150 ? "2026-11-12" : "2026-11-13")
        }
        batch.flushNow()
        XCTAssertEqual(batch.writes, 2)
        let first = try String(contentsOf: dir.appendingPathComponent("rti-2026-11-12.log"), encoding: .utf8)
        let second = try String(contentsOf: dir.appendingPathComponent("rti-2026-11-13.log"), encoding: .utf8)
        XCTAssertEqual(first.split(separator: "\n").count, 150)
        XCTAssertEqual(second.split(separator: "\n").last, "line 199")

        batch.enqueue("later\n", day: "2026-11-13")
        batch.flushNow()
        XCTAssertEqual(batch.writes, 3)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("rti-2026-11-13.log"), encoding: .utf8).hasSuffix("line 199\nlater\n"))
    }

    func testAnErrorLineIsWrittenWithoutTheDelay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rti-logbatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.logbatch.urgent")
        let batch = LogFileBatch(queue: queue) { dir.appendingPathComponent("rti-\($0).log") }
        batch.enqueue("boom\n", day: "d", urgent: true)
        queue.sync {}
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("rti-d.log"), encoding: .utf8), "boom\n")
    }
}
