import RTICore
import XCTest

/// Auto's project search must stay small on an 8 GB M1: `.utility`, two
/// workers, 300 ms, a per-session cache, and at most one search in three
/// passes. Invented text only.
final class VaultSearchBudgetTests: XCTestCase {
    private var tmp: URL!
    private var previousConfigHome: String?
    private static let fileCount = 3000

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-vault-budget-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let project = tmp.appendingPathComponent("kb/projects/big", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let filler = String(repeating: "Shoppers compare running shoes by cushioning, price and weight in the store. ", count: 25)
        for index in 0 ..< Self.fileCount {
            let body = index == 1234 ? "# Lantern pricing\nLantern pricing packaging decision for the battery.\n" : "# Note \(index)\n"
            try (body + filler).write(to: project.appendingPathComponent("note-\(index).md"), atomically: false, encoding: .utf8)
        }
        let home = tmp.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "recordings_dir": tmp.appendingPathComponent("kb/meetings/recordings").path,
            "project_roots": [String](),
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent("config.json"))
        previousConfigHome = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        setenv("RTI_CONFIG_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousConfigHome {
            setenv("RTI_CONFIG_HOME", previousConfigHome, 1)
        } else {
            unsetenv("RTI_CONFIG_HOME")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    func testAutoBudgetStopsAt300MillisecondsAndUnderOneCPUSecond() {
        let cache = VaultSearch.DocumentCache()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = cpuSeconds()
        _ = VaultSearch.search(query: "lantern pricing packaging battery", scopeRelativePath: "projects/big",
                               broaden: false, budget: .auto, cache: cache)
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000_000
        let cpu = cpuSeconds() - cpuStart
        print("Auto vault search over \(Self.fileCount) files: wall \(wall) s, CPU \(cpu) s, files read \(cache.reads)")
        // The walk and the score both stop at the limit; a little slack for
        // the last file in flight and a loaded test machine.
        XCTAssertLessThan(wall, 0.45)
        XCTAssertLessThan(cpu, 1.0)
    }

    func testTheCacheReadsAFileOnceUntilItChanges() throws {
        let cache = VaultSearch.DocumentCache()
        let budget = VaultSearch.Budget(qos: .utility, workers: 2, timeLimit: nil)
        let first = VaultSearch.search(query: "lantern pricing packaging battery", scopeRelativePath: "projects/big",
                                       broaden: false, budget: budget, cache: cache)
        XCTAssertEqual(first.map(\.relativePath), ["projects/big/note-1234.md"])
        XCTAssertEqual(cache.reads, Self.fileCount)
        let again = VaultSearch.search(query: "lantern pricing packaging battery", scopeRelativePath: "projects/big",
                                       broaden: false, budget: budget, cache: cache)
        XCTAssertEqual(again, first)
        XCTAssertEqual(cache.reads, Self.fileCount, "a repeat search reads nothing again")
        let changed = tmp.appendingPathComponent("kb/projects/big/note-7.md")
        try "# Lantern pricing battery packaging\nUpdated.".write(to: changed, atomically: true, encoding: .utf8)
        _ = VaultSearch.search(query: "lantern", scopeRelativePath: "projects/big", broaden: false, budget: budget, cache: cache)
        XCTAssertEqual(cache.reads, Self.fileCount + 1, "only the changed file is read again")
    }

    func testCancellingTheTaskStopsTheScan() async {
        let task = Task {
            await VaultSearch.retrieve(query: "lantern pricing packaging battery", scopeRelativePath: "projects/big",
                                       broaden: false, budget: VaultSearch.Budget(qos: .utility, workers: 1, timeLimit: nil))
        }
        task.cancel()
        let start = DispatchTime.now().uptimeNanoseconds
        _ = await task.value
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000, 0.5)
    }

    /// A clock for the budget that moves 1 ms each time it is read, so
    /// the walk and read limits are tested without real timing.
    private final class TickClock: @unchecked Sendable {
        private let lock = NSLock()
        private var ticks: UInt64 = 0
        var count: UInt64 {
            lock.withLock { ticks }
        }

        func now() -> UInt64 {
            lock.withLock {
                ticks += 1
                return ticks * 1_000_000
            }
        }
    }

    /// Flips to true after a set number of checks: a cancel that lands
    /// while the scan runs.
    private final class LateCancel: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        private let after: Int
        init(after: Int) {
            self.after = after
        }

