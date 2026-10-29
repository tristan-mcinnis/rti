import XCTest
import RTICore

/// The read-only project root: client folders at `<root>/<client>/<year>/<project>`
/// show in the picker and are reachable by search, grep, list and read under a
/// `work/` prefix, and nothing escapes the root.
final class ProjectRootsTests: XCTestCase {
    private var tmp: URL!
    private var work: URL!
    private var previousConfigHome: String?
    private let year = Calendar(identifier: .gregorian).component(.year, from: Date())

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-project-roots-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        work = tmp.appendingPathComponent("Work", isDirectory: true)
        let kb = tmp.appendingPathComponent("kb", isDirectory: true)
        try write("# KB status", to: kb.appendingPathComponent("projects/personal/00-status.md"))

        let af1 = work.appendingPathComponent("Acme/\(year)/acme-launch", isDirectory: true)
        try write("# AF1 status\nReadout today.", to: af1.appendingPathComponent("00-status.md"))
        try write("# AF1 project", to: af1.appendingPathComponent("PROJECT.md"))
        try write("Harbor Loft venue notes from the walk.",
                  to: af1.appendingPathComponent("07-fieldwork/transcripts/harbor-loft.txt"))
        try write("Harbor Loft photo caption", to: af1.appendingPathComponent("07-fieldwork/participant-media/caption.md"))
        try write("# Old", to: work.appendingPathComponent("Acme/\(year - 1)/acme-tennis/00-status.md"))
        try write("# Too old", to: work.appendingPathComponent("Acme/\(year - 2)/acme-old/00-status.md"))
        try write("# No status", to: work.appendingPathComponent("Acme/\(year)/no-status/PROJECT.md"))
        try write("secret", to: tmp.appendingPathComponent("outside.md"))

        let home = tmp.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "recordings_dir": kb.appendingPathComponent("meetings/recordings").path,
            "project_roots": [work.path],
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

    func testPickerListsThisAndLastYearsProjectsWithStatus() {
        let names = VaultWorkstreamStore.projects().map(\.name)
        XCTAssertTrue(names.contains("Acme · acme-launch"), "\(names)")
        XCTAssertTrue(names.contains("Acme · acme-tennis"), "\(names)")
        XCTAssertFalse(names.contains("Acme · acme-old"))
        XCTAssertFalse(names.contains("Acme · no-status"))
        XCTAssertTrue(names.contains("Personal"), "knowledge-base projects stay listed")
    }

    func testPickedProjectScopesToWorkPathAndLoadsStatus() throws {
        let item = try XCTUnwrap(VaultWorkstreamStore.projects().first { $0.name == "Acme · acme-launch" })
        XCTAssertEqual(VaultWorkstreamStore.scopeRelativePath(for: item), "work/Acme/\(year)/acme-launch")
        XCTAssertTrue(VaultWorkstreamStore.context(for: item).contains("Readout today."))
    }

    func testPathMappingAndEscapeGuard() {
        let resolved = VaultFiles.resolve("work/Acme/\(year)/acme-launch/00-status.md")
        XCTAssertEqual(resolved?.path, work.appendingPathComponent("Acme/\(year)/acme-launch/00-status.md").path)
        XCTAssertNil(VaultFiles.resolve("work/../outside.md"))
        XCTAssertNil(VaultFiles.resolve("work/Acme/../../outside.md"))
        XCTAssertTrue(VaultFiles.read(relativePath: "work/../outside.md").hasPrefix("Refused:"))
    }

    func testSymlinkOutOfRootRefused() throws {
        let link = work.appendingPathComponent("Acme/\(year)/acme-launch/escape.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp.appendingPathComponent("outside.md"))
        XCTAssertNil(VaultFiles.resolve("work/Acme/\(year)/acme-launch/escape.md"))
    }

    func testSymlinkedFileIsNotGrepped() throws {
        let link = work.appendingPathComponent("Acme/\(year)/acme-launch/linked.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp.appendingPathComponent("outside.md"))
        let grep = VaultFiles.grep(query: "secret", scopeRelativePath: "work/Acme/\(year)/acme-launch")
        XCTAssertFalse(grep.contains("linked.md"), grep)
    }

    func testKnowledgeBaseFoldersAreNotListedTwice() throws {
        let kb = tmp.appendingPathComponent("Work/Inner-Chapter", isDirectory: true)
        try write("# Internal", to: kb.appendingPathComponent("\(year)/ai-services/00-status.md"))
        let roots = ProjectRoots.roots(config: ["project_roots": [work.path]])
        let names = ProjectRoots.projects(roots: roots, knowledgeBase: kb).map(\.name)
        XCTAssertFalse(names.contains("Inner-Chapter · ai-services"), "\(names)")
        XCTAssertTrue(names.contains("Acme · acme-launch"))
    }

    func testScopedSearchFindsTranscriptTextAndSkipsMedia() {
        let results = VaultSearch.search(query: "Harbor Loft", scopeRelativePath: "work/Acme/\(year)/acme-launch")
        let paths = results.map(\.relativePath)
        XCTAssertTrue(paths.contains("work/Acme/\(year)/acme-launch/07-fieldwork/transcripts/harbor-loft.txt"), "\(paths)")
        XCTAssertFalse(paths.contains { $0.contains("participant-media") })
    }

    func testUnscopedSearchReachesThisYearsProjects() {
        let paths = VaultSearch.search(query: "Harbor Loft").map(\.relativePath)
        XCTAssertTrue(paths.contains { $0.hasPrefix("work/Acme/\(year)/acme-launch/") }, "\(paths)")
    }

    func testToolPathRoundTrip() {
        let scope = "work/Acme/\(year)/acme-launch"
        let grep = VaultFiles.grep(query: "Loft venue", scopeRelativePath: scope)
        let path = "\(scope)/07-fieldwork/transcripts/harbor-loft.txt"
        XCTAssertTrue(grep.contains("• \(path)"), grep)
        XCTAssertFalse(grep.contains("participant-media"))

        let list = VaultFiles.list(scopeRelativePath: scope, pattern: nil)
        XCTAssertTrue(list.contains(path), list)
        XCTAssertFalse(list.contains("participant-media"), list)

        XCTAssertEqual(VaultFiles.read(relativePath: path), "Harbor Loft venue notes from the walk.")
    }

    func testEmptyProjectRootsTurnsItOff() {
        XCTAssertTrue(ProjectRoots.roots(config: ["project_roots": [String]()]).isEmpty)
        XCTAssertEqual(ProjectRoots.roots(config: [:]).first?.prefix, "work")
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
