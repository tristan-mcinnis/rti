import XCTest

@MainActor
final class PaletteSearchTests: XCTestCase {

    private func cmd(_ id: String, _ title: String = "Cmd") -> RTICommand {
        RTICommand(id: id, title: title, perform: {})
    }

    func test_compose_mapsCommandsInOrder() {
        let results = PaletteSearch.compose(commands: [cmd("a"), cmd("b")])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.isCommand })
        XCTAssertEqual(results.map(\.id), ["cmd:a", "cmd:b"])
    }

    func test_compose_emptyCommands_isEmpty() {
        XCTAssertTrue(PaletteSearch.compose(commands: []).isEmpty)
    }

    func test_resultId_isNamespaced() {
        let results = PaletteSearch.compose(commands: [cmd("x")])
        XCTAssertEqual(results[0].id, "cmd:x")
    }
}
