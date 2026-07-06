import XCTest
import MaughamCore
@testable import Maugham

final class FountainTokenizerTests: XCTestCase {
    private let parser = FountainTokenizer()

    // MARK: - Foundations

    func test_emptyText_returnsEmptyScript() {
        XCTAssertEqual(parser.parse(""), .empty)
    }

    func test_singleActionLine_classifiesAsAction() {
        let script = parser.parse("Larry sits at the bar.")
        XCTAssertEqual(script.lines.count, 1)
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertEqual(script.lines[0].content, "Larry sits at the bar.")
        XCTAssertEqual(script.lines[0].isForced, false)
        XCTAssertEqual(script.lines[0].sourceCase, .mixed)
    }

    func test_blankLineBetweenActions_producesBlankActionRow() {
        let script = parser.parse("First.\n\nSecond.")
        XCTAssertEqual(script.lines.count, 3)
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertEqual(script.lines[1].element, .action)
        XCTAssertEqual(script.lines[1].content, "")
        XCTAssertEqual(script.lines[1].sourceCase, .neutral)
        XCTAssertEqual(script.lines[2].element, .action)
    }

    // MARK: - Scene heading

    func test_sceneHeadingINT_afterBlank_classifiesAsSceneHeading() {
        let script = parser.parse("INT. KITCHEN - DAY")
        XCTAssertEqual(script.lines.count, 1)
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
        XCTAssertEqual(script.lines[0].content, "INT. KITCHEN - DAY")
        XCTAssertEqual(script.lines[0].isForced, false)
    }

    func test_sceneHeadingEXT_afterBlank_classifiesAsSceneHeading() {
        let script = parser.parse("Action one.\n\nEXT. ROOFTOP - NIGHT")
        XCTAssertEqual(script.lines.last?.element, .sceneHeading)
    }

    func test_sceneHeadingEST_afterBlank_classifiesAsSceneHeading() {
        let script = parser.parse("EST. MEADOW - DAWN")
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
    }

    func test_sceneHeadingIE_combined_classifiesAsSceneHeading() {
        let script = parser.parse("I/E. CAR - CONTINUOUS")
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
    }

    func test_sceneHeadingForcedDot_classifiesAsSceneHeading() {
        let script = parser.parse(".barbershop")
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
        XCTAssertEqual(script.lines[0].content, "barbershop")
        XCTAssertEqual(script.lines[0].isForced, true)
        XCTAssertEqual(script.lines[0].sourceCase, .lower)
    }

    func test_intMidParagraph_isNotSceneHeading() {
        // Without a blank line above, "INT." mid-text is just action.
        let script = parser.parse("He yelled.\nINT. ROOM - DAY")
        XCTAssertEqual(script.lines[1].element, .action)
    }

    func test_doubleDotPrefix_isAction_notSceneHeading() {
        // Two dots is NOT a forced scene heading per Fountain spec.
        let script = parser.parse("..ellipsis-ish")
        XCTAssertEqual(script.lines[0].element, .action)
    }

    // MARK: - Character / Dialogue / Parenthetical

    func test_allCapsLine_followedByDialogue_classifiesAsCharacter() {
        let script = parser.parse("BARRY\nHello there.")
        XCTAssertEqual(script.lines[0].element, .character)
        XCTAssertEqual(script.lines[0].content, "BARRY")
        XCTAssertEqual(script.lines[0].sourceCase, .upper)
        XCTAssertEqual(script.lines[1].element, .dialogue)
        XCTAssertEqual(script.lines[1].content, "Hello there.")
    }

    func test_allCapsLine_alone_classifiesAsCharacter() {
        // ALL-CAPS line preceded by blank classifies as Character even
        // without dialogue below — supports live editing where the user
        // is mid-typing (about to type dialogue but hasn't yet).
        let script = parser.parse("BARRY\n")
        XCTAssertEqual(script.lines[0].element, .character)
    }

