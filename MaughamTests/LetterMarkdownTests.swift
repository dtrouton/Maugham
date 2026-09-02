import XCTest
import MaughamCore
@testable import Maugham

/// **The letter as a durable document** (editorial letter P1 Task 10, spec
/// §3.6). `LetterMarkdown.render` is the whole of what *Keep this letter*
/// writes; `LetterKeepTests` covers where that text lands.
@MainActor
final class LetterMarkdownTests: XCTestCase {

    // MARK: - Fixtures

    /// Local noon on 2 September 2026, so the rendered day cannot slip a
    /// calendar day under any time zone the gate runs in.
    private var noon: Date {
        Calendar.current.date(
            from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))!
    }

    private func ref(_ id: String, _ excerpt: String) -> Diagnostic.Ref {
        Diagnostic.Ref(paragraphId: id, excerpt: excerpt)
    }

    private func letter(
        about: String = "You are writing about a house nobody lives in.",
        oneThing: String? = "Let the second scene end before it explains itself.",
        working: [Letter.Working] = [],
        habits: [Letter.Habit] = [],
        questions: [Letter.Question] = [],
        scenes: [Letter.Scene]? = nil,
        scenePosition: String? = nil
    ) -> Letter {
        Letter(about: about, oneThing: oneThing, working: working, habits: habits,
               questions: questions, scenes: scenes, scenePosition: scenePosition)
    }

    private func render(
        _ letter: Letter, editorName: String = "Le Guin",
        laneLine: String = "Le Guin \u{00b7} round 3"
    ) -> (title: String, body: String) {
        LetterMarkdown.render(
            letter, editorName: editorName, laneLine: laneLine, at: noon)
    }

    // MARK: - The heading

    /// **Voice, date and lane line, in the heading** — the three facts a
    /// writer opening this note in six months needs before the prose makes
    /// sense: who wrote it, when, and which round of which lane it came from.
    func test_theHeadingCarriesTheVoiceTheDateAndTheLaneLine() {
        let out = render(letter())
        XCTAssertEqual(out.title, "Letter from Le Guin \u{2014} 2 September 2026")
        XCTAssertTrue(out.body.hasPrefix("# Letter from Le Guin \u{2014} 2 September 2026\n"),
                      out.body)
        XCTAssertTrue(out.body.contains("*Le Guin \u{00b7} round 3*"), out.body)
    }

    /// A passless run has no lane to name. The italic line is omitted rather
    /// than drawn empty — a stray `**` over a letter is a lane the writer
    /// would go looking for.
    func test_aRunWithNoLaneDrawsNoLaneLine() {
        let out = render(letter(), editorName: "Claude", laneLine: "")
        XCTAssertEqual(out.title, "Letter from Claude \u{2014} 2 September 2026")
        // The block after the heading is the say-back, not an empty italic
        // line where the lane would have been.
        let blocks = out.body.components(separatedBy: "\n\n")
        XCTAssertEqual(blocks.count > 1 ? blocks[1] : "",
                       "You are writing about a house nobody lives in.", out.body)
    }

    // MARK: - The parts, in reading order

    /// **The schema's reading order, and the register on screen.** The
    /// headings are `LetterSection`'s own copy constants, so a kept letter and
    /// the letter it was kept from cannot call the same part two things
    /// (global constraint 12).
    func test_thePartsRenderAsSectionsInReadingOrder() {
        let out = render(letter(
            working: [Letter.Working(refs: [], what: "The rain holds.",
                                     why: "It never explains itself.")],
            habits: [Letter.Habit(name: "Explaining the weather", refs: [],
                                  cost: "The reader stops looking.",
                                  lesson: "Trust the image.",
                                  exercise: "Cut every sentence that says why.")],
            questions: [Letter.Question(refs: [], question: "Whose house is it?",
                                        lessonHeading: nil)],
            scenes: [Letter.Scene(refs: [], wants: "In", changes: "Nothing",
                                  turn: "None", charge: "-")]))
        let body = out.body
        let order = [
            "## \(LetterSection.workingTitle)",
            "## \(LetterSection.habitsTitle)",
            "## \(LetterSection.questionsTitle)",
            "## \(LetterSection.scenesTitle)",
        ]
        var cursor = body.startIndex
        for heading in order {
            let found = body.range(of: heading, range: cursor..<body.endIndex)
            XCTAssertNotNil(found, "\(heading) missing or out of order in:\n\(body)")
            cursor = found?.upperBound ?? cursor
        }
        // The say-back and the one thing lead, above every heading.
        guard let firstHeading = body.range(of: "## "),
              let about = body.range(of: "You are writing about a house"),
              let one = body.range(of: "Let the second scene end")
        else { return XCTFail("the letter's own prose is missing:\n\(body)") }
        XCTAssertTrue(about.lowerBound < firstHeading.lowerBound, body)
        XCTAssertTrue(one.lowerBound < firstHeading.lowerBound, body)
        // Every part's own prose survives.
        for words in ["The rain holds.", "It never explains itself.",
                      "Explaining the weather", "The reader stops looking.",
                      "Trust the image.", "Cut every sentence that says why.",
                      "Whose house is it?"] {
            XCTAssertTrue(body.contains(words), "\(words) missing from:\n\(body)")
        }
    }

    /// **An empty part draws no heading** — the rule the on-screen letter
    /// keeps (`LetterSection`'s own doc), for the same reason: a "Habits"
    /// heading over nothing tells the writer their reader had something to say
    /// about their habits.
    func test_anEmptyPartDrawsNoHeading() {
        let body = render(letter()).body
        for heading in [LetterSection.workingTitle, LetterSection.habitsTitle,
                        LetterSection.questionsTitle, LetterSection.scenesTitle] {
            XCTAssertFalse(body.contains("## \(heading)"),
                           "\(heading) drew a heading over nothing:\n\(body)")
        }
    }

    /// `scenes == nil` (a lyric piece) and `scenes == []` (a table with no
    /// rows) mean different things upstream and neither is a table.
    func test_neitherScenesNilNorScenesEmptyDrawsATable() {
        XCTAssertFalse(render(letter(scenes: nil)).body.contains("| \(LetterSection.wantsColumn)"))
        XCTAssertFalse(render(letter(scenes: [])).body.contains("| \(LetterSection.wantsColumn)"))
    }

    // MARK: - Refs

    /// **A ref reaches the note as the paragraph's own words, in italics** —
    /// the same thing the jump chip shows on screen, since a kept letter has
    /// no jump to offer and an id would be the schema showing through.
    func test_aRefRendersAsItsExcerptInItalics() {
        let body = render(letter(
            questions: [Letter.Question(
                refs: [ref("ab3d", "The house stood where the road bent.")],
                question: "Whose house is it?", lessonHeading: nil)])).body
        XCTAssertTrue(body.contains("*The house stood where the road bent.*"), body)
    }

    /// Every ref an entry carries is written down, not just the first: on
    /// screen the rest are "and N more" behind a chip, and a durable note has
    /// no chip to hide them behind.
    func test_everyRefOfAnEntryIsWrittenDown() {
        let body = render(letter(
            habits: [Letter.Habit(
                name: "Explaining", refs: [ref("ab3d", "First place."),
                                           ref("cd4e", "Second place.")],
                cost: "The reader stops.", lesson: nil, exercise: nil)])).body
        XCTAssertTrue(body.contains("*First place.*"), body)
        XCTAssertTrue(body.contains("*Second place.*"), body)
    }

    // MARK: - The scene table

    func test_theScenesRenderAsAMarkdownTable() {
        let body = render(letter(scenes: [
            Letter.Scene(refs: [], wants: "To be let in", changes: "The door opens",
                         turn: "She stays outside", charge: "-"),
            Letter.Scene(refs: [], wants: "To be told", changes: "", turn: "", charge: "+"),
        ])).body
        XCTAssertTrue(body.contains(
            "| \(LetterSection.wantsColumn) | \(LetterSection.changesColumn) "
            + "| \(LetterSection.turnColumn) | \(LetterSection.chargeColumn) |"), body)
        XCTAssertTrue(body.contains("| To be let in | The door opens | She stays outside | - |"),
                      body)
        // A blank cell stays blank — filling it with a dash would put words in
        // the reader's mouth (`LetterSection.scenesPart`'s own rule).
        XCTAssertTrue(body.contains("| To be told |  |  | + |"), body)
    }

    /// The charge column is drawn only when the form has a charge, exactly as
    /// the table on screen decides it (`LetterSection.hasCharge`).
    func test_aWeakFormTableCarriesNoChargeColumn() {
        let body = render(letter(scenes: [
            Letter.Scene(refs: [], wants: "To be let in", changes: "The door opens",
                         turn: "She stays outside", charge: nil),
        ])).body
        XCTAssertTrue(body.contains(
            "| \(LetterSection.wantsColumn) | \(LetterSection.changesColumn) "
            + "| \(LetterSection.turnColumn) |"), body)
        XCTAssertFalse(body.contains(LetterSection.chargeColumn), body)
    }

    /// A cell holding a pipe or a newline cannot be allowed to break the row
    /// it sits in — a table that stops being a table loses the writer the
    /// scenes below it.
    func test_aCellsPipeOrNewlineCannotBreakTheRow() {
        let body = render(letter(scenes: [
            Letter.Scene(refs: [], wants: "in | out", changes: "one\ntwo",
                         turn: "", charge: nil),
        ])).body
        guard let row = body.split(separator: "\n").first(where: { $0.contains("out |") })
        else { return XCTFail("no scene row in:\n\(body)") }
        XCTAssertEqual(String(row), "| in \\| out | one two |  |", body)
    }

    // MARK: - Never a paragraph id

    /// **The renderer never emits a paragraph id** (spec §3.6's own rule, and
    /// `DiagnosticsPane.jumpExcerpt`'s one layer out). The id is a join key;
    /// a kept letter is prose the writer reads.
    ///
    /// Asserted with the tripwire's own regex rather than a literal, so a
    /// leaked id in any shape is caught.
    func test_theRenderNeverEmitsAParagraphId() {
        let out = render(letter(
            about: "A say-back.",
            working: [Letter.Working(refs: [ref("ab3d", "First place.")],
                                     what: "It holds.", why: "It does not explain.")],
            habits: [Letter.Habit(name: "Explaining", refs: [ref("cd4e", "Second.")],
                                  cost: "Cost.", lesson: "Lesson.", exercise: "Exercise.")],
            questions: [Letter.Question(refs: [ref("ef5g", "Third.")],
                                        question: "Whose house?", lessonHeading: nil)],
            scenes: [Letter.Scene(refs: [ref("gh6j", "Fourth.")], wants: "In",
                                  changes: "Out", turn: "None", charge: "-")]))
        XCTAssertEqual(Self.paragraphIdTokens(in: out.body), [],
                       "a kept letter carries no join keys:\n\(out.body)")
        XCTAssertEqual(Self.paragraphIdTokens(in: out.title), [], out.title)
        // Control: the ids ARE in the input, so the assertion above is not
        // passing because there was nothing to leak.
        for id in ["ab3d", "cd4e", "ef5g", "gh6j"] {
            XCTAssertFalse(out.body.contains(id), "\(id) reached the note:\n\(out.body)")
        }
    }

    /// **CONTROL for the scrub.** A model that wrote an anchor into its own
    /// prose, or a paragraph excerpt carrying one, must still render clean —
    /// this is the case `LetterMarkdown.scrubbed` exists for, and the one that
    /// goes red when it is removed.
    func test_aPlantedAnchorIsScrubbedRatherThanCopiedThrough() {
        let out = render(letter(
            about: "A say-back <!-- \u{00b6}ab3d --> with an anchor in it.",
            oneThing: "One thing \u{00b6}cd4e trailing.",
            questions: [Letter.Question(
                refs: [ref("ef5g", "An excerpt <!-- \u{00b6}gh6j --> with one too.")],
                question: "Whose house?", lessonHeading: nil)]))
        XCTAssertEqual(Self.paragraphIdTokens(in: out.body), [],
                       "the scrub let one through:\n\(out.body)")
        // The prose around the anchor survives — the scrub takes the id, not
        // the sentence.
        XCTAssertTrue(out.body.contains("A say-back"), out.body)
        XCTAssertTrue(out.body.contains("with an anchor in it."), out.body)
        XCTAssertTrue(out.body.contains("One thing"), out.body)
        XCTAssertTrue(out.body.contains("An excerpt"), out.body)
    }

    /// **The scrub touches the anchor and nothing else.** A writer who double-
    /// spaces after a full stop keeps their own habit; the collapse exists
    /// only to close the gap an inline anchor leaves behind it.
    func test_theScrubLeavesProseItTookNothingOutOfAlone() {
        XCTAssertEqual(
            LetterMarkdown.scrubbed("She left.  He stayed."),
            "She left.  He stayed.")
        XCTAssertEqual(
            LetterMarkdown.scrubbed("She left. <!-- \u{00b6}ab3d --> He stayed."),
            "She left. He stayed.")
    }

    /// **A task anchor's removal earns the same collapse an id's does** (fix
    /// round 1, Minor 4). `MarkdownDisplayFilter.stripTaskAnchorsInline` eats
    /// one leading whitespace character, so the common ` <!--t-…-->` shape
    /// closes cleanly on its own — but an anchor written tight against the
    /// word before it and spaced after leaves the gap behind, and the collapse
    /// has to know a removal happened to close it.
    func test_aTaskAnchorsRemovalCollapsesItsGapToo() {
        XCTAssertEqual(
            LetterMarkdown.scrubbed("She left<!--t-ab3dfg-->  alone."),
            "She left alone.")
        XCTAssertEqual(
            LetterMarkdown.scrubbed("She left <!--t-ab3dfg--> alone."),
            "She left alone.",
            "and the common shape is unchanged")
    }

    /// Self-check: the matcher this file's negative assertions stand on does
    /// fire on a planted id. Without this, a broken regex would make every
    /// assertion above pass over any output at all.
    func test_theParagraphIdMatcherFiresOnAPlantedId() {
        XCTAssertEqual(
            Self.paragraphIdTokens(in: "a line <!-- \u{00b6}ab3d --> here"), ["ab3d"])
        XCTAssertEqual(Self.paragraphIdTokens(in: "no ids here"), [])
    }

    /// The tripwire's OWN pattern (`TripwireGrepTests.paragraphIdAnchorTokenPattern`,
    /// same test target), applied to rendered text rather than to source. Read
    /// rather than re-spelled: a second copy of the regex is a second answer to
    /// "what does a leaked id look like", and this file's every negative
    /// assertion stands on it.
    private static func paragraphIdTokens(in text: String) -> [String] {
        let pattern = TripwireGrepTests.paragraphIdAnchorTokenPattern
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }
}
