import XCTest

/// docs/workflows/flows.json drew the removed corpus, import and panel
/// flows for months because nothing checked it. Every package file and
/// every step's `path · symbol` ref must exist in the source tree.
final class WorkflowDocTests: XCTestCase {
    private struct Doc: Decodable {
        struct Subsystem: Decodable { let id: String }
        struct Package: Decodable { let id, subsystem, file: String }
        struct Step: Decodable { let from, to, ref: String }
        struct Flow: Decodable { let id: String; let steps: [Step] }
        let subsystems: [Subsystem]
        let packages: [Package]
        let flows: [Flow]
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // RTI
            .deletingLastPathComponent()  // repo
    }

    func test_flowsDoc_pointsAtCodeThatExists() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("docs/workflows/flows.json"))
        let doc = try JSONDecoder().decode(Doc.self, from: data)
        let subsystems = Set(doc.subsystems.map(\.id))
        let packages = Set(doc.packages.map(\.id))

        for package in doc.packages {
            XCTAssertTrue(subsystems.contains(package.subsystem), "\(package.id): unknown subsystem \(package.subsystem)")
            XCTAssertTrue(exists(package.file), "\(package.id): \(package.file) is missing")
        }
        for flow in doc.flows {
            for step in flow.steps {
                XCTAssertTrue(packages.contains(step.from), "\(flow.id): unknown package \(step.from)")
                XCTAssertTrue(packages.contains(step.to), "\(flow.id): unknown package \(step.to)")
                let parts = step.ref.components(separatedBy: " · ")
                XCTAssertEqual(parts.count, 2, "\(flow.id): ref must be 'path · symbol': \(step.ref)")
                guard parts.count == 2 else { continue }
                let source = try? String(contentsOf: repoRoot.appendingPathComponent(parts[0]), encoding: .utf8)
                XCTAssertNotNil(source, "\(flow.id): \(parts[0]) is missing")
                XCTAssertTrue(source?.contains(parts[1]) == true, "\(flow.id): '\(parts[1])' is not in \(parts[0])")
            }
        }
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(relativePath).path)
    }
}