    func test_forcedCharacterAt_classifiesAsCharacter() {
        let script = parser.parse("@Sam\nHi.")
        XCTAssertEqual(script.lines[0].element, .character)
        XCTAssertEqual(script.lines[0].content, "Sam")
        XCTAssertEqual(script.lines[0].isForced, true)
        XCTAssertEqual(script.lines[0].sourceCase, .mixed)
    }

    func test_parentheticalBetweenCharacterAndDialogue() {
        let script = parser.parse("BARRY\n(quietly)\nHi.")
        XCTAssertEqual(script.lines[0].element, .character)
        XCTAssertEqual(script.lines[1].element, .parenthetical)
        XCTAssertEqual(script.lines[1].content, "(quietly)")
        XCTAssertEqual(script.lines[2].element, .dialogue)
    }

    func test_dialogueContinuesAcrossMultipleLines() {
        let script = parser.parse("BARRY\nLine one.\nLine two.\nLine three.")
        XCTAssertEqual(script.lines[1].element, .dialogue)
        XCTAssertEqual(script.lines[2].element, .dialogue)
        XCTAssertEqual(script.lines[3].element, .dialogue)
    }

    func test_dialogueEndsAtBlankLine() {
        let script = parser.parse("BARRY\nDialogue.\n\nAction line.")
        XCTAssertEqual(script.lines[1].element, .dialogue)
        XCTAssertEqual(script.lines[3].element, .action)
    }

    // MARK: - Held blank (two-space) line in dialogue

    func test_twoSpaceLine_holdsDialogueOpen() {
        let s = FountainTokenizer().parse("DAN\nThen.\n  \nWhaddya want?\n")
        // [DAN, Then., <held blank>, Whaddya want?, <trailing synthetic empty
        // from the source's final "\n">]
        XCTAssertEqual(s.lines.map(\.element),
                       [.character, .dialogue, .dialogue, .dialogue, .action])
        // The held line itself is a `.dialogue` line with empty content.
        XCTAssertEqual(s.lines[2].content, "")
    }

    func test_emptyLine_stillEndsDialogue() {
        let s = FountainTokenizer().parse("DAN\nThen.\n\nAction now.\n")
        // [DAN, Then., <blank action>, Action now., <trailing empty>]
        XCTAssertEqual(s.lines.map(\.element),
                       [.character, .dialogue, .action, .action, .action])
        XCTAssertEqual(s.lines[2].content, "")
    }

    func test_heldBlank_afterParenthetical_staysDialogue() {
        // A held blank while inside a dialogue block gated by a preceding
        // parenthetical (not just a cue) also stays open.
        let script = parser.parse("DAN\n(beat)\nThen.\n  \nMore.")
        XCTAssertEqual(script.lines.map(\.element),
                       [.character, .parenthetical, .dialogue, .dialogue, .dialogue])
    }

    func test_heldBlank_doesNotMisclassifyFollowingSceneHeading() {
        // A following ALL-CAPS-with-dot line inside an *open* dialogue block
        // must still be treated as dialogue continuation — the held blank
        // must not set prevBlank=true and re-trigger the blank-gated
        // scene-heading check mid-block.
        let script = parser.parse("DAN\nThen.\n  \nINT. HOUSE - DAY")
        XCTAssertEqual(script.lines.map(\.element),
                       [.character, .dialogue, .dialogue, .dialogue])
        XCTAssertEqual(script.lines[3].content, "INT. HOUSE - DAY")
    }

    func test_heldBlank_doesNotMisclassifyFollowingCue() {
        // Same concern for the all-caps-cue check.
        let script = parser.parse("DAN\nThen.\n  \nSTEVE")
        XCTAssertEqual(script.lines.map(\.element),
                       [.character, .dialogue, .dialogue, .dialogue])
    }

