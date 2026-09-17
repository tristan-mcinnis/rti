import XCTest
@testable import RTICore

/// What the composer says about its sources before Send: whether they are
/// ready, whether a read was cut short, and whether this chat is being saved.
/// The image destination rides the same line.
final class ComposerSourcesStatusTests: XCTestCase {

    func testNothingToSayWhenEverythingIsReady() {
        let status = ComposerSourcesStatus()
        XCTAssertNil(status.notice)
        XCTAssertEqual(status.saveLabel, "Saved")
    }

    func testAReadStillRunningIsNamedAndTheDraftIsKept() {
        let status = ComposerSourcesStatus(readiness: .reading)
        XCTAssertEqual(status.notice, "Reading attachments. Your draft is kept.")
    }

    func testAFailedReadNamesTheWayOut() {
        let status = ComposerSourcesStatus(readiness: .failed)
        XCTAssertEqual(status.notice, "Remove failed attachments or attach them again before sending.")
    }

    func testACutReadNamesTheFileAndTheExtractorsOwnLine() {
        let status = ComposerSourcesStatus(partial: [
            ComposerPartialSource(name: "Board pack.pdf", limit: "200,000 characters kept"),
        ])
        XCTAssertEqual(status.notice, "Board pack.pdf was cut to fit: 200,000 characters kept")
    }

    func testACutReadWithNoLineStillSaysItWasCut() {
        let status = ComposerSourcesStatus(partial: [ComposerPartialSource(name: "Survey export.txt")])
        XCTAssertEqual(status.notice, "Survey export.txt was cut to fit")
    }

    func testAnImageNamesItsDestinationOnTheSameLine() {
        let status = ComposerSourcesStatus(imageRouteLabel: "Images go to DeepSeek (cloud)")
        XCTAssertEqual(status.notice, "Images go to DeepSeek (cloud)")
    }

    func testASavedSourceTheStoreCannotRehydrateIsSaidOutLoud() {
        let status = ComposerSourcesStatus(
            retainedNotice: "Some saved sources are no longer readable from this chat's store (a.pdf)."
        )
        XCTAssertEqual(status.notice, "Some saved sources are no longer readable from this chat's store (a.pdf).")
    }

    func testTheLastRetrievalStateIsSaidOutLoud() {
        let status = ComposerSourcesStatus(
            retrievalNotice: "Vault search fell back to the keyword scan: the index was slow"
        )
        XCTAssertEqual(status.notice, "Vault search fell back to the keyword scan: the index was slow")
    }

    func testAnEmptyControllerNoticeAddsNothing() {
        let status = ComposerSourcesStatus(retainedNotice: "", retrievalNotice: "")
        XCTAssertNil(status.notice)
    }

    func testNoVaultIsSaidOutLoud() {
        let status = ComposerSourcesStatus(savesToVault: false)
        XCTAssertEqual(status.notice, "Not saved: no vault configured")
        XCTAssertEqual(status.saveLabel, "Not saved")
        XCTAssertTrue(status.saveHelp.contains("nothing is written"))
    }

    func testTheLineReadsInOrderReadinessThenCutsThenDestination() {
        let status = ComposerSourcesStatus(
            readiness: .failed,
            partial: [ComposerPartialSource(name: "Board pack.pdf", limit: "cut")],
            imageRouteLabel: "Images stay on this Mac; text only",
            savesToVault: false
        )
        let expected = "Remove failed attachments or attach them again before sending."
            + " · Board pack.pdf was cut to fit: cut"
            + " · Images stay on this Mac; text only"
            + " · Not saved: no vault configured"
        XCTAssertEqual(status.notice, expected)
    }
}
