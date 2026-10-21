import XCTest
import RTICore

/// Locks the tolerant kind parsing Auto mode relies on — the model emits
/// uppercase tags and a few synonyms, and an unknown tag must not drop the card.
///
/// Also locks the citation gate: a card may only cite a document that this pass
/// actually retrieved, matched by its exact handle. A fabricated name, a
/// title-with-substring, or nothing at all yields a card with no citation.
final class AutoAssistCardTests: XCTestCase {
    func testCanonicalKinds() {
        XCTAssertEqual(AutoCardKind(raw: "SAY"), .say)
        XCTAssertEqual(AutoCardKind(raw: "ASK"), .ask)
        XCTAssertEqual(AutoCardKind(raw: "RECALL"), .recall)
        XCTAssertEqual(AutoCardKind(raw: "FLAG"), .flag)
    }

    func testSynonymsAndCase() {
        XCTAssertEqual(AutoCardKind(raw: "context"), .recall)
        XCTAssertEqual(AutoCardKind(raw: "Info"), .recall)
        XCTAssertEqual(AutoCardKind(raw: "watch"), .flag)
    }

    func testUnknownFallsBackToRecall() {
        XCTAssertEqual(AutoCardKind(raw: "banana"), .recall)
        XCTAssertEqual(AutoCardKind(raw: ""), .recall)
    }

    // MARK: - Citation fixtures (synthetic; no vault access, no model request)

    /// Two invented retrieval records, shaped exactly like `VaultSearch.Result`.
    private func retrievedResults() -> [VaultSearch.Result] {
        [
            VaultSearch.Result(
                title: "Sample brand status",
                relativePath: "projects/sample-brand/00-status.md",
                modified: Date(timeIntervalSince1970: 1_700_000_000),
                excerpt: "The programme is in field.",
                score: 40
            ),
            VaultSearch.Result(
                title: "Group 1 transcript",
                relativePath: "projects/sample-brand/transcripts/group-1.md",
                modified: Date(timeIntervalSince1970: 1_700_100_000),
                excerpt: "Participants described the store layout.",
                score: 20
            ),
        ]
    }

    private func retrievedCitations() -> [VaultSearch.Citation] {
        VaultSearch.citations(for: retrievedResults())
    }

