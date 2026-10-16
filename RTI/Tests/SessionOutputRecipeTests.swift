import RTICore
import XCTest

/// The saved-meeting output recipes: shipped identity, custom templates, the
/// catalog merge, and the filename-safe id rules. All pure, so no I/O and no
/// provider is involved.
final class SessionOutputRecipeTests: XCTestCase {
    func testBuiltInCatalogueAndIdentity() {
        XCTAssertEqual(
            BuiltInOutputRecipe.allCases.map(\.id),
            ["client-follow-up", "decision-log", "research-debrief"]
        )
        for builtIn in BuiltInOutputRecipe.allCases {
            XCTAssertEqual(builtIn.name, builtIn.promptID.title)
            XCTAssertEqual(builtIn.defaultInstruction, builtIn.promptID.defaultText)
            XCTAssertTrue(SessionOutputID.isValid(builtIn.id), builtIn.id)
        }
    }

    func testBuiltInRecipeResolvesInstructionAndHashesIt() {
        let recipe = SessionOutputRecipe.builtIn(.decisionLog, resolve: { _ in "CUSTOM INSTRUCTION" })
        XCTAssertEqual(recipe.id, "decision-log")
        XCTAssertEqual(recipe.name, "Decision log")
        XCTAssertEqual(recipe.instruction, "CUSTOM INSTRUCTION")
        XCTAssertTrue(recipe.isBuiltIn)
        XCTAssertEqual(recipe.promptID, .decisionLog)
        XCTAssertEqual(recipe.templateHash, PromptDefaults.fnv1a("CUSTOM INSTRUCTION"))
    }

    func testCustomRecipeHashFollowsTheInstructionNotTheName() {
        let first = SessionOutputRecipe.custom(
            CustomOutputTemplate(id: "my-note", name: "My note", instruction: "Summarize.")
        )
        let renamed = SessionOutputRecipe.custom(
            CustomOutputTemplate(id: "my-note", name: "A different name", instruction: "Summarize.")
        )
        XCTAssertEqual(first.templateHash, renamed.templateHash)
        XCTAssertEqual(first.templateHash, PromptDefaults.fnv1a("Summarize."))
        XCTAssertNil(first.promptID)
        XCTAssertFalse(first.isBuiltIn)
    }

    func testCatalogPutsShippedFirstAndDropsShadowingCustoms() {
        let custom = [
            CustomOutputTemplate(id: "decision-log", name: "Shadow", instruction: "must not appear"),
            CustomOutputTemplate(id: "my-note", name: "My note", instruction: "Do it."),
        ]
        let catalog = SessionOutputRecipe.catalog(builtInResolve: { _ in "SHIPPED" }, custom: custom)
        XCTAssertEqual(catalog.map(\.id), ["client-follow-up", "decision-log", "research-debrief", "my-note"])
        XCTAssertEqual(catalog.first?.instruction, "SHIPPED")
        XCTAssertEqual(catalog.last?.instruction, "Do it.")
        XCTAssertEqual(catalog.filter(\.isBuiltIn).count, 3)
    }

    func testRecipeIDValidation() {
        XCTAssertTrue(SessionOutputID.isValid("decision-log"))
        XCTAssertTrue(SessionOutputID.isValid("a"))
        XCTAssertTrue(SessionOutputID.isValid("abc-123"))
        XCTAssertFalse(SessionOutputID.isValid(""))
        XCTAssertFalse(SessionOutputID.isValid("-leading"))
        XCTAssertFalse(SessionOutputID.isValid("trailing-"))
        XCTAssertFalse(SessionOutputID.isValid("double--hyphen"))
        XCTAssertFalse(SessionOutputID.isValid("Upper"))
        XCTAssertFalse(SessionOutputID.isValid("has space"))
        XCTAssertFalse(SessionOutputID.isValid("../escape"))
        XCTAssertFalse(SessionOutputID.isValid("slash/x"))
        XCTAssertFalse(SessionOutputID.isValid(String(repeating: "a", count: SessionOutputID.maxLength + 1)))
    }

    func testSlugAndUniqueSlug() {
        XCTAssertEqual(SessionOutputID.slug(from: "Client follow-up draft!"), "client-follow-up-draft")
        XCTAssertEqual(SessionOutputID.slug(from: "   "), "output")
        XCTAssertEqual(SessionOutputID.slug(from: "决策记录"), "output")
        XCTAssertEqual(SessionOutputID.uniqueSlug(from: "decision-log", existing: []), "decision-log")
        XCTAssertEqual(SessionOutputID.uniqueSlug(from: "decision-log", existing: ["decision-log"]), "decision-log-2")
        XCTAssertEqual(
            SessionOutputID.uniqueSlug(from: "decision-log", existing: ["decision-log", "decision-log-2"]),
            "decision-log-3"
        )
    }

    func testCustomTemplateCodableRoundTrip() throws {
        let template = CustomOutputTemplate(id: "my-note", name: "My note", instruction: "Line 1\nLine 2: value")
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(CustomOutputTemplate.self, from: data)
        XCTAssertEqual(decoded, template)
    }
}
