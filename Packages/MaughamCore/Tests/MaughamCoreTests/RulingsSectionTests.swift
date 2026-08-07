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

    // MARK: - a heading with nothing itemized under it is not a section

    /// **The whole-branch review's C1, at its root.** A blank-delimited heading
    /// with no list item under it used to qualify as the section boundary, which
    /// made every byte from the heading onward disappear out of
    /// `StatementEssay.half` — and the Intent pane binds that half. The writer
    /// typing the heading the guide told them to type watched it vanish from
    /// under the caret one keystroke after they finished it, with no stratum to
    /// show for it (the pane mounts one only when a ruling exists) and their
    /// typing undo stack cleared by the buffer replacement.
    ///
    /// Every prefix a writer passes THROUGH while typing it, because the defect
    /// fired on one of them and not on the finished shape.
    func test_aHeadingWithNothingUnderItIsNotASectionAtAll() {
        let whileTyping = [
            "Essay.\n\n## Rulings",
            "Essay.\n\n## Rulings\n",
            "Essay.\n\n## Rulings\n\n",
            "Essay.\n\n## Rulings\n\n\n",
            // The list marker alone, before there are any words after it —
            // `parse` skips an empty item, so this is still heading-only.
            "Essay.\n\n## Rulings\n\n- ",
            // A heading on line 0, which has its own arm in `parse`.
            "## Rulings",
            "## Rulings\n\n",
        ]
        for markdown in whileTyping {
            let (essay, rulings) = RulingsSection.parse(markdown)
            XCTAssertEqual(
                essay, markdown,
                "a heading with nothing itemized under it took bytes out of the "
                + "essay: \(markdown.debugDescription)")
            XCTAssertTrue(
                rulings.isEmpty,
                "a heading with no items itemized something: \(markdown.debugDescription)")
        }
    }

    /// The other half of C1: prose under a heading that has no items. It is
    /// reachable by pasting, it is not a list item, and `render` keeps only
    /// parsed items — so while the heading qualified, the next ruling verb
    /// (including the one an *answered compiler note* runs, which the writer
    /// does not experience as asking for anything to be rewritten) deleted it.
    func test_proseUnderAHeadingWithNoItemsStaysEssayAndSurvivesAVerb() throws {
        let md = """
        Essay.

        ## Rulings

        A paragraph I typed under my own heading.
        """
        let (essay, rulings) = RulingsSection.parse(md)
        XCTAssertEqual(essay, md, "the writer's paragraph left the essay")
        XCTAssertTrue(rulings.isEmpty)

        let date = try makeDate(day: 7, month: 8, year: 2026)
        let after = RulingsSection.appending(
            "Kelly never lies", provenance: "from a run", on: date, to: md)
        XCTAssertTrue(
            after.contains("A paragraph I typed under my own heading."),
            "a ruling deleted the writer's prose: \(after)")
        XCTAssertTrue(
            RulingsSection.parse(after).essay
                .contains("A paragraph I typed under my own heading."),
            "the writer's prose survived on disk but below the section boundary, "
            + "where the essay editor cannot show it and the NEXT verb deletes it: "
            + "\(after)")
    }

    /// A ruling landing on a document whose essay already ends with a heading
    /// the writer typed **adopts that heading** rather than writing a second
    /// one. Two headings is the shape whose lower half `parse` reads and whose
    /// upper half the next `render` deletes.
    func test_appendingAdoptsAHeadingTheWriterAlreadyTyped() throws {
        let date = try makeDate(day: 7, month: 8, year: 2026)
        for md in ["Essay.\n\n## Rulings", "Essay.\n\n## Rulings\n\n", "## Rulings\n\n"] {
            let after = RulingsSection.appending(
                "Kelly never lies", provenance: "from a run", on: date, to: md)
            XCTAssertEqual(
                after.components(separatedBy: "\n")
                    .filter { $0.trimmingCharacters(in: .whitespaces) == RulingsSection.heading }
                    .count,
                1, "the writer's own heading was left dangling above a second one: "
                + "\(after.debugDescription) (from \(md.debugDescription))")
            let (essay, rulings) = RulingsSection.parse(after)
            XCTAssertEqual(rulings.map(\.text), ["Kelly never lies"], after)
            XCTAssertFalse(
                essay.contains(RulingsSection.heading),
                "a dangling heading survived in the essay: \(after.debugDescription)")
        }
    }

    /// Adoption keeps the words that were under the adopted heading — they go
    /// back into the essay, above the canonical section, rather than being
    /// stranded under it.
    func test_adoptionKeepsTheProseThatWasUnderTheHeading() throws {
        let md = "Essay.\n\n## Rulings\n\nA paragraph I typed under my own heading.\n"
        let date = try makeDate(day: 7, month: 8, year: 2026)
        let after = RulingsSection.appending(
            "Kelly never lies", provenance: "from a run", on: date, to: md)

        let (essay, rulings) = RulingsSection.parse(after)
        XCTAssertEqual(essay, "Essay.\n\nA paragraph I typed under my own heading.", after)
        XCTAssertEqual(rulings.map(\.text), ["Kelly never lies"])

        // And it converges: a second pass moves nothing.
        let rerendered = RulingsSection.render(essay: essay, rulings: rulings)
        XCTAssertEqual(rerendered, after, "adoption is not idempotent")
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
