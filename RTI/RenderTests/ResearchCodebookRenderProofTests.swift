import Foundation
import HouseDesign
import SwiftUI
import XCTest

/// The Codebook tab as a list of meanings: emic names with a gloss, quote
/// counts, a tension with both sides, a vote with counts, hypotheses for and
/// against, a client question's status. An older person card loads but is
/// not shown. Light and dark. Invented fixture. PNG prefix `codebook-`.
final class ResearchCodebookRenderProofTests: RenderProofTestCase {
    override func tearDown() async throws {
        ResearchCodebookController.shared.seedForRenderProof(ResearchCodebook())
        try await super.tearDown()
    }

    func testCodebookTabShowsMeanings() throws {
        var book = LiveRailRenderProofTests.codebook
        book.sessions = [.init(id: "rail-fixture", group: "G1", startedAt: Date(timeIntervalSince1970: 0), folder: "fixture")]
        if let index = book.cards.firstIndex(where: { $0.name == "洗起来麻烦" }) {
            book.cards[index].provenance = .moderatorIntroduced
            book.cards[index].qids = ["S2Q1"]
        }
        ResearchCodebookController.shared.seedForRenderProof(book)
        XCTAssertFalse(book.cards.filter(\.type.isCode).contains { $0.name == "小禾" })
        try renderBothAppearances(name: "codebook-tab", size: CGSize(width: 560, height: 1640),
                                  view: ResearchCodebookTab().background(House.ColorToken.surface))
    }
}
