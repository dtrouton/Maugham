import XCTest
@testable import MaughamCore

final class RulingsSectionTests: XCTestCase {

    // MARK: - parse: no section

    func test_parse_noRulingsSection_wholeTextIsEssayNoRulings() {
        let md = "Kelly never lies. She only ever acts on things she's actually heard."
        let (essay, rulings) = RulingsSection.parse(md)
        XCTAssertEqual(essay, md)
        XCTAssertTrue(rulings.isEmpty)
    }

    // MARK: - F-A lesson: blank-delimited detection only

    func test_aBodyLineSpellingTheHeadingStaysProse() {
        let md = """
        Kelly's voice is careful.
        ## Rulings
        This is not really a section, just more prose that happens to follow
        a line spelling the heading with no blank line before it.
        """
        let (essay, rulings) = RulingsSection.parse(md)
        XCTAssertEqual(essay, md)
        XCTAssertTrue(rulings.isEmpty)
    }

    // MARK: - hand-written rulings are legal

    func test_handWrittenRulingsAreLegal() {
        let md = """
        Some essay text.

        ## Rulings

        - Kelly never lies
        """
        let (essay, rulings) = RulingsSection.parse(md)
        XCTAssertEqual(essay, "Some essay text.")
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].text, "Kelly never lies")
        XCTAssertNil(rulings[0].ruledOn)
        XCTAssertNil(rulings[0].provenance)
    }

    // MARK: - dated/provenanced rulings parse

    func test_parse_datedRuling_extractsDateAndProvenance() throws {
        let md = """
        Essay.

        ## Rulings

        - Kelly heard about the call offstage, before scene 4 — ruled 7 Aug 2026, from a run on ¶wnse
        """
        let (_, rulings) = RulingsSection.parse(md)
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].text, "Kelly heard about the call offstage, before scene 4")
        XCTAssertEqual(rulings[0].provenance, "from a run on ¶wnse")
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.day, .month, .year], from: try XCTUnwrap(rulings[0].ruledOn))
        XCTAssertEqual(comps.day, 7)
        XCTAssertEqual(comps.month, 8)
        XCTAssertEqual(comps.year, 2026)
    }

    func test_parse_emDashSuffixThatIsNotADate_becomesWholeProvenanceNilDate() throws {
        let md = """
        Essay.

        ## Rulings

        - Kelly never lies — Denver's ruling, no date given
        """
        let (_, rulings) = RulingsSection.parse(md)
        XCTAssertEqual(rulings.count, 1)
        XCTAssertNil(rulings[0].ruledOn)
        XCTAssertEqual(rulings[0].provenance, "Denver's ruling, no date given")
    }

    // MARK: - appending

    func test_appending_createsSectionWhenAbsent_andRoundTrips() throws {
        let md = "Essay only, no section yet."
        let date = try makeDate(day: 7, month: 8, year: 2026)
        let updated = RulingsSection.appending(
            "Kelly never lies", provenance: "from a run on ¶wnse", on: date, to: md)

        let (essay, rulings) = RulingsSection.parse(updated)
        XCTAssertEqual(essay, "Essay only, no section yet.")
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].text, "Kelly never lies")
        XCTAssertEqual(rulings[0].provenance, "from a run on ¶wnse")
        XCTAssertNotNil(rulings[0].ruledOn)
    }

    func test_appending_appendsOneLineWhenSectionPresent() throws {
        let md = """
        Essay.

        ## Rulings

        - Kelly never lies
        """
        let date = try makeDate(day: 7, month: 8, year: 2026)
        let updated = RulingsSection.appending(
            "Denver hates prologues", provenance: "from a chat", on: date, to: md)

        let (essay, rulings) = RulingsSection.parse(updated)
        XCTAssertEqual(essay, "Essay.")
        XCTAssertEqual(rulings.count, 2)
        XCTAssertEqual(rulings[0].text, "Kelly never lies")
        XCTAssertEqual(rulings[1].text, "Denver hates prologues")
        XCTAssertEqual(rulings[1].provenance, "from a chat")
    }

    // MARK: - removing

    func test_removing_byId_deletesExactlyOneLine() throws {
        let md = """
        Essay.

        ## Rulings

        - Kelly never lies
        - Denver hates prologues
        """
        let (_, rulings) = RulingsSection.parse(md)
        let targetId = rulings[0].id

        let updated = RulingsSection.removing(rulingId: targetId, from: md)
        let (essay, remaining) = RulingsSection.parse(updated)
        XCTAssertEqual(essay, "Essay.")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].text, "Denver hates prologues")
    }

    /// Removing the LAST ruling collapses the doc back to essay-only — no
    /// empty "## Rulings" heading left behind. This is the spec's "no
    /// section → no stratum" rule applied to the file itself: a document
    /// with zero rulings is indistinguishable from one that never had a
    /// Rulings section, by design (see `render`'s `guard !rulings.isEmpty`).
    func test_removing_lastRuling_collapsesTheSectionEntirely() {
        let essayOnly = "Essay."
        let md = """
        \(essayOnly)

        ## Rulings

        - Kelly never lies
        - Denver hates prologues
        """
        let (_, rulings) = RulingsSection.parse(md)
        XCTAssertEqual(rulings.count, 2)

        let afterFirst = RulingsSection.removing(rulingId: rulings[0].id, from: md)
        let afterBoth = RulingsSection.removing(rulingId: rulings[1].id, from: afterFirst)

        XCTAssertEqual(
            afterBoth, essayOnly,
            "removing every ruling must collapse the file to exactly its essay-only form — "
                + "no dangling '## Rulings' heading, matching a document that never had one")
        XCTAssertFalse(
            afterBoth.contains(RulingsSection.heading),
            "no rulings left means no stratum at all, not an empty one")

        let (finalEssay, finalRulings) = RulingsSection.parse(afterBoth)
        XCTAssertEqual(finalEssay, essayOnly)
        XCTAssertTrue(finalRulings.isEmpty)
    }

    func test_removing_unknownId_isNoOp_returnsInputUnchanged() {
        let md = """
        Essay.

        ## Rulings

        - Kelly never lies
        """
        let updated = RulingsSection.removing(rulingId: "not-a-real-id", from: md)
        XCTAssertEqual(updated, md)
    }

    // MARK: - byte fidelity for files this code wrote

    func test_render_ofParse_isByteIdentical_forWrittenFiles() throws {
        let date = try makeDate(day: 7, month: 8, year: 2026)
        let seed = RulingsSection.appending(
            "Kelly never lies", provenance: "from a run on ¶wnse", on: date, to: "Essay text.")
        let twice = RulingsSection.appending(
            "Denver hates prologues", provenance: "from a chat", on: date, to: seed)

        let (essay, rulings) = RulingsSection.parse(twice)
        let rerendered = RulingsSection.render(essay: essay, rulings: rulings)
        XCTAssertEqual(rerendered, twice)
    }

    // MARK: - hand edits converge by second render (palette convergence rule)

    func test_handEditsConvergeBySecondRender() {
        let md = """
        Essay.

        ## Rulings

        -   Kelly never lies
        """
        let (essay1, rulings1) = RulingsSection.parse(md)
        let firstRender = RulingsSection.render(essay: essay1, rulings: rulings1)

        let (essay2, rulings2) = RulingsSection.parse(firstRender)
        let secondRender = RulingsSection.render(essay: essay2, rulings: rulings2)

        XCTAssertEqual(secondRender, firstRender)
    }

    // MARK: - duplicate lines remain individually removable

    func test_duplicateRulingLinesRemainIndividuallyRemovable() {
        let md = """
        Essay.

        ## Rulings

        - Kelly never lies
        - Kelly never lies
        """
        let (_, rulings) = RulingsSection.parse(md)
        XCTAssertEqual(rulings.count, 2)
        XCTAssertNotEqual(rulings[0].id, rulings[1].id)

        let updated = RulingsSection.removing(rulingId: rulings[1].id, from: md)
        let (_, remaining) = RulingsSection.parse(updated)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, rulings[0].id)
    }

    // MARK: - helpers

    private func makeDate(day: Int, month: Int, year: Int) throws -> Date {
        var comps = DateComponents()
        comps.day = day
        comps.month = month
        comps.year = year
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return try XCTUnwrap(calendar.date(from: comps))
    }
}