        func check() -> Bool {
            lock.withLock {
                checks += 1
                return checks > after
            }
        }
    }

    func testAWalkThatUsesItsShareStillReadsFiles() {
        // 300 ms limit, 1 ms per clock read: the walk stops near 150 ms,
        // long before 3,000 files, and each worker still reads its minimum.
        let clock = TickClock()
        let cache = VaultSearch.DocumentCache()
        _ = VaultSearch.search(query: "lantern pricing packaging battery", scopeRelativePath: "projects/big",
                               broaden: false, budget: .auto, cache: cache, now: { clock.now() })
        XCTAssertGreaterThanOrEqual(cache.reads, 2 * 8, "a cold cache warms even when the walk used its share")
        XCTAssertLessThan(cache.reads, 200, "the walk stopped at its share of the limit")
    }

    func testTheWalkStopsOnFilesThatAreNotMarkdown() throws {
        // Only decks and images: no markdown reaches the read phase, so every
        // clock read comes from the walk checking each enumerated item.
        let decks = tmp.appendingPathComponent("kb/projects/decks", isDirectory: true)
        try FileManager.default.createDirectory(at: decks, withIntermediateDirectories: true)
        for index in 0 ..< 1000 {
            FileManager.default.createFile(atPath: decks.appendingPathComponent("slide-\(index).png").path, contents: Data())
        }
        let clock = TickClock()
        let results = VaultSearch.search(query: "lantern pricing", scopeRelativePath: "projects/decks",
                                         broaden: false, budget: .auto, now: { clock.now() })
        XCTAssertEqual(results, [])
        // One read to start, then one per item until 150 ms: about 151.
        XCTAssertGreaterThanOrEqual(clock.count, 150)
        XCTAssertLessThan(clock.count, 160)
    }

    func testProjectRootWalkChecksEveryItem() throws {
        let folder = tmp.appendingPathComponent("root-walk", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0 ..< 40 {
            FileManager.default.createFile(atPath: folder.appendingPathComponent("deck-\(index).pptx").path, contents: Data())
        }
        var checks = 0
        var visited = 0
        ProjectRoots.walkFiles(under: folder, shouldStop: {
            checks += 1
            return false
        }) { _ in
            visited += 1
            return true
        }
        XCTAssertEqual(checks, 40)
        XCTAssertEqual(visited, 0)
        checks = 0
        ProjectRoots.walkFiles(under: folder, shouldStop: {
            checks += 1
            return checks > 10
        }) { _ in true }
        XCTAssertEqual(checks, 11, "the walk stops at the first true")
    }

    func testACancelDuringTheWalkStopsBeforeReading() {
        let cancel = LateCancel(after: 100)
        let cache = VaultSearch.DocumentCache()
        _ = VaultSearch.search(query: "lantern pricing packaging battery", scopeRelativePath: "projects/big", broaden: false,
                               budget: VaultSearch.Budget(qos: .utility, workers: 1, timeLimit: nil), cache: cache,
                               isCancelled: { cancel.check() })
        XCTAssertEqual(cache.reads, 0)
    }

    func testACancelDuringTheReadStopsMidway() {
        // The walk makes one check per file (3,000), then each read makes one.
        let cancel = LateCancel(after: Self.fileCount + 500)
        let cache = VaultSearch.DocumentCache()
        _ = VaultSearch.search(query: "lantern pricing packaging battery", scopeRelativePath: "projects/big", broaden: false,
                               budget: VaultSearch.Budget(qos: .utility, workers: 1, timeLimit: nil), cache: cache,
                               isCancelled: { cancel.check() })
        XCTAssertGreaterThan(cache.reads, 0)
        XCTAssertLessThan(cache.reads, Self.fileCount)
    }

    func testTheCacheStopsGrowingAtItsByteLimit() {
        let cache = VaultSearch.DocumentCache(byteLimit: 100_000)
        let budget = VaultSearch.Budget(qos: .utility, workers: 2, timeLimit: nil)
        let first = VaultSearch.search(query: "lantern pricing packaging battery", scopeRelativePath: "projects/big",
                                       broaden: false, budget: budget, cache: cache)
        XCTAssertEqual(first.map(\.relativePath), ["projects/big/note-1234.md"], "files past the limit are still searched")
        XCTAssertLessThanOrEqual(cache.bytes, 100_000)
        XCTAssertGreaterThan(cache.bytes, 90000)
        XCTAssertFalse(first[0].excerpt.isEmpty, "the excerpt is read from disk in its own case")
        XCTAssertTrue(first[0].excerpt.contains("Lantern"))
    }

    func testAutoSearchesAtMostOnceEveryThreePasses() {
        var cadence = AutoVaultCadence()
        let pattern = (0 ..< 9).map { _ in cadence.shouldSearch() }
        XCTAssertEqual(pattern, [true, false, false, true, false, false, true, false, false])
        XCTAssertEqual(VaultSearch.Budget.auto, VaultSearch.Budget(qos: .utility, workers: 2, timeLimit: 0.3))
    }
}