    func test_heldBlank_preservesDualSecondPropagation() {
        // The held blank line itself, and the dialogue after it, both keep
        // carrying the dual-second flag across the pause.
        let script = parser.parse("BRICK\nHi.\n\nSTEVE ^\nThen.\n  \nMore.")
        // [BRICK, Hi., blank, STEVE ^, Then., <held>, More.]
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertTrue(script.lines[3].isDualSecond)
        XCTAssertEqual(script.lines[4].element, .dialogue)
        XCTAssertTrue(script.lines[4].isDualSecond)
        XCTAssertEqual(script.lines[5].element, .dialogue)
        XCTAssertEqual(script.lines[5].content, "")
        XCTAssertTrue(script.lines[5].isDualSecond)
        XCTAssertEqual(script.lines[6].element, .dialogue)
        XCTAssertTrue(script.lines[6].isDualSecond)
    }

    func test_doubleHeldBlank_bothStayDialogue() {
        // Two consecutive two-space held lines both stay open as dialogue
        // (the held gate doesn't require the very next line to close it).
        let s = FountainTokenizer().parse("DAN\nA.\n  \n  \nB.\n")
        // [DAN, A., <held>, <held>, B., <trailing synthetic empty>]
        XCTAssertEqual(s.lines.map(\.element),
                       [.character, .dialogue, .dialogue, .dialogue, .dialogue, .action])
        XCTAssertEqual(s.lines[2].content, "")
        XCTAssertEqual(s.lines[3].content, "")
    }

    func test_heldBlank_atEndOfFile_noCrash_staysDialogue() {
        // A held blank with nothing after it (no trailing newline) must not
        // crash the state machine, and the held line itself stays dialogue —
        // there's no follow-on content to force it closed.
        let s = FountainTokenizer().parse("DAN\nA.\n  ")
        XCTAssertEqual(s.lines.map(\.element),
                       [.character, .dialogue, .dialogue])
        XCTAssertEqual(s.lines[2].content, "")
    }

    func test_twoSpaceLine_outsideDialogue_isStillBlankAction() {
        // Outside a dialogue block, a whitespace-only line behaves exactly
        // as a truly empty line always has — an `.action` blank row.
        let script = parser.parse("Action one.\n  \nAction two.")
        XCTAssertEqual(script.lines.map(\.element), [.action, .action, .action])
        XCTAssertEqual(script.lines[1].content, "")
    }

    func test_forcedActionBang_classifiesAsAction() {
        // Without bang, an ALL-CAPS line preceded by blank with following
        // non-blank line would be Character. Forced-action bang overrides.
        let script = parser.parse("!ALL CAPS DESCRIPTION\nMore action.")
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertEqual(script.lines[0].content, "ALL CAPS DESCRIPTION")
        XCTAssertEqual(script.lines[0].isForced, true)
    }

    // MARK: - Transition / Centered / Lyric

    func test_allCapsTransition_endingInTo_classifiesAsTransition() {
        let script = parser.parse("Action one.\n\nSMASH CUT TO:\n\nINT. NEXT - DAY")
        XCTAssertEqual(script.lines[2].element, .transition)
        XCTAssertEqual(script.lines[2].content, "SMASH CUT TO:")
        XCTAssertEqual(script.lines[2].isForced, false)
    }

    func test_forcedTransitionGreater_classifiesAsTransition() {
        let script = parser.parse("> cut to:")
        XCTAssertEqual(script.lines[0].element, .transition)
        XCTAssertEqual(script.lines[0].content, "cut to:")
        XCTAssertEqual(script.lines[0].isForced, true)
        XCTAssertEqual(script.lines[0].sourceCase, .lower)
    }

    func test_centeredAngleBrackets_classifiesAsCentered() {
        let script = parser.parse("> THE END <")
        XCTAssertEqual(script.lines[0].element, .centered)
        XCTAssertEqual(script.lines[0].content, "THE END")
    }

    func test_centeredAngleBrackets_noSpaces_classifiesAsCentered() {
        let script = parser.parse(">centered<")
        XCTAssertEqual(script.lines[0].element, .centered)
        XCTAssertEqual(script.lines[0].content, "centered")
    }

