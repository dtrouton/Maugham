import MaughamCore
import XCTest
@testable import Maugham

/// `BriefingDoctrine.swift` reads directives and the glossary off statement
/// markdown into the plain values every briefing takes — pure, over the P1
/// `Ruling` shapes.
final class BriefingDoctrineTests: XCTestCase {

    private let intent = """
        A quiet book.

        ## Rulings

        - Kelly never lies — ruled 20 Aug 2026, from a run on ¶wnse
        - ¶k7mq: keep the three "and"s - this sentence is a list on purpose — ruled 28 Aug 2026, translator's note
        """

    private let brief = """
        Texture: reads as written in Spanish.

        ## Rulings

        - ¶k7mq: do not elevate this — ruled 29 Aug 2026, translator's note
        - «October» → «Octubre» (the month, never a name) — ruled 28 Aug 2026, glossary
        - «Kelly» → «Kelly» — ruled 28 Aug 2026, glossary
        - ¶zzzz: one sentence, not two
        """

    // MARK: - Directives

    func test_gatherReadsDirectivesFromBothStatementsAndNothingElse() {
        let directives = Directives.gather(craftIntent: intent, editionBrief: brief)
        XCTAssertEqual(directives.map(\.paragraphId), ["k7mq", "k7mq", "zzzz"])
        XCTAssertEqual(directives[0].text, "keep the three \"and\"s - this sentence is a list on purpose")
        XCTAssertEqual(directives[0].source, .craftIntent)
        XCTAssertEqual(directives[1].source, .editionBrief)
        XCTAssertNil(directives[2].ruledOn, "a hand-written bare line has no date")
        XCTAssertNotNil(directives[0].ruledOn)
    }

    func test_gatherOverNothingIsEmpty() {
        XCTAssertEqual(Directives.gather(craftIntent: nil, editionBrief: nil), [])
        XCTAssertEqual(Directives.gather(craftIntent: "", editionBrief: "no rulings here"), [])
    }

    func test_byParagraphGroupsInOrder() {
        let grouped = Directives.byParagraph(
            Directives.gather(craftIntent: intent, editionBrief: brief))
        XCTAssertEqual(grouped["k7mq"]?.count, 2)
        XCTAssertEqual(grouped["zzzz"]?.count, 1)
        XCTAssertNil(grouped["wnse"], "an ordinary ruling mentioning an id in prose is not a directive")
    }

    /// Spec §2: directed = a directive ruled AFTER the record's `at`. Dates in
    /// the stratum are days (UTC midnight), so the comparison is on days.
    func test_isDirectedComparesRuledDayAgainstTheRecordsDay() {
        let ruled = Directives.gather(craftIntent: intent, editionBrief: nil)  // 28 Aug 2026
        let day = { (iso: String) -> Date in ISO8601DateFormatter().date(from: iso)! }

        XCTAssertTrue(Directives.isDirected(
            translatedAt: day("2026-08-27T15:00:00Z"), directives: ruled),
            "translated the day before the ruling → directed")
        XCTAssertTrue(Directives.isDirected(
            translatedAt: day("2026-08-28T15:00:00Z"), directives: ruled),
            "translated the SAME day → directed: the day cannot say which came first, "
            + "and re-sending one paragraph is cheaper than losing the writer's ruling")
        XCTAssertFalse(Directives.isDirected(
            translatedAt: day("2026-08-29T01:00:00Z"), directives: ruled),
            "translated the day after → the ruling was already honoured")
    }

    func test_anUndatedDirectiveNeverDirects() {
        let undated = [Directive(paragraphId: "zzzz", text: "one sentence", ruledOn: nil,
                                 source: .editionBrief)]
        XCTAssertFalse(Directives.isDirected(translatedAt: .distantPast, directives: undated),
                       "no date, no 'after' — it still reaches the translator whenever the "
                       + "paragraph is work, but it must not keep it work for ever")
    }

    func test_isDirectedIsAboutFreshParagraphsOnly() {
        let ruled = Directives.gather(craftIntent: intent, editionBrief: nil)
        XCTAssertFalse(Directives.isDirected(translatedAt: nil, directives: ruled),
                       "no record is `missing`, which is already work")
        XCTAssertFalse(Directives.isDirected(translatedAt: .distantPast, directives: []))
    }

    // MARK: - Glossary

    func test_gatherReadsGlossaryEntriesInOrder() {
        let entries = GlossaryTable.gather(editionBrief: brief)
        XCTAssertEqual(entries, [
            GlossaryEntry(term: "October", rendering: "Octubre", note: "the month, never a name"),
            GlossaryEntry(term: "Kelly", rendering: "Kelly", note: nil),
        ])
        XCTAssertEqual(GlossaryTable.gather(editionBrief: nil), [])
    }

    func test_renderIsAMarkdownTableAndNilWhenEmpty() {
        XCTAssertNil(GlossaryTable.render([]))
        let table = GlossaryTable.render(GlossaryTable.gather(editionBrief: brief))!
        XCTAssertTrue(table.hasPrefix("| Term | Rendering | Note |\n|---|---|---|\n"), table)
        XCTAssertTrue(table.contains("| October | Octubre | the month, never a name |"))
        XCTAssertTrue(table.contains("| Kelly | Kelly |  |"))
    }

    /// A pipe inside a term would break the table's own columns.
    func test_renderEscapesPipes() {
        let table = GlossaryTable.render([
            GlossaryEntry(term: "a|b", rendering: "c", note: nil)])!
        XCTAssertTrue(table.contains("| a\\|b | c |  |"), table)
    }
}
