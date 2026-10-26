import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// The load-bearing pin for the windowed-typography perf fix
/// (`perf(editor): windowed typography application`).
///
/// For each (document, edit) case we assert that the INCREMENTAL path — apply
/// the edit to an already-styled storage so attributes shift the way they do in
/// production, then run the windowed restyle with old→new tokens — produces an
/// ATTRIBUTE-IDENTICAL storage to the WHOLE-DOC path (style the post-edit text
/// from scratch).
///
/// If this test fails, the window is dropping or mis-applying an attribute the
/// whole-doc path produces; investigate the window math / mode gating, do NOT
/// weaken the assertion. See `TokenRestyleWindow`, `ScreenplayMode`/`ProseMode`
/// `applyTypography`, and the Editor AREA guide.
final class WindowedTypographyEquivalenceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // absorbs the parallel-worker fontd cold-start window — see FontWarmup.swift
    }


    private let theme: Theme = .light

    // MARK: - Screenplay realistic document

    /// A ~30+ element screenplay with a title page, scene headings, action,
    /// character cues, parentheticals, dialogue, a transition, a section, a
    /// synopsis, an inline `[[todo:]]` task, and inline emphasis — so the diff
    /// exercises every styling pass.
    private let screenplayDoc = """
    Title: The Long Afternoon
    Author: A. Writer

    FADE IN:

    INT. KITCHEN - DAY

    Larry stands at the counter, *staring* at a cold cup of coffee.

    LARRY
    (muttering)
    Not again.

    He pours the coffee down the drain.

    BARRY
    You always do that.

    LARRY
    Do what?

    EXT. STREET - NIGHT

    The rain comes down in sheets. [[todo: describe the neon]]

    # Act Two

    = Larry confronts the truth about the afternoon.

    DETECTIVE MORALES
    Where were you at noon?

    LARRY
    Home. Drinking bad coffee.

    CUT TO:

    INT. PRECINCT - LATER

    Morales paces behind the glass.

    MORALES
    (to himself)
    He's lying.
    """

    private let proseDoc = """
    # The Long Afternoon

    Larry stood at the counter, *staring* at a cold cup of coffee. The
    morning had not gone the way he planned, and the **kitchen** felt
    smaller than it had the day before.

    ## Chapter One

    He thought about the meeting. About what [[Barry Sullivan]] had said,
    and how the words had landed like a slap he hadn't seen coming.

    - [ ] call the detective back
    - [x] throw out the coffee

    > Some quotes are worth remembering. This is not one of them.

    The `terminal` blinked on the desk. He had work to do, and a
    [[deadline]] that would not move for anyone.

    ## Chapter Two

    By the time the rain started, Larry had decided. He would tell
    Morales everything, and let the afternoon fall where it might.
    """

    /// Dual-dialogue fixture: LARRY speaks, then BARRY's cue carries the
    /// trailing `^` making his block the dual-second column — his
    /// parenthetical and dialogue lines INHERIT `isDualSecond` from the cue
    /// without their own text encoding it (FountainTokenizer). Used by the
    /// dual-caret regression cases below.
    private let dualDialogueDoc = """
    INT. BAR - NIGHT

    Larry and Barry argue across the counter, neither one listening.

    LARRY
    I can't believe you did that. After everything we talked about.

    BARRY ^
    (overlapping)
    You never believe anything. That's your whole problem, Larry.

    The bartender slides a glass between them.

    MORALES
    Gentlemen. Take it outside.

    They don't take it outside.
    """

    // MARK: - Dual-dialogue regression (review HIGH: inherited isDualSecond)

    /// Deleting the trailing ` ^` from a dual-second cue must de-dual the
    /// FOLLOWING parenthetical + dialogue lines too — their `isDualSecond` is
    /// inherited from the cue, not encoded in their own text, so without
    /// `isDualSecond` in token identity they matched (kind, length) and kept
    /// stale dual-column indents. (The originally-shipped windowing failed
    /// exactly here.)
    func test_screenplay_removeDualCaret_deDualsInheritedFollowers() {
        let edit = Edit(replace: "BARRY ^", with: "BARRY")
        assertEquivalent(doc: dualDialogueDoc, edit: edit, mode: .screenplay)
    }

    /// The symmetric direction: adding ` ^` to a solo cue must dual-ify the
    /// followers.
    func test_screenplay_addDualCaret_dualsInheritedFollowers() {
        let edit = Edit(replace: "MORALES", with: "MORALES ^")
        assertEquivalent(doc: dualDialogueDoc, edit: edit, mode: .screenplay)
    }

    /// The deeper hole that drove the token-identity fix (option 2 over a
    /// window-extension heuristic): a SAME-LENGTH overtype of the `^`
    /// (`BARRY ^` → `BARRY X`) changes `isDualSecond` for the cue and its
    /// followers without changing ANY token's length — only identity-aware
    /// tokens let the diff see it at all.
    func test_screenplay_sameLengthCaretOvertype_deDuals() {
        let edit = Edit(replace: "BARRY ^", with: "BARRY X")
        assertEquivalent(doc: dualDialogueDoc, edit: edit, mode: .screenplay)
    }

    /// Non-vacuity guard for the dual-caret pins: the removeDualCaret edit
    /// must produce a PROPER SUB-WINDOW (covering the cue + inherited
    /// followers) — not a full-document fallback, which would make the
    /// equivalence assertions above prove nothing about the windowed path.
    func test_removeDualCaret_producesProperSubWindow() {
        let oldTokens = tokenize(dualDialogueDoc, mode: .screenplay)
        let ns = dualDialogueDoc as NSString
        let r = ns.range(of: "BARRY ^")
        let newText = ns.replacingCharacters(in: r, with: "BARRY")
        let newTokens = tokenize(newText, mode: .screenplay)
        let decision = TokenRestyleWindow.decide(
            oldTokens: oldTokens, newTokens: newTokens,
            storageLength: (newText as NSString).length)
        guard case .window(let w) = decision else {
            return XCTFail("expected a sub-window, got \(decision)")
        }
        let newNS = newText as NSString
        XCTAssertLessThan(w.length, newNS.length,
                          "window covered the whole document — not actually windowed")
        XCTAssertGreaterThan(w.location, 0,
                             "window started at 0 — head was not trimmed")
        XCTAssertLessThan(NSMaxRange(w), newNS.length,
                          "window ran to end of document — tail was not trimmed")
        // The window must reach THROUGH the inherited-dual followers: the cue,
        // the parenthetical, and the dialogue line must all be inside it.
        for needle in ["BARRY", "(overlapping)", "your whole problem"] {
            let hit = newNS.range(of: needle)
            XCTAssertNotEqual(hit.location, NSNotFound, "fixture drifted: \(needle)")
            XCTAssertTrue(
                NSIntersectionRange(hit, w).length == hit.length,
                "window \(w) does not fully cover follower text '\(needle)' at \(hit)")
        }
    }

    // MARK: - Screenplay edit cases

    func test_screenplay_editInsideAction() {
        let edit = Edit(replace: "cold cup", with: "cold mug")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    /// Guards the test's own load-bearing-ness: a one-character mid-document
    /// insertion (the realistic keystroke) must produce a PROPER SUB-WINDOW
    /// (not a full-document fallback), otherwise the equivalence assertions
    /// above prove nothing about the windowing path. (A same-length swap that
    /// changes no token's kind/length correctly yields `.noChange`; here we
    /// change a token length so a window must be produced.)
    func test_diffProducesProperSubWindow_notFullFallback() {
        let oldTokens = tokenize(screenplayDoc, mode: .screenplay)
        let ns = screenplayDoc as NSString
        let r = ns.range(of: "cold cup of coffee")
        let newText = ns.replacingCharacters(in: r, with: "cold cup of fresh coffee")
        let newTokens = tokenize(newText, mode: .screenplay)
        let decision = TokenRestyleWindow.decide(
            oldTokens: oldTokens, newTokens: newTokens,
            storageLength: (newText as NSString).length)
        guard case .window(let w) = decision else {
            return XCTFail("expected a sub-window, got \(decision)")
        }
        XCTAssertLessThan(w.length, (newText as NSString).length,
                          "window covered the whole document — not actually windowed")
        XCTAssertGreaterThan(w.location, 0,
                             "window started at 0 — head was not trimmed")
        // The unchanged tail (everything after this action paragraph) must be
        // excluded from the window.
        XCTAssertLessThan(NSMaxRange(w), (newText as NSString).length,
                          "window ran to end of document — tail was not trimmed")
    }

    func test_screenplay_editInsideDialogue() {
        let edit = Edit(replace: "Not again.", with: "Not this again.")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    /// Reclassifies elements: lowercasing a CHARACTER cue makes it action and
    /// turns the following line from dialogue into action too.
    func test_screenplay_reclassifyCharacterCue() {
        // Turn an action line into a CHARACTER cue by uppercasing it, so the
        // following line reclassifies from action into dialogue.
        let edit = Edit(
            replace: "He pours the coffee down the drain.",
            with: "JANITOR")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_paragraphSplit() {
        // Insert a blank line inside the action, splitting one paragraph in two.
        let edit = Edit(
            replace: "comes down in sheets.",
            with: "comes down\n\nin sheets.")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_paragraphJoin() {
        // Delete a blank line, joining the section header onto the synopsis.
        let edit = Edit(
            replace: "# Act Two\n\n= Larry",
            with: "# Act Two\n= Larry")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_multiCharPasteMidDocument() {
        let edit = Edit(
            replace: "The rain comes down",
            with: "The rain comes down hard and fast and loud")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_editAtDocumentStart() {
        let edit = Edit(replace: "Title: The Long Afternoon",
                        with: "Title: The Very Long Afternoon")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_editAtDocumentEnd() {
        let edit = Edit(replace: "He's lying.", with: "He's clearly lying.")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    func test_screenplay_emojiInsertion() {
        // Emoji spans two UTF-16 code units; the window math is UTF-16-based.
        let edit = Edit(replace: "Do what?", with: "Do what? 🤔")
        assertEquivalent(doc: screenplayDoc, edit: edit, mode: .screenplay)
    }

    // MARK: - Prose edit cases

    func test_prose_editInsideParagraph() {
        let edit = Edit(replace: "cold cup of coffee", with: "cold mug of coffee")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    func test_prose_paragraphSplit() {
        let edit = Edit(replace: "the day before.",
                        with: "the day before.\n\nA new paragraph appears.")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    func test_prose_multiCharPasteMidDocument() {
        let edit = Edit(replace: "He had work to do",
                        with: "He had a great deal of important work to do")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    func test_prose_wikiLinkEdit() {
        let edit = Edit(replace: "[[Barry Sullivan]]",
                        with: "[[Barry T. Sullivan]]")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    func test_prose_emojiInsertion() {
        let edit = Edit(replace: "He would tell", with: "He would 🙂 tell")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    /// Editing before a markdown checkbox shifts the checkbox; its stamped
    /// `MaughamCheckboxMarker.bracketLocation` must stay current document-wide.
    func test_prose_editBeforeCheckbox_marker_staysCurrent() {
        let edit = Edit(replace: "had landed like a slap",
                        with: "had landed like a hard slap")
        assertEquivalent(doc: proseDoc, edit: edit, mode: .prose)
    }

    // MARK: - Report element cases (plan 3a Task 2)

    /// Every report element, between ordinary prose paragraphs.
    private var reportDoc: String {
        "Opening paragraph with *emphasis* before the findings.\n\n"
            + ReportTokenizerTests.reportSample
            + "\n\nA closing paragraph after everything else."
    }

    func test_report_editInsideATableHeaderCell() {
        let edit = Edit(replace: "| Name |", with: "| Full name |")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    func test_report_editInsideATableBodyCell() {
        let edit = Edit(replace: "| Grace |", with: "| Grace Hopper |")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    /// Breaking the delimiter row un-makes the table: the header row two
    /// lines up loses its bold although its own text did not change. The
    /// typing path must repaint the whole block, not just the edited line.
    func test_report_breakingTheDelimiterRowUnboldsTheHeader() {
        let edit = Edit(replace: "|:-----|-----:|", with: "|:-----|--x--:|")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    /// The reverse: completing the delimiter row makes the header bold.
    func test_report_completingTheDelimiterRowBoldsTheHeader() {
        let broken = reportDoc.replacingOccurrences(of: "|:-----|-----:|", with: "|:-----|--x--:|")
        let edit = Edit(replace: "|:-----|--x--:|", with: "|:-----|-----:|")
        assertEquivalent(doc: broken, edit: edit, mode: .prose)
    }

    func test_report_editTheTableCaption() {
        let edit = Edit(replace: "Engines of note", with: "Engines of real note")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    func test_report_editInsideACitation() {
        let edit = Edit(replace: "[@gartner2026, p. 12]", with: "[@gartner2026, pp. 12-14]")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    func test_report_unmakingACitation() {
        let edit = Edit(replace: "[@gartner2026, p. 12]", with: "[gartner2026, p. 12]")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    func test_report_editInsideAFootnoteDefinition() {
        let edit = Edit(replace: "Figures are nominal", with: "Figures are strictly nominal")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    func test_report_editAFootnoteReference() {
        let edit = Edit(replace: "shows.[^1]", with: "shows.[^12]")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    func test_report_editTheFigureLine() {
        let edit = Edit(replace: "Revenue by year", with: "Revenue by fiscal year")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    /// A second line under the figure makes it a two-line paragraph, which is
    /// no longer a figure: the untouched figure line above loses its styling.
    func test_report_aLineUnderTheFigureUnmakesIt() {
        let edit = Edit(replace: "{#fig:revenue}", with: "{#fig:revenue}\nand a second line")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    /// A blank line between the table and its caption detaches the caption.
    func test_report_aBlankLineDetachesTheCaption() {
        let edit = Edit(replace: "| Grace | 1952 |\n", with: "| Grace | 1952 |\n\n")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    func test_report_editTheHeadingLabel() {
        let edit = Edit(replace: "{#sec:findings}", with: "{#sec:finding}")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    /// Prose typed straight above a table (no blank line) un-makes the table.
    func test_report_proseJoinedAboveATableUnmakesIt() {
        // The anchor stops short of `[^1]`: a replace over it would wipe its
        // attributes in a way NSTextView's minimal edit never does.
        let edit = Edit(replace: "\n\n| Name", with: "\n| Name")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .prose)
    }

    // MARK: - The figure thumbnail's reserved space (plan 3a Task 7)
    //
    // A manuscript's ProseMode gives each figure line a `paragraphSpacing`
    // tall enough for its thumbnail. The windowed paint must add and remove it
    // exactly as the whole-document paint does.

    func test_thumbnail_editTheFigureCaption() {
        let edit = Edit(replace: "Revenue by year", with: "Revenue by fiscal year")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .manuscript)
    }

    func test_thumbnail_editTheFigurePath() {
        let edit = Edit(replace: "../research/rev.png", with: "../research/revenue.png")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .manuscript)
    }

    func test_thumbnail_aLineUnderTheFigureTakesTheSpaceAway() {
        let edit = Edit(replace: "{#fig:revenue}", with: "{#fig:revenue}\nand a second line")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .manuscript)
    }

    func test_thumbnail_closingTheBracketMakesTheFigureAndItsSpace() {
        let unmade = reportDoc.replacingOccurrences(of: "](../research/rev.png)",
                                                    with: "](../research/rev.png")
        let edit = Edit(replace: "rev.png{#fig", with: "rev.png){#fig")
        assertEquivalent(doc: unmade, edit: edit, mode: .manuscript)
    }

    /// Dropping the `!` un-makes the figure: its line loses the space (M3).
    func test_thumbnail_unmakingTheFigureRemovesItsSpace() {
        let edit = Edit(replace: "![Revenue by year]", with: "[Revenue by year]")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .manuscript)
    }

    func test_thumbnail_proseEditElsewhereKeepsTheSpace() {
        let edit = Edit(replace: "A closing paragraph", with: "A short closing paragraph")
        assertEquivalent(doc: reportDoc, edit: edit, mode: .manuscript)
    }

    // MARK: - The table card's reserved room (report plan 7a Task 4)
    //
    // A table figure's line reserves its card's height, read from the cached
    // model through the coordinator's `figureRoom(forLinePath:at:)`. The room is
    // data-derived (the row count), so both paints must read the same
    // function of the path, and a path the cache has not filled keeps the
    // placeholder (R7a-2).

    private let cardDoc = """
    Opening prose before the tables.

    ![Cash flows](figures/cash.csv){#tbl:cash}

    Middle prose between them.

    ![Staff by grade](figures/staff.csv){#tbl:staff}

    ![The full ledger](figures/ledger.csv){#tbl:ledger}

    ![Not filled yet](figures/unfilled.csv){#tbl:unfilled}

    A closing paragraph after the tables.
    """

    private static func table(rows: Int) -> FigureCardModel {
        let shown = min(rows, FigureCardModel.maxShownRows)
        return FigureCardModel(kind: .table, bodyRows: Array(repeating: ["1"], count: shown),
                               moreRows: rows - shown)
    }

    /// Three tables of 3, 7 and 40 rows; `figures/unfilled.csv` is a miss.
    private let cardModels: [String: FigureCardModel] = [
        "figures/cash.csv": table(rows: 3),
        "figures/staff.csv": table(rows: 7),
        "figures/ledger.csv": table(rows: 40),
    ]

    private var cardRoom: (String, Int) -> CGFloat {
        let models = cardModels
        return { path, _ in FigureCardMetrics.room(for: models[path], typography: .defaults) }
    }

    func test_card_eachTableLineReservesItsOwnCardsRoom() {
        let storage = NSTextStorage(string: cardDoc)
        applyWhole(storage, text: cardDoc, mode: .manuscript, figureRoom: cardRoom)
        func spacing(_ needle: String) -> CGFloat {
            let at = (storage.string as NSString).range(of: needle).location
            return (storage.attribute(.paragraphStyle, at: at, effectiveRange: nil)
                    as? NSParagraphStyle)?.paragraphSpacing ?? -1
        }
        let body = spacing("Middle prose")
        let rooms = ["cash", "staff", "ledger"].map { spacing("figures/\($0).csv") - body }
        XCTAssertEqual(rooms, ["cash", "staff", "ledger"].map {
            FigureCardMetrics.room(for: cardModels["figures/\($0).csv"], typography: .defaults)
        })
        XCTAssertEqual(Set(rooms).count, 3, "three row counts, three rooms: \(rooms)")
        XCTAssertEqual(spacing("figures/unfilled.csv") - body, FigureThumbnailLayout.reservedHeight,
                       "a cache miss reserves the placeholder")
        XCTAssertNotEqual(rooms[0], FigureThumbnailLayout.reservedHeight,
                          "a filled table's room is its card's, not the placeholder")
    }

    func test_card_editTheSecondTablesCaption() {
        let edit = Edit(replace: "Staff by grade", with: "Staff by grade and year")
        assertEquivalent(doc: cardDoc, edit: edit, mode: .manuscript, figureRoom: cardRoom)
    }

    func test_card_proseEditElsewhereKeepsEveryRoom() {
        let edit = Edit(replace: "Middle prose", with: "Some middle prose")
        assertEquivalent(doc: cardDoc, edit: edit, mode: .manuscript, figureRoom: cardRoom)
    }

    /// Re-pointing a line at a path the cache has not filled swaps its card's
    /// room for the placeholder, on both paints.
    func test_card_repointingALineToAMissTakesThePlaceholder() {
        let edit = Edit(replace: "figures/cash.csv", with: "figures/cashflow.csv")
        assertEquivalent(doc: cardDoc, edit: edit, mode: .manuscript, figureRoom: cardRoom)
    }

    func test_card_aLineUnderTheLongTableTakesItsRoomAway() {
        let edit = Edit(replace: "{#tbl:ledger}", with: "{#tbl:ledger}\nand a second line")
        assertEquivalent(doc: cardDoc, edit: edit, mode: .manuscript, figureRoom: cardRoom)
    }

    // MARK: - The expanded grid's room (report plan 7c Task 6)
    //
    // The line a grid is expanded on holds the grid's room, keyed by the
    // line's START (`figureRoom(forLinePath:at:)`), which the coordinator's
    // anchor carries through every edit. Both paints read that function.

    /// The card rooms, with the line starting where `"![Staff"` starts in
    /// `text` given the grid's room instead.
    private func expandedRoom(in text: String, room: CGFloat = 400) -> (String, Int) -> CGFloat {
        let start = (text as NSString).range(of: "![Staff").location
        let cards = cardRoom
        return { path, line in line == start ? room : cards(path, line) }
    }

    /// An edit above the expanded line moves its start; the anchor moves
    /// with it, so the windowed paint and a whole paint agree.
    func test_expandedGrid_anEditAboveTheExpandedLineKeepsItsRoomOnBothPaints() {
        let edit = Edit(replace: "Middle prose", with: "Some longer middle prose")
        let after = cardDoc.replacingOccurrences(of: "Middle prose", with: "Some longer middle prose")
        assertEquivalent(doc: cardDoc, edit: edit, mode: .manuscript,
                         figureRoom: expandedRoom(in: after), figureRoomBefore: expandedRoom(in: cardDoc))
    }

    /// Typing in the expanded line's caption keeps its room on both paints.
    func test_expandedGrid_editingTheExpandedLinesCaption() {
        let edit = Edit(replace: "Staff by grade", with: "Staff by grade and year")
        let after = cardDoc.replacingOccurrences(of: "Staff by grade", with: "Staff by grade and year")
        assertEquivalent(doc: cardDoc, edit: edit, mode: .manuscript,
                         figureRoom: expandedRoom(in: after), figureRoomBefore: expandedRoom(in: cardDoc))
    }

    /// R7c-4: the same figure on two lines — only the expanded line takes
    /// the grid's room; the other keeps its card's.
    func test_expandedGrid_theSameFigureOnAnotherLineKeepsItsCard() {
        let doc = cardDoc.replacingOccurrences(of: "![The full ledger](figures/ledger.csv){#tbl:ledger}",
                                               with: "![Staff again](figures/staff.csv)")
        let storage = NSTextStorage(string: doc)
        applyWhole(storage, text: doc, mode: .manuscript, figureRoom: expandedRoom(in: doc, room: 400))
        func spacing(_ needle: String) -> CGFloat {
            let at = (storage.string as NSString).range(of: needle).location
            return (storage.attribute(.paragraphStyle, at: at, effectiveRange: nil)
                    as? NSParagraphStyle)?.paragraphSpacing ?? -1
        }
        let body = spacing("Middle prose")
        XCTAssertEqual(spacing("![Staff by grade]") - body, 400, "the expanded line holds the grid's room")
        XCTAssertEqual(spacing("![Staff again]") - body,
                       FigureCardMetrics.room(for: cardModels["figures/staff.csv"], typography: .defaults),
                       "the same figure's other line keeps its card")
    }

    // MARK: - The caption bar's fade (report plan 7b Task 8, R7b-2)
    //
    // A manuscript paints a figure line's `![`, `](path)` and `{#…}` faded,
    // a pure function of the tokens: a label belongs to the fade only on a
    // figure line, and the caret never enters the paint.

    func test_fade_labellingAnUnlabelledTableLineFadesItsLabel() {
        let doc = cardDoc.replacingOccurrences(of: "{#tbl:staff}", with: "")
        let edit = Edit(replace: "](figures/staff.csv)", with: "](figures/staff.csv){#tbl:staff}")
        assertEquivalent(doc: doc, edit: edit, mode: .manuscript, figureRoom: cardRoom)
    }

    /// Dropping the `!` leaves `[Cash flows](…){#tbl:cash}` prose: its label
    /// and brackets lose the fade on both paints.
    func test_fade_unmakingATableLineUnfadesItsSyntax() {
        let edit = Edit(replace: "![Cash flows]", with: "[Cash flows]")
        assertEquivalent(doc: cardDoc, edit: edit, mode: .manuscript, figureRoom: cardRoom)
    }

    /// A heading's label two lines above a figure line keeps its own colour.
    func test_fade_aHeadingLabelBesideAFigureLineIsNotFaded() {
        let doc = "## Results {#sec:results}\n" + cardDoc
        let edit = Edit(replace: "## Results", with: "## Findings")
        assertEquivalent(doc: doc, edit: edit, mode: .manuscript, figureRoom: cardRoom)
    }

    // MARK: - The typing window's cap

    /// A 250 KB document with single newlines and no blank line is ONE block.
    /// An edit in its middle must still paint a bounded window, not the whole
    /// text (a whole-document `setAttributes` snaps scroll to the top).
    func test_typingWindow_isCappedInADocumentWithNoBlankLines() {
        let line = String(repeating: "word ", count: 16) + "end."
        var lines: [String] = []
        while lines.count * 85 < 250_000 { lines.append(line) }
        let old = lines.joined(separator: "\n") as NSString
        let mid = old.length / 2
        let new = old.replacingCharacters(in: NSRange(location: mid, length: 0), with: "x") as NSString

        let window = TypingRestyleWindow.changedBlockWindow(old: old, new: new)

        let cap = TypingRestyleWindow.maxWideningPerSide
        let lineLength = (line as NSString).length + 1
        XCTAssertNotNil(window)
        XCTAssertLessThanOrEqual(window?.length ?? .max, 2 * (cap + lineLength) + lineLength,
                                 "the widening must stop at the cap on each side")
        XCTAssertGreaterThan(window?.length ?? 0, 2 * cap,
                             "control: below the cap the window still widens over the block")
        XCTAssertTrue(NSLocationInRange(mid, window ?? NSRange()))
    }

    // MARK: - Equivalence harness

    /// `.manuscript` is the manuscript editor's ProseMode, which reserves the
    /// figure thumbnails' space; `.prose` is every other prose surface's.
    private enum ModeKind { case screenplay, prose, manuscript }

    private struct Edit {
        let replace: String
        let with: String
    }

    /// The window decision must never claim "no change needed" then leave the
    /// storage diverging; the assertion below enforces that by construction. We
    /// run the SAME diff the coordinator runs.
    private func assertEquivalent(
        doc oldText: String,
        edit: Edit,
        mode: ModeKind,
        figureRoom: ((String, Int) -> CGFloat)? = nil,
        figureRoomBefore: ((String, Int) -> CGFloat)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ns = oldText as NSString
        let editRange = ns.range(of: edit.replace)
        XCTAssertNotEqual(editRange.location, NSNotFound,
                          "edit anchor '\(edit.replace)' not found", file: file, line: line)
        let newText = ns.replacingCharacters(in: editRange, with: edit.with)

        let oldTokens = tokenize(oldText, mode: mode)
        let newTokens = tokenize(newText, mode: mode)

        // ----- Storage A: old text fully styled, then edited, then windowed -----
        let storageA = NSTextStorage(string: oldText)
        // The old text as it was painted: with the room function of THAT
        // text (an anchor keyed by line start moves with the edit).
        applyWhole(storageA, text: oldText, mode: mode, figureRoom: figureRoomBefore ?? figureRoom)
        // Apply the edit the way NSTextView does — attributes shift with chars.
        storageA.replaceCharacters(in: editRange, with: edit.with)
        XCTAssertEqual(storageA.length, (newText as NSString).length,
                       "edit produced wrong storage length", file: file, line: line)

        // ----- Storage B: new text styled whole-doc from scratch -----
        let storageB = NSTextStorage(string: newText)
        applyWhole(storageB, text: newText, mode: mode, figureRoom: figureRoom)

        // Two windows, each checked from the same edited storage: the token
        // diff (the oracle) and the typing path's own character diff widened
        // to blank-line blocks (`TypingRestyleWindow.changedBlockWindow`, what
        // `performDeferredRestyle` and `paintLiveWindowed` actually paint).
        let decision = TokenRestyleWindow.decide(
            oldTokens: oldTokens,
            newTokens: newTokens,
            storageLength: storageA.length)
        let tokenWindow: NSRange?
        switch decision {
        case .noChange:      tokenWindow = NSRange(location: 0, length: 0)
        case .window(let r): tokenWindow = r
        case .fullDocument:  tokenWindow = nil
        }
        let typingWindow = TypingRestyleWindow.changedBlockWindow(
            old: oldText as NSString, new: newText as NSString)
            ?? NSRange(location: 0, length: 0)

        for (name, window) in [("token-diff", tokenWindow), ("typing-path", typingWindow)] {
            let edited = NSMutableAttributedString(attributedString: storageA)
            let windowed = NSTextStorage(attributedString: edited)
            applyWindowed(windowed, tokens: newTokens, mode: mode, window: window,
                          figureRoom: figureRoom)
            assertStoragesEqual(windowed, storageB, label: name, file: file, line: line)
        }
    }

    private func tokenize(_ text: String, mode: ModeKind) -> [Token] {
        switch mode {
        case .screenplay: return ScreenplayMode().tokenize(text)
        case .prose:      return ProseMode().tokenize(text)
        case .manuscript: return ProseMode(reservesFigureThumbnails: true).tokenize(text)
        }
    }

    private func applyWhole(_ storage: NSTextStorage, text: String, mode: ModeKind,
                            figureRoom: ((String, Int) -> CGFloat)? = nil) {
        switch mode {
        case .screenplay:
            let m = ScreenplayMode()
            m.applyTypography(
                in: storage, theme: theme, typography: .screenplayDefaults,
                tokens: m.tokenize(text), parsedScript: FountainTokenizer().parse(text))
        case .prose, .manuscript:
            let m = ProseMode(reservesFigureThumbnails: mode == .manuscript)
            m.applyTypography(
                in: storage, theme: theme, typography: .defaults,
                tokens: m.tokenize(text), wikiLinkResolver: nil, figureRoom: figureRoom)
        }
    }

    private func applyWindowed(
        _ storage: NSTextStorage,
        tokens: [Token],
        mode: ModeKind,
        window: NSRange?,
        figureRoom: ((String, Int) -> CGFloat)? = nil
    ) {
        let text = storage.string
        switch mode {
        case .screenplay:
            let m = ScreenplayMode()
            m.applyTypography(
                in: storage, theme: theme, typography: .screenplayDefaults,
                tokens: tokens, parsedScript: FountainTokenizer().parse(text),
                restyleWindow: window)
        case .prose, .manuscript:
            let m = ProseMode(reservesFigureThumbnails: mode == .manuscript)
            m.applyTypography(
                in: storage, theme: theme, typography: .defaults,
                tokens: tokens, wikiLinkResolver: nil, figureRoom: figureRoom,
                restyleWindow: window)
        }
    }

    /// Enumerate every attribute at every character index and assert exact
    /// equality of the dictionaries — font, foregroundColor, paragraphStyle,
    /// underline/strikethrough, the custom checkbox marker, and any other key
    /// present in either storage.
    private func assertStoragesEqual(
        _ a: NSTextStorage,
        _ b: NSTextStorage,
        label: String,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(a.length, b.length, "[\(label)] storage length diverged",
                       file: file, line: line)
        guard a.length == b.length else { return }
        var diverged = 0
        for i in 0..<a.length where diverged < 3 {
            let attrsA = a.attributes(at: i, effectiveRange: nil)
            let attrsB = b.attributes(at: i, effectiveRange: nil)
            let keys = Set(attrsA.keys).union(attrsB.keys)
            for key in keys where !attributeValuesEqual(attrsA[key], attrsB[key], key: key) {
                diverged += 1
                XCTFail(
                    "[\(label)] attribute \(key.rawValue) diverged at index \(i): "
                        + "windowed=\(String(describing: attrsA[key])) "
                        + "whole=\(String(describing: attrsB[key]))",
                    file: file, line: line)
            }
        }
    }

    private func attributeValuesEqual(
        _ x: Any?, _ y: Any?, key: NSAttributedString.Key
    ) -> Bool {
        switch (x, y) {
        case (nil, nil):
            return true
        case let (px?, py?):
            if let fx = px as? NSFont, let fy = py as? NSFont { return fx == fy }
            if let cx = px as? NSColor, let cy = py as? NSColor { return cx == cy }
            if let sx = px as? NSParagraphStyle, let sy = py as? NSParagraphStyle {
                return sx.isEqual(sy)
            }
            if let mx = px as? MaughamCheckboxMarker,
               let my = py as? MaughamCheckboxMarker {
                return mx.bracketLocation == my.bracketLocation
                    && mx.checked == my.checked
                    && mx.kind == my.kind
            }
            if let ox = px as? NSObject, let oy = py as? NSObject {
                return ox.isEqual(oy)
            }
            return false
        default:
            return false
        }
    }
}
