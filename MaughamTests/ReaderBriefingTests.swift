import XCTest
@testable import Maugham

/// `ReaderBriefing.compose` is what the blind reader is sent (translation
/// pipeline spec §2). The one property everything else serves: **the reader
/// never sees the source.**
final class ReaderBriefingTests: XCTestCase {

    private let plantedSource = "The fog came in over the harbour."

    private func makeInputs(
        readerName: String = "Ocampo", language: String = "es",
        authorLanguage: String = "English",
        roleBrief: String? = nil, editionBriefText: String? = nil,
        paragraphs: [ReaderBriefing.Inputs.Paragraph] = [
            .init(paragraphId: "a1b2", translation: "Llegó la niebla sobre el puerto."),
            .init(paragraphId: "c3d4", translation: nil),
            .init(paragraphId: "e5f6", translation: "Nadie habló."),
        ]
    ) -> ReaderBriefing.Inputs {
        ReaderBriefing.Inputs(
            readerName: readerName, language: language, authorLanguage: authorLanguage,
            roleBrief: roleBrief, editionBriefText: editionBriefText, paragraphs: paragraphs)
    }

    func test_thePlantedSourceSentenceIsAbsent() {
        // The type has no field a source sentence could travel in; this is
        // the spec's own test, and it also guards the gap marker, which is the
        // one place a careless composer would reach for the source.
        let briefing = ReaderBriefing.compose(inputs: makeInputs())
        XCTAssertFalse(briefing.contains(plantedSource))
        XCTAssertFalse(briefing.contains("fog"))
    }

    func test_roleFrameIsFirstAndNamesReaderLanguageAndBlindness() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs())
        XCTAssertTrue(briefing.hasPrefix("You are Ocampo"), briefing)
        XCTAssertTrue(briefing.contains("es"))
        XCTAssertTrue(briefing.contains("You have not seen, and will not see, any other version"))
        XCTAssertTrue(briefing.contains("in English"), "the report's language is the author's")
    }

    func test_roleBriefIsCarriedWhenPresent() {
        let briefing = ReaderBriefing.compose(
            inputs: makeInputs(roleBrief: "Judge rhythm above all."))
        XCTAssertTrue(briefing.contains("Judge rhythm above all."))
    }

    func test_editionBriefIsCarriedWholeRulingsIncluded() {
        let brief = """
            Texture: reads as written in Spanish.

            ## Rulings

            - ¶a1b2: this fragment is deliberate — ruled 28 Aug 2026, translator's note
            """
        let briefing = ReaderBriefing.compose(inputs: makeInputs(editionBriefText: brief))
        XCTAssertTrue(briefing.contains("## Rulings"))
        XCTAssertTrue(briefing.contains("this fragment is deliberate"),
                      "a declared feature is not a fault — the directive reaches the reader")
        XCTAssertTrue(briefing.contains("Texture: reads as written in Spanish."))
    }

    func test_noEditionBriefComposesNoBriefSection() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs(editionBriefText: nil))
        XCTAssertFalse(briefing.contains("Edition brief"))
    }

    func test_paragraphsAreTaggedInOrderAndAGapIsMarkedNeverFilled() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs())
        let a = briefing.range(of: "[a1b2]")!.lowerBound
        let gap = briefing.range(of: ReaderBriefing.gapMarker("c3d4"))!.lowerBound
        let e = briefing.range(of: "[e5f6]")!.lowerBound
        XCTAssertLessThan(a, gap)
        XCTAssertLessThan(gap, e)
        XCTAssertEqual(ReaderBriefing.gapMarker("c3d4"), "[c3d4 \u{2014} not yet translated]")
        XCTAssertTrue(briefing.contains("Llegó la niebla sobre el puerto."))
    }

    func test_briefedIdsAreTheTranslatedOnesOnly() {
        XCTAssertEqual(makeInputs().briefedParagraphIds, ["a1b2", "e5f6"])
    }

    func test_nothingOfTheCompilersWorldIsBriefed() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs())
        for absent in ["Declared intent", "Established so far", "Queries from earlier rounds"] {
            XCTAssertFalse(briefing.contains(absent), absent)
        }
    }

    func test_reportContractIsTheLastSection() {
        let briefing = ReaderBriefing.compose(inputs: makeInputs())
        XCTAssertTrue(briefing.hasSuffix(ReaderReport.schemaDescription))
    }

    func test_anchorsAreStrippedFromEmbeddedText() {
        // `MarkdownDisplayFilter.stripAnchors` only strips a paragraph anchor
        // that stands alone on its own line (`ParagraphID.parseComment`'s
        // `^…$`-anchored regex) — the shape `Materializer` actually emits, and
        // the one `TranslatorBriefingTests` plants its own version of this
        // test with. A mid-line anchor is not a real anchor shape, so it is
        // not the case this defense-in-depth test is guarding.
        let briefing = ReaderBriefing.compose(inputs: makeInputs(
            editionBriefText: "<!-- ¶zzzz -->\n\nTexture line",
            paragraphs: [.init(paragraphId: "a1b2", translation: "<!-- ¶a1b2 -->\n\nHola mundo")]))
        XCTAssertFalse(briefing.contains("<!-- ¶"))
    }
}
