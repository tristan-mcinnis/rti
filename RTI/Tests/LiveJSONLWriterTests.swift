import XCTest

final class LiveJSONLWriterTests: XCTestCase {

    private var tmpURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-jsonl-\(UUID().uuidString).jsonl")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpURL)
        try await super.tearDown()
    }

    func test_appendAndRead_roundTripsEvents() throws {
        let writer = LiveJSONLWriter(url: tmpURL)
        try writer.open()
        writer.append(.word(ts: 100, speaker: 0, text: "hello", isFinal: true, confidence: 0.9, channel: "mic"))
        writer.append(.note(ts: 1000, text: "follow up"))
        writer.append(.chat(ts: 2000, role: "user", content: "what was decided"))
        writer.close()

        let events = try LiveJSONLReader.readAll(tmpURL)
        XCTAssertEqual(events.count, 3)
    }

    func test_concurrentAppends_preserveCount() throws {
        let writer = LiveJSONLWriter(url: tmpURL)
        try writer.open()
        let total = 200
        let group = DispatchGroup()
        for i in 0..<total {
            group.enter()
            DispatchQueue.global().async {
                writer.append(.word(ts: i, speaker: 0, text: "w\(i)", isFinal: true, confidence: 1.0, channel: "mic"))
                group.leave()
            }
        }
        group.wait()
        writer.close()

        // Give the serial write queue time to drain (close() syncs through it).
        let events = try LiveJSONLReader.readAll(tmpURL)
        XCTAssertEqual(events.count, total)
    }

    func test_readSince_returnsOnlyNewEvents() throws {
        let writer = LiveJSONLWriter(url: tmpURL)
        try writer.open()
        writer.append(.word(ts: 0, speaker: 0, text: "a", isFinal: true, confidence: 1, channel: "mic"))
        writer.append(.word(ts: 100, speaker: 0, text: "b", isFinal: true, confidence: 1, channel: "mic"))
        writer.append(.word(ts: 200, speaker: 0, text: "c", isFinal: true, confidence: 1, channel: "mic"))
        writer.close()

        let result = try LiveJSONLReader.readSince(tmpURL, sinceLine: 1)
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.nextLine, 3)
    }

    func test_readSince_pastEnd_returnsEmpty() throws {
        let writer = LiveJSONLWriter(url: tmpURL)
        try writer.open()
        writer.append(.word(ts: 0, speaker: 0, text: "a", isFinal: true, confidence: 1, channel: "mic"))
        writer.close()

        let result = try LiveJSONLReader.readSince(tmpURL, sinceLine: 5)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.nextLine, 1)
    }

    func test_deleteFile_removesIt() throws {
        let writer = LiveJSONLWriter(url: tmpURL)
        try writer.open()
        writer.append(.note(ts: 0, text: "x"))
        writer.deleteFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
    }
}
