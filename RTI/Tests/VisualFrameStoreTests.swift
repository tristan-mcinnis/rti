@testable import RTICore
import XCTest

final class VisualFrameStoreTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() {
        super.setUp()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("visual-frame-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        super.tearDown()
    }

    func testStagingDirectoryIsDeterministicForOneSessionStart() {
        let startedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let first = VisualFrameStore.stagingDirectory(configHome: temporaryRoot, startedAt: startedAt)
        let second = VisualFrameStore.stagingDirectory(configHome: temporaryRoot, startedAt: startedAt)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.path.contains("frame-staging/frames-"))
    }

    func testFrameFilenameShape() {
        let name = VisualFrameStore.frameFilename(offsetSeconds: 65, trigger: "Ambient!", unique: "ab12")
        XCTAssertEqual(name, "frame-00065-ambient-ab12.jpg")
        let fallback = VisualFrameStore.frameFilename(offsetSeconds: -3, trigger: "___", unique: "cd34")
        XCTAssertEqual(fallback, "frame-00000-capture-cd34.jpg")
    }

    func testWriteFrameCreatesOwnerOnlyFile() throws {
        let staging = temporaryRoot.appendingPathComponent("staging", isDirectory: true)
        let name = try VisualFrameStore.writeFrame(
            Data([0xFF, 0xD8, 0x01]),
            offsetSeconds: 7,
            trigger: "manual",
            stagingDirectory: staging
        )
        let url = staging.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xFF, 0xD8, 0x01]))
    }

    func testPromoteMovesJPEGsAndRemovesStaging() throws {
        let staging = temporaryRoot.appendingPathComponent("staging", isDirectory: true)
        try VisualFrameStore.writeFrame(Data([0x01]), offsetSeconds: 1, trigger: "ambient", stagingDirectory: staging)
        try VisualFrameStore.writeFrame(Data([0x02]), offsetSeconds: 2, trigger: "manual", stagingDirectory: staging)
        try Data([0x03]).write(to: staging.appendingPathComponent("notes.txt"))

        let sessionDirectory = temporaryRoot.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let moved = VisualFrameStore.promoteStagedFrames(stagingDirectory: staging, into: sessionDirectory)
        XCTAssertEqual(moved, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))

        let framesDirectory = sessionDirectory.appendingPathComponent("frames", isDirectory: true)
        let promoted = try FileManager.default.contentsOfDirectory(atPath: framesDirectory.path).sorted()
        XCTAssertEqual(promoted.count, 2)
        XCTAssertTrue(promoted.allSatisfy { $0.hasSuffix(".jpg") })
    }

    func testPromoteWithNoStagingDirectoryIsQuietlyZero() {
        let missing = temporaryRoot.appendingPathComponent("nothing-here", isDirectory: true)
        let sessionDirectory = temporaryRoot.appendingPathComponent("session", isDirectory: true)
        XCTAssertEqual(VisualFrameStore.promoteStagedFrames(stagingDirectory: missing, into: sessionDirectory), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("frames").path))
    }
}