    func test_lyricTilde_classifiesAsLyric() {
        let script = parser.parse("~la la la")
        XCTAssertEqual(script.lines[0].element, .lyric)
        XCTAssertEqual(script.lines[0].content, "la la la")
        XCTAssertEqual(script.lines[0].isForced, true)
    }

    // MARK: - Section / Synopsis / Page Break

    func test_sectionLevelOne_classifiesAsSection1() {
        let script = parser.parse("# ACT ONE")
        XCTAssertEqual(script.lines[0].element, .section(level: 1))
        XCTAssertEqual(script.lines[0].content, "ACT ONE")
    }

    func test_sectionLevelThree_classifiesAsSection3() {
        let script = parser.parse("### Beat")
        XCTAssertEqual(script.lines[0].element, .section(level: 3))
        XCTAssertEqual(script.lines[0].content, "Beat")
    }

    func test_sectionLevelSix_classifiesAsSection6() {
        let script = parser.parse("###### deep")
        XCTAssertEqual(script.lines[0].element, .section(level: 6))
    }

    func test_sectionLevelSeven_isAction() {
        // Fountain caps section nesting at 6.
        let script = parser.parse("####### too deep")
        XCTAssertEqual(script.lines[0].element, .action)
    }

    func test_synopsisEquals_classifiesAsSynopsis() {
        let script = parser.parse("= the chase begins")
        XCTAssertEqual(script.lines[0].element, .synopsis)
        XCTAssertEqual(script.lines[0].content, "the chase begins")
    }

    func test_pageBreakTripleEquals_classifiesAsPageBreak() {
        let script = parser.parse("===")
        XCTAssertEqual(script.lines[0].element, .pageBreak)
    }

    func test_pageBreakManyEquals_classifiesAsPageBreak() {
        let script = parser.parse("==========")
        XCTAssertEqual(script.lines[0].element, .pageBreak)
    }

    func test_doubleEquals_isAction_notPageBreak() {
        // Per Fountain spec: page break requires THREE or more =.
        let script = parser.parse("==")
        XCTAssertEqual(script.lines[0].element, .action)
    }

    func test_synopsisRequiresSpace_singleEqualsAlone_isAction() {
        // "=" alone (no content after) classifies as action; spec requires
        // "= space content" for synopsis.
        let script = parser.parse("=")
        XCTAssertEqual(script.lines[0].element, .action)
    }

    // MARK: - Boneyard / Notes

    func test_boneyardSingleLine_classifiesAsBoneyard() {
        let script = parser.parse("/* cut */")
        XCTAssertEqual(script.lines[0].element, .boneyard)
    }

    func test_boneyardMultiLine_allLinesClassifiedAsBoneyard() {
        let script = parser.parse("/* cut\nthis was here\nfor pacing */\n\nResume.")
        XCTAssertEqual(script.lines[0].element, .boneyard)
        XCTAssertEqual(script.lines[1].element, .boneyard)
        XCTAssertEqual(script.lines[2].element, .boneyard)
        XCTAssertEqual(script.lines[4].element, .action)
        XCTAssertEqual(script.lines[4].content, "Resume.")
    }

    func test_blockNoteSingleLine_classifiesAsNote() {
        let script = parser.parse("[[ todo ]]")
        XCTAssertEqual(script.lines[0].element, .note)
    }

    func test_blockNoteMultiLine_allLinesClassifiedAsNote() {
        let script = parser.parse("[[ todo:\nrewrite this beat\nmaybe ]]")
        XCTAssertEqual(script.lines[0].element, .note)
        XCTAssertEqual(script.lines[1].element, .note)
        XCTAssertEqual(script.lines[2].element, .note)
    }

    func test_inlineNoteWithinAction_lineStaysAction_inlineSpanRecorded() {
        let script = parser.parse("Action with [[ note ]] inside.")
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertEqual(script.lines[0].inlineSpans.count, 1)
        XCTAssertEqual(script.lines[0].inlineSpans[0].kind, .note)
        // The inline span covers "[[ note ]]" within the line; range
        // location is the line's range start + 12 (length of "Action with ").
        let span = script.lines[0].inlineSpans[0].range
        XCTAssertEqual(span.length, 10)   // "[[ note ]]"
    }