    private func card(
        text: String = "Confirm the field window with the client.",
        sourceID: String?,
        citations: [VaultSearch.Citation]? = nil
    ) -> AutoAssistCard? {
        AutoAssistCard.make(
            kind: .recall,
            text: text,
            why: "Answering the question just asked.",
            sourceID: sourceID,
            citations: citations ?? retrievedCitations(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    // MARK: - Citation handles printed for the model

    func testCitationsAreNumberedAndDerivedFromTheRetrievalRecord() {
        let citations = retrievedCitations()
        XCTAssertEqual(citations.map(\.id), ["S1", "S2"])
        XCTAssertEqual(citations[0].title, "Sample brand status")
        XCTAssertEqual(citations[0].relativePath, "projects/sample-brand/00-status.md")
        XCTAssertEqual(citations[0].label, "00-status.md")
    }

    func testCiteableMaterialPrintsTheSameHandlesTheGateAccepts() {
        let results = retrievedResults()
        let citations = VaultSearch.citations(for: results)
        let cited = VaultSearch.format(results, query: "store", citeable: true)
        for citation in citations {
            XCTAssertTrue(
                cited.contains("[\(citation.id)]"),
                "material must print the handle the gate resolves: \(citation.id)"
            )
        }
        XCTAssertTrue(cited.contains(results[0].title))
        XCTAssertTrue(cited.contains(results[0].relativePath))
        XCTAssertTrue(cited.contains("bracketed ID"))
    }

    func testUncitedMaterialKeepsTheExistingFormat() {
        // The existing formatted-search entry must not gain handles.
        let plain = VaultSearch.format(retrievedResults(), query: "store")
        XCTAssertFalse(plain.contains("[S1]"))
        XCTAssertFalse(plain.contains("bracketed ID"))
        XCTAssertTrue(plain.contains("Cite the document name"))
        XCTAssertTrue(plain.contains("Found 2 relevant vault documents"))
    }

    func testNoHitMaterialIsUnchangedByCitationMode() {
        let plain = VaultSearch.format([], query: "store")
        let cited = VaultSearch.format([], query: "store", citeable: true)
        XCTAssertEqual(plain, cited)
        XCTAssertTrue(plain.hasPrefix("No vault documents matched"))
    }

    // MARK: - Valid handles map to the real retrieved record

    func testValidIDCitesTheRetrievedDocument() {
        let card = card(sourceID: "S1")
        XCTAssertEqual(card?.citation?.id, "S1")
        XCTAssertEqual(card?.citation?.relativePath, "projects/sample-brand/00-status.md")
        XCTAssertEqual(card?.citation?.title, "Sample brand status")
        // The source row reads the real document name, not the model's text.
        XCTAssertEqual(card?.source, "00-status.md")
    }

    func testSecondIDCitesItsOwnDocument() {
        let card = card(sourceID: "S2")
        XCTAssertEqual(card?.citation?.relativePath, "projects/sample-brand/transcripts/group-1.md")
        XCTAssertEqual(card?.source, "group-1.md")
    }

    func testHandleToleratesCaseBracketsAndPadding() {
        XCTAssertEqual(card(sourceID: " s1 ")?.citation?.id, "S1")
        XCTAssertEqual(card(sourceID: "[S2]")?.citation?.id, "S2")
        XCTAssertEqual(card(sourceID: "「S1」")?.citation?.id, "S1")
    }

    func testExactRelativePathIsAValidHandle() {
        let card = card(sourceID: "projects/sample-brand/00-status.md")
        XCTAssertEqual(card?.citation?.id, "S1")
    }

    // MARK: - Missing or invented handles cite nothing, but keep the card

    func testMissingHandleStillSurfacesTheCardWithoutACitation() {
        for handle in [nil, "", "   ", "null", "none", "n/a"] as [String?] {
            let card = card(sourceID: handle)
            XCTAssertNotNil(card, "a card with no citation is still useful")
            XCTAssertNil(card?.citation, "handle \(String(describing: handle)) must not cite")
            XCTAssertNil(card?.source)
            XCTAssertFalse(card?.text.isEmpty ?? true)
        }
    }

    func testInventedHandleIsRejected() {
        for handle in ["S9", "S0", "S", "00-legacy-strategy.md", "projects/sample-brand/notes.md"] {
            XCTAssertNil(card(sourceID: handle)?.citation, "invented handle \(handle) must not cite")
        }
    }

    func testNoRetrievedMaterialRejectsEveryHandle() {
        XCTAssertNil(card(sourceID: "S1", citations: [])?.citation)
    }

    // MARK: - Spoofed labels never match

    func testTitleAndSubstringSpoofsAreRejected() {
        // A real title is not a handle, so it can never become a citation by
        // being typed back — and a title that merely contains a real one is
        // rejected for the same reason. No substring matching anywhere.
        let spoofs = [
            "Sample brand status",
            "Group 1 transcript",
            "Sample brand status (workshop draft)",
            "Revised Group 1 transcript",
            "Sample brand",
            "Group 1",
            "00-status",
            "status.md",
            "projects/sample-brand/00-status",
        ]
        for spoof in spoofs {
            XCTAssertNil(card(sourceID: spoof)?.citation, "spoofed label \(spoof) must not cite")
        }
    }

    func testCompoundHandlesAreNotSplit() {
        for handle in ["S1, S2", "S1 and S2", "S1/S2", "S1S2", "S1 (Group 1 transcript)"] {
            XCTAssertNil(card(sourceID: handle)?.citation, "compound handle \(handle) must not cite")
        }
    }

    // MARK: - Repeated handles

    func testRepeatedIDOnTwoCardsCitesTheSameDocumentTwice() {
        let citations = retrievedCitations()
        let first = card(text: "Confirm the field window.", sourceID: "S1", citations: citations)
        let second = card(text: "Ask who owns the store layout.", sourceID: "S1", citations: citations)
        XCTAssertEqual(first?.citation, second?.citation)
        XCTAssertEqual(first?.citation?.relativePath, "projects/sample-brand/00-status.md")
        XCTAssertEqual(first?.source, second?.source)
    }

    func testOneCardCitingDifferentIDsGetsThatDocument() {
        let citations = retrievedCitations()
        let first = card(text: "One.", sourceID: "S1", citations: citations)
        let second = card(text: "Two.", sourceID: "S2", citations: citations)
        XCTAssertNotEqual(first?.citation, second?.citation)
        XCTAssertEqual(second?.citation?.id, "S2")
    }

    // MARK: - Actual decode-to-card path

    /// Decode a model response exactly as Auto does, then assemble cards through
    /// the same call the controller uses. These tests cover the wire type's key
    /// aliases and the citation gate together, not each in isolation.
    private func cards(
        from json: String,
        citations: [VaultSearch.Citation]? = nil
    ) -> [AutoAssistCard] {
        let items = JSONExtractor.decodeArrayLenient(json, key: "cards", as: AutoCardItem.self)
        let allowed = citations ?? retrievedCitations()
        return items.compactMap {
            AutoAssistCard.make(
                from: $0,
                citations: allowed,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
    }

    func testDecodedCardWithValidSourceIDCitesTheRetrievedDocument() {
        let json = #"""
        {"cards":[{"kind":"RECALL","text":"The field window is agreed.","why":"They just asked about timing.","sourceId":"S1"}]}
        """#
        let card = cards(from: json).first
        XCTAssertEqual(card?.text, "The field window is agreed.")
        XCTAssertEqual(card?.why, "They just asked about timing.")
        XCTAssertEqual(card?.kind, .recall)
        XCTAssertEqual(card?.citation?.id, "S1")
        XCTAssertEqual(card?.source, "00-status.md")
    }

    func testDecodedCardAcceptsEveryHandleSpelling() {
        // The model writes `sourceId`, `source_id` or `sourceID` depending on the
        // prompt it remembers; all three must reach the same gate.
        for key in ["sourceId", "source_id", "sourceID"] {
            let json = #"{"cards":[{"kind":"RECALL","text":"Point.","\#(key)":"S2"}]}"#
            let card = cards(from: json).first
            XCTAssertEqual(card?.citation?.id, "S2", "key \(key) must decode")
            XCTAssertEqual(card?.source, "group-1.md")
        }
    }

    func testDecodedLegacySourceFieldIsAHandleCandidateOnly() {
        // An older saved prompt override asks for a free-form `source`. An exact
        // vault-relative path still resolves; a document name does not.
        let realPath = #"{"cards":[{"text":"Point.","source":"projects/sample-brand/00-status.md"}]}"#
        XCTAssertEqual(cards(from: realPath).first?.citation?.id, "S1")

        let typedTitle = #"{"cards":[{"text":"Point.","source":"Sample brand status"}]}"#
        XCTAssertNotNil(cards(from: typedTitle).first)
        XCTAssertNil(cards(from: typedTitle).first?.citation)
        XCTAssertNil(cards(from: typedTitle).first?.source)
    }

    func testDecodedInventedSourceIDKeepsTheCardWithoutACitation() {
        let json = #"{"cards":[{"text":"Point about the rollout.","sourceId":"S9"}]}"#
        let card = cards(from: json).first
        XCTAssertEqual(card?.text, "Point about the rollout.")
        XCTAssertNil(card?.citation)
        XCTAssertNil(card?.source)
    }

    func testDecodedTitleSpoofNeverBecomesACitation() {
        // A misleading title that contains a real title as a substring.
        let json = #"{"cards":[{"text":"Point.","sourceId":"Sample brand status (workshop draft)"}]}"#
        XCTAssertNil(cards(from: json).first?.citation)
    }

    func testDecodedNullStringFallsBackToTheLegacySource() {
        // `"sourceId": null` decodes to nil; the string "null" must not mask a
        // usable legacy field.
        let explicitNull = #"{"cards":[{"text":"Point.","sourceId":null,"source":"S1"}]}"#
        XCTAssertEqual(cards(from: explicitNull).first?.citation?.id, "S1")

        let nullString = #"{"cards":[{"text":"Point.","sourceId":"null","source":"S1"}]}"#
        XCTAssertEqual(cards(from: nullString).first?.citation?.id, "S1")
    }

    func testDecodedBatchKeepsValidCardsAndDropsAnEmptyOne() {
        // The lenient decoder and the gate together: one good card, one with a
        // spoofed source, one with no text.
        let json = #"""
        {"cards":[
          {"kind":"ASK","text":"Ask who owns the store layout.","source_id":"S2"},
          {"kind":"FLAG","text":"Flag the draft date.","sourceId":"Sample brand status"},
          {"kind":"SAY","text":"   ","sourceId":"S1"}
        ]}
        """#
        let decoded = cards(from: json)
        XCTAssertEqual(decoded.map(\.text), [
            "Ask who owns the store layout.",
            "Flag the draft date.",
        ])
        XCTAssertEqual(decoded.first?.citation?.id, "S2")
        XCTAssertNil(decoded.last?.citation)
    }

    // MARK: - Assembly basics

    func testEmptyTextDropsTheCard() {
        XCTAssertNil(card(text: "   \n ", sourceID: "S1"))
    }

    func testAssemblyTrimsTextAndWhy() {
        let card = AutoAssistCard.make(
            kind: .recall,
            text: "  Confirm the field window.\n",
            why: "  They just asked about timing.  ",
            sourceID: "S1",
            citations: retrievedCitations()
        )
        XCTAssertEqual(card?.text, "Confirm the field window.")
        XCTAssertEqual(card?.why, "They just asked about timing.")
        XCTAssertEqual(card?.kind, .recall)
    }
}
