import XCTest
@testable import Maugham

/// **What a gloss is briefed on, and what it must never be briefed on**
/// (translation pipeline spec §9, P4 Task 6).
///
/// A gloss is the author's one way of reading a language they do not read: the
/// translated paragraph, rendered back literally into their own. Its whole
/// value is that the model glossing it has NOT seen the original — shown the
/// source, a model renders the source it can read rather than the translation
/// it is being asked about, and the author is told their book is intact by a
/// process that never looked. `GlossBriefing.Inputs` therefore has no source
/// field at all, and the first test here is the one that fails if somebody
/// gives it one.
@MainActor
final class GlossBriefingTests: XCTestCase {

    private func inputs(
        before: String? = "Llegó la niebla.",
        paragraph: String = "Cerró la puerta.",
        after: String? = "Nadie habló.",
        textureLine: String? = nil
    ) -> GlossBriefing.Inputs {
        GlossBriefing.Inputs(
            language: "Spanish", authorLanguage: "English", textureLine: textureLine,
            before: before, paragraph: paragraph, after: after)
    }

    // MARK: - What the briefing carries

    func test_theParagraphAndBothNeighboursAreThere() {
        let message = GlossBriefing.compose(inputs: inputs())

        XCTAssertTrue(message.contains("Cerró la puerta."), "the paragraph being glossed")
        XCTAssertTrue(message.contains("Llegó la niebla."), "the paragraph before it")
        XCTAssertTrue(message.contains("Nadie habló."), "the paragraph after it")
    }

    /// The neighbours are context, and the briefing says so: a model handed
    /// three paragraphs and asked for one gloss will otherwise gloss all three,
    /// and the author gets a wall of prose where one paragraph goes.
    func test_theNeighboursAreMarkedAsContextAndNotToBeGlossed() {
        let message = GlossBriefing.compose(inputs: inputs())

        XCTAssertTrue(message.contains("Before:"))
        XCTAssertTrue(message.contains("The paragraph:"))
        XCTAssertTrue(message.contains("After:"))
        XCTAssertTrue(message.lowercased().contains("do not gloss these"))
    }

    func test_aMissingNeighbourLeavesItsLineOut() {
        let message = GlossBriefing.compose(inputs: inputs(before: nil, after: nil))

        XCTAssertFalse(message.contains("Before:"))
        XCTAssertFalse(message.contains("After:"))
        XCTAssertTrue(message.contains("The paragraph:"))
    }

    /// **The source is unreachable from here.** Composed with everything the
    /// type can carry, a sentence the author wrote in English is nowhere in the
    /// message — because there is no field it could have arrived through.
    func test_theSourceIsNowhereInTheBriefingBecauseThereIsNoFieldForIt() {
        let plantedSource = "She closed the door."
        let message = GlossBriefing.compose(
            inputs: inputs(textureLine: "Texture \u{2014} fluent Spanish"))

        XCTAssertFalse(message.contains(plantedSource),
                       "a gloss that has seen the original is not a gloss")
    }

    func test_theAuthorsLanguageIsInTheRoleFrame() {
        let message = GlossBriefing.compose(inputs: inputs())

        XCTAssertTrue(message.contains("English"),
                      "the author reads this and the gloss is written in it")
        XCTAssertTrue(message.contains("Spanish"), "the language being glossed")
    }

    func test_theTextureLineIsCarriedWhenThereIsOne() {
        let with = GlossBriefing.compose(inputs: inputs(textureLine: "Texture \u{2014} fluent Spanish"))
        let without = GlossBriefing.compose(inputs: inputs())

        XCTAssertTrue(with.contains("fluent Spanish"))
        XCTAssertFalse(without.contains("fluent Spanish"))
    }

    func test_theSchemaIsAtTheEnd() {
        let message = GlossBriefing.compose(inputs: inputs())

        XCTAssertTrue(message.contains(GlossBriefing.schemaDescription))
        XCTAssertTrue(message.contains("\"gloss\""))
    }

    // MARK: - The texture line

    func test_theTextureLineIsFoundInAnEditionBriefAndStrippedOfMarkdown() {
        let brief = """
            # Spanish edition

            **Texture** \u{2014} fluent Spanish, contemporary, no archaism.

            ## Rulings
            """

        let line = GlossBriefing.textureLine(in: brief)

        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("fluent Spanish") == true)
        XCTAssertFalse(line?.contains("**") == true, "markdown prefixes are stripped")
        XCTAssertTrue(line?.hasPrefix("Texture") == true)
    }

    func test_theTextureLineIsFoundCaseInsensitivelyAndAfterAListMarker() {
        let line = GlossBriefing.textureLine(in: "- texture: dry, plain, short sentences.")

        XCTAssertEqual(line, "texture: dry, plain, short sentences.")
    }

    func test_aBriefWithNoTextureLineHasNone() {
        XCTAssertNil(GlossBriefing.textureLine(in: "# Spanish edition\n\nKeep the names."))
        XCTAssertNil(GlossBriefing.textureLine(in: nil))
    }

    // MARK: - The report

    func test_aGlossIsReadOffTheAnswerAndTrimmed() {
        XCTAssertEqual(GlossReport.parse("{\"gloss\":\"The fog came.\"}"), "The fog came.")
        XCTAssertEqual(GlossReport.parse("Here it is:\n{\"gloss\":\"  The fog came.  \"}"),
                       "The fog came.")
    }

    /// A model that reasons in prose puts a worked example first; the answer is
    /// the LAST object, `ReportJSON`'s rule for every parser here.
    func test_theLastObjectWins() {
        let raw = "{\"gloss\":\"an example\"}\nand the real one:\n{\"gloss\":\"The fog came.\"}"

        XCTAssertEqual(GlossReport.parse(raw), "The fog came.")
    }

    func test_anEmptyOrProseOnlyAnswerIsRefused() {
        XCTAssertNil(GlossReport.parse("{\"gloss\":\"\"}"))
        XCTAssertNil(GlossReport.parse("{\"gloss\":\"   \"}"))
        XCTAssertNil(GlossReport.parse("The fog came."),
                     "prose is not a report, however readable")
        XCTAssertNil(GlossReport.parse("{\"overall\":\"it holds\"}"))
    }
}
