import XCTest

/// Spawns the actual `rti-mcp` binary as a subprocess and exercises every
/// tool over real JSON-RPC stdio. Stands in for the manual smoke test of
/// the read-path documented in the spec under "Verification" → Phase 5.
///
/// The binary is built before this test runs (it's a sibling target in
/// the same Xcode scheme); we locate it via the test bundle's
/// `BUILT_PRODUCTS_DIR` neighbours.
final class MCPSpawnIntegrationTests: XCTestCase {

    private var fixtureDir: URL!
    private var binaryURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-mcp-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)

        binaryURL = try locateBinary()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
        try await super.tearDown()
    }

    // MARK: - locate the built binary

    private func locateBinary() throws -> URL {
        // The xctest bundle lives alongside the rti-mcp executable in
        // `Build/Products/Debug/`. Walk up from the bundle to the products
        // dir and look for the binary.
        let bundleURL = Bundle(for: Self.self).bundleURL
        let productsDir = bundleURL.deletingLastPathComponent()
        let candidate = productsDir.appendingPathComponent("rti-mcp")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // Fall back to a glob in DerivedData if the layout shifts.
        throw XCTSkip("rti-mcp binary not found at \(candidate.path) — build the RTIMCP target first.")
    }

    // MARK: - JSON-RPC plumbing

    /// Runs the binary against the fixture corpus, pipes the given
    /// requests in over stdin, and returns the parsed JSON-RPC responses.
    private func driveMCP(_ requests: [String]) throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["--corpus", fixtureDir.path]

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()

        for req in requests {
            try stdin.fileHandleForWriting.write(contentsOf: Data((req + "\n").utf8))
        }
        try stdin.fileHandleForWriting.close()

        // Wait briefly for the binary to drain stdin and write responses,
        // then close the read side. Process.waitUntilExit blocks on the
        // child terminating, which it will once stdin reaches EOF.
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let lines = String(data: outData, encoding: .utf8)?
            .split(separator: "\n")
            .filter { !$0.isEmpty } ?? []

        return try lines.map { line in
            guard let data = line.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "MCPSpawnIntegrationTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Could not parse JSON-RPC line: \(line)"
                ])
            }
            return obj
        }
    }

    // MARK: - fixture helpers

    private func writeFixtureMeeting(
        date: String,
        slug: String,
        id: String,
        title: String,
        body: String
    ) throws {
        let yaml = """
        ---
        id: \(id)
        date: \(date)T10:00:00Z
        title: \(title)
        attendees:
          - Tristan
          - Alex
        ---
        \(body)
        """
        let url = fixtureDir.appendingPathComponent("\(date)-\(slug).md")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - tests

    func test_initialize_returnsServerInfo() throws {
        let responses = try driveMCP([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        ])
        XCTAssertEqual(responses.count, 1)
        let result = responses[0]["result"] as? [String: Any]
        XCTAssertNotNil(result)
        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "rti-mcp")
    }

    func test_toolsList_returnsCoreTools() throws {
        let responses = try driveMCP([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        ])
        let listing = responses.first(where: { ($0["id"] as? Int) == 2 })
        let result = listing?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertNotNil(tools)
        let names = Set(tools?.compactMap { $0["name"] as? String } ?? [])
        let core: Set<String> = ["search_corpus", "read_meeting", "list_meetings", "read_live_transcript"]
        XCTAssertTrue(core.isSubset(of: names), "Expected core tools \(core) in \(names)")
    }

    func test_listMeetings_returnsFixtureFiles() throws {
        try writeFixtureMeeting(
            date: "2026-05-03",
            slug: "alpha",
            id: "fixture-1",
            title: "Alpha meeting",
            body: "## Summary\nHello.\n\n## Transcript\n[self 0:00] yo"
        )
        try writeFixtureMeeting(
            date: "2026-05-04",
            slug: "beta",
            id: "fixture-2",
            title: "Beta meeting",
            body: "## Summary\nWorld.\n\n## Transcript\n[self 0:00] hi"
        )

        let responses = try driveMCP([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_meetings","arguments":{"limit":10}}}"#
        ])

        let call = responses.first(where: { ($0["id"] as? Int) == 2 })
        let result = call?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? "{}"
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let meetings = payload?["meetings"] as? [[String: Any]]
        XCTAssertEqual(meetings?.count, 2)
        let titles = Set(meetings?.compactMap { $0["title"] as? String } ?? [])
        XCTAssertEqual(titles, ["Alpha meeting", "Beta meeting"])
    }

    func test_readMeeting_byPath_returnsParsedFrontmatterAndBody() throws {
        try writeFixtureMeeting(
            date: "2026-05-03",
            slug: "pricing",
            id: "fixture-x",
            title: "Pricing",
            body: "## Summary\nDecided to go monthly.\n\n## Transcript\n[self 0:00] hello"
        )

        let path = fixtureDir.appendingPathComponent("2026-05-03-pricing.md").path
        let req = """
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_meeting","arguments":{"path":"\(path)"}}}
        """

        let responses = try driveMCP([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            req
        ])

        let call = responses.first(where: { ($0["id"] as? Int) == 2 })
        let result = call?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? "{}"
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let fm = payload?["frontmatter"] as? [String: Any]
        XCTAssertEqual(fm?["title"] as? String, "Pricing")
        XCTAssertEqual(fm?["id"] as? String, "fixture-x")
        let body = payload?["body"] as? String ?? ""
        XCTAssertTrue(body.contains("Decided to go monthly"))
    }

    func test_readLiveTranscript_returnsEmptyWhenNoSession() throws {
        let responses = try driveMCP([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_live_transcript","arguments":{}}}"#
        ])

        let call = responses.first(where: { ($0["id"] as? Int) == 2 })
        let result = call?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        // Empty events array is the contract when no session is active.
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? "{}"
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let events = payload?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 0)
    }

    func test_unknownMethod_returnsMethodNotFound() throws {
        let responses = try driveMCP([
            #"{"jsonrpc":"2.0","id":1,"method":"some_unknown_method","params":{}}"#
        ])
        XCTAssertEqual(responses.count, 1)
        let error = responses[0]["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
    }
}