    func test_actionAfterBoneyardClose_classifiesAsAction() {
        // Verify state machine returns to .normal after */.
        let script = parser.parse("/* cut */\nNot boneyard.")
        XCTAssertEqual(script.lines[0].element, .boneyard)
        XCTAssertEqual(script.lines[1].element, .action)
    }

    // MARK: - Dual dialogue

    func test_characterCue_trailingCaret_marksIsDualSecond() {
        let script = parser.parse("BRICK\nHi.\n\nSTEVE ^\nHi.")
        // Lines: [BRICK, Hi., blank, STEVE ^, Hi.]
        XCTAssertEqual(script.lines.count, 5)
        XCTAssertEqual(script.lines[0].element, .character)
        XCTAssertFalse(script.lines[0].isDualSecond)
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertTrue(script.lines[3].isDualSecond)
    }

    func test_dualSecond_propagatesToFollowingDialogueAndParenthetical() {
        let script = parser.parse("BRICK\nHi.\n\nSTEVE ^\n(quietly)\nHi back.")
        // Lines: [BRICK, Hi., blank, STEVE ^, (quietly), Hi back.]
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertTrue(script.lines[3].isDualSecond)
        XCTAssertEqual(script.lines[4].element, .parenthetical)
        XCTAssertTrue(script.lines[4].isDualSecond)
        XCTAssertEqual(script.lines[5].element, .dialogue)
        XCTAssertTrue(script.lines[5].isDualSecond)
    }

    func test_dualSecond_doesNotPropagatePastBlankLine() {
        let script = parser.parse("BRICK\nHi.\n\nSTEVE ^\nHi.\n\nALICE\nCheers.")
        // After the blank line following STEVE's "Hi.", ALICE is a fresh cue.
        XCTAssertEqual(script.lines.count, 8)
        XCTAssertEqual(script.lines[6].element, .character)
        XCTAssertEqual(script.lines[6].content, "ALICE")
        XCTAssertFalse(script.lines[6].isDualSecond)
        XCTAssertEqual(script.lines[7].element, .dialogue)
        XCTAssertFalse(script.lines[7].isDualSecond)
    }

    func test_doubleCaret_treatedAsSingleMarker() {
        // Only the trailing single ^ is consumed; the rest stays in content.
        let script = parser.parse("BRICK\nHi.\n\nSTEVE ^^\nHi.")
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertTrue(script.lines[3].isDualSecond)
        // The leading ^ remains in the cue text (content is "STEVE ^").
        XCTAssertEqual(script.lines[3].content, "STEVE ^")
    }

    func test_leadingCaret_notRecognizedAsDualMarker() {
        // ^STEVE has the caret at the start; not the trailing marker.
        let script = parser.parse("BRICK\nHi.\n\n^STEVE\nHi.")
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertFalse(script.lines[3].isDualSecond)
    }

    func test_forcedCharacter_withCaret_setsBothFlags() {
        let script = parser.parse("BRICK\nHi.\n\n@steve ^\nHi.")
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertTrue(script.lines[3].isForced)
        XCTAssertTrue(script.lines[3].isDualSecond)
    }

    func test_danglingDualSecond_noPriorCue_stillFlagsCue() {
        // Document opens with a ^-marked cue — no prior block.
        // Parser stays permissive; pairing is a page-count concern.
        let script = parser.parse("STEVE ^\nHi.")
        XCTAssertEqual(script.lines[0].element, .character)
        XCTAssertTrue(script.lines[0].isDualSecond)
    }

    func test_caretInActionLine_isNotDualMarker() {
        // Caret in prose action text must not be misinterpreted.
        let script = parser.parse("The cursor ^^ blinks.")
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertFalse(script.lines[0].isDualSecond)
    }
}
