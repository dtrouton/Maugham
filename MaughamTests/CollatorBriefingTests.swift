import XCTest
@testable import Maugham

/// `CollatorBriefing.compose` — both texts side by side, the writer's intent,
/// the brief, the glossary, and every directive under its paragraph
/// (translation pipeline spec §2).
final class CollatorBriefingTests: XCTestCase {

    private func makeInputs(
        craftIntentText: String? = nil, editionBriefText: String? = nil,
        glossary: [GlossaryEntry] = [],
        pairs: [CollatorBriefing.Inputs.Pair] = [
            .init(paragraphId: "a1b2", sourceText: "The fog came in.",
                  translation: "Llegó la niebla.", directives: ["keep it one sentence"]),
            .init(paragraphId: "c3d4", sourceText: "She closed the door.",
                  translation: nil, directives: []),
        ]
    ) -> CollatorBriefing.Inputs {
        CollatorBriefing.Inputs(
            collatorName: "Borges", language: "es", authorLanguage: "English",
            roleBrief: "Meaning is your only business.",
            craftIntentText: craftIntentText, editionBriefText: editionBriefText,
            glossary: glossary, pairs: pairs)
    }

    func test_roleFrameIsFirstAndNamesBothTextsAndTheReportLanguage() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs())
        XCTAssertTrue(briefing.hasPrefix("You are Borges"), briefing)
        XCTAssertTrue(briefing.contains("original and the es translation side by side"))
        XCTAssertTrue(briefing.contains("in English"))
        XCTAssertTrue(briefing.contains("Meaning is your only business."))
    }

    func test_thePairCarriesSourceThenTranslationThenItsDirectives() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs())
        let id = briefing.range(of: "[a1b2]")!.lowerBound
        let source = briefing.range(of: "Original: The fog came in.")!.lowerBound
        let translation = briefing.range(of: "Translation: Llegó la niebla.")!.lowerBound
        let directive = briefing.range(of: "Directive from the author: keep it one sentence")!.lowerBound
        XCTAssertLessThan(id, source)
        XCTAssertLessThan(source, translation)
        XCTAssertLessThan(translation, directive)
    }

    func test_anUntranslatedPairIsListedAsSuchWithItsSource() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs())
        XCTAssertTrue(briefing.contains("[c3d4] (not translated)"))
        XCTAssertTrue(briefing.contains("Original: She closed the door."))
        XCTAssertFalse(briefing.contains("Translation: \n"), "no empty translation line")
    }

    func test_briefedIdsAreThePairsWithATranslation() {
        XCTAssertEqual(makeInputs().briefedParagraphIds, ["a1b2"])
    }

    func test_intentAndBriefAreCarriedVerbatim() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs(
            craftIntentText: "Plainness is the point.",
            editionBriefText: "Texture: fluent.\n\n## Rulings\n\n- «October» → «Octubre» — ruled 28 Aug 2026, glossary"))
        XCTAssertTrue(briefing.contains("Declared intent:\nPlainness is the point."))
        XCTAssertTrue(briefing.contains("Texture: fluent."))
        XCTAssertTrue(briefing.contains("## Rulings"))
    }

    func test_theGlossaryIsATableAndAbsentWhenEmpty() {
        let with = CollatorBriefing.compose(inputs: makeInputs(
            glossary: [GlossaryEntry(term: "October", rendering: "Octubre", note: nil)]))
        XCTAssertTrue(with.contains("| Term | Rendering | Note |"))
        XCTAssertTrue(with.contains("| October | Octubre |  |"))
        XCTAssertTrue(with.contains("rendered two ways"), "the consistency remit is said in words")
        let without = CollatorBriefing.compose(inputs: makeInputs())
        XCTAssertFalse(without.contains("| Term |"))
    }

    func test_nothingOfTheOtherSessionsIsBriefed() {
        let briefing = CollatorBriefing.compose(inputs: makeInputs())
        for absent in ["Established so far", "Queries from earlier rounds", "reader's notes"] {
            XCTAssertFalse(briefing.contains(absent), absent)
        }
    }

    func test_reportContractIsLast() {
        XCTAssertTrue(CollatorBriefing.compose(inputs: makeInputs())
            .hasSuffix(CollatorReport.schemaDescription))
    }

    func test_anchorsAreStripped() {
        // `MarkdownDisplayFilter.stripAnchors` only strips a paragraph anchor
        // that stands alone on its own line (`ParagraphID.parseComment`'s
        // `^…$`-anchored regex) — the shape `Materializer` actually emits, and
        // the shape `TranslatorBriefingTests`/`ReaderBriefingTests` plant
        // their own versions of this test with. A mid-line anchor is not a
        // real anchor shape, so it is not the case this defense-in-depth
        // test is guarding.
        let briefing = CollatorBriefing.compose(inputs: makeInputs(pairs: [
            .init(paragraphId: "a1b2", sourceText: "<!-- ¶a1b2 -->\n\nFog came",
                  translation: "<!-- ¶a1b2 -->\n\nNiebla", directives: [])]))
        XCTAssertFalse(briefing.contains("<!-- ¶"))
    }
}
