import XCTest
@testable import Maugham

final class ScreenplayLineMutatorTests: XCTestCase {
    private let blankAbove = LineNeighborhood(prevIsBlank: true, nextIsBlank: false)
    private let nonBlankAbove = LineNeighborhood(prevIsBlank: false, nextIsBlank: false)
    private let blankAboveAndBelow = LineNeighborhood(prevIsBlank: true, nextIsBlank: true)

    // MARK: - Action

    func test_mutateToAction_stripsAtPrefix() {
        let result = ScreenplayLineMutator.mutate(
            line: "@BARRY", to: .action, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "BARRY")
    }

    func test_mutateToAction_stripsTransitionPrefix() {
        let result = ScreenplayLineMutator.mutate(
            line: "> CUT TO:", to: .action, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "CUT TO:")
    }

    func test_mutateToAction_stripsParens() {
        let result = ScreenplayLineMutator.mutate(
            line: "(quietly)", to: .action, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "quietly")
    }

    func test_mutateToAction_stripsLeadingDot() {
        let result = ScreenplayLineMutator.mutate(
            line: ".barbershop", to: .action, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "barbershop")
    }

    // MARK: - Scene heading

    func test_mutateToSceneHeading_intWithBlankAbove_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "INT. ROOM - DAY", to: .sceneHeading, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "INT. ROOM - DAY")
    }

    func test_mutateToSceneHeading_intWithoutBlankAbove_addsForcedDot() {
        let result = ScreenplayLineMutator.mutate(
            line: "INT. ROOM - DAY", to: .sceneHeading, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, ".INT. ROOM - DAY")
    }

    func test_mutateToSceneHeading_dotlessStemWithBlankAbove_unchanged() {
        // Task 12: recognition widened to dot-less stems, so an existing
        // dot-less heading cycles intact (no forced `.` prepended).
        let result = ScreenplayLineMutator.mutate(
            line: "INT ROOM - DAY", to: .sceneHeading, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "INT ROOM - DAY")
    }

    func test_mutateToSceneHeading_ieDotlessStemWithBlankAbove_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "I/E CAR - NIGHT", to: .sceneHeading, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "I/E CAR - NIGHT")
    }

    func test_mutateToSceneHeading_unprefixedAddsForcedDot() {
        let result = ScreenplayLineMutator.mutate(
            line: "barbershop", to: .sceneHeading, neighborhood: blankAbove)
        XCTAssertEqual(result.text, ".barbershop")
    }

    // MARK: - Character

    func test_mutateToCharacter_allCapsBlankAboveContentBelow_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "BARRY", to: .character, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "BARRY")
    }

    func test_mutateToCharacter_allCapsButNoBlankAbove_addsAt() {
        let result = ScreenplayLineMutator.mutate(
            line: "BARRY", to: .character, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "@BARRY")
    }

    func test_mutateToCharacter_allCapsButOrphan_addsAt() {
        // blankAbove + blankBelow = orphan: parser would demote to .action.
        let result = ScreenplayLineMutator.mutate(
            line: "BARRY", to: .character, neighborhood: blankAboveAndBelow)
        XCTAssertEqual(result.text, "@BARRY")
    }

    func test_mutateToCharacter_lowercase_addsAt() {
        let result = ScreenplayLineMutator.mutate(
            line: "barry", to: .character, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "@barry")
    }

    func test_mutateToCharacter_mixedCase_addsAt() {
        let result = ScreenplayLineMutator.mutate(
            line: "Sam", to: .character, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "@Sam")
    }

    func test_mutateToCharacter_alreadyForced_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "@Sam", to: .character, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "@Sam")
    }

    // MARK: - Dialogue

    func test_mutateToDialogue_textUnchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "Hello there.", to: .dialogue, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "Hello there.")
    }

    // MARK: - Parenthetical

    func test_mutateToParenthetical_unwrappedTextWraps_cursorInsideParen() {
        let result = ScreenplayLineMutator.mutate(
            line: "quietly", to: .parenthetical, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "(quietly)")
        XCTAssertEqual(result.cursorOffset, 1)
    }

    func test_mutateToParenthetical_alreadyWrapped_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "(quietly)", to: .parenthetical, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "(quietly)")
    }

    // MARK: - Transition

    func test_mutateToTransition_allCapsTOWithBlankAbove_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "CUT TO:", to: .transition, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "CUT TO:")
    }

    func test_mutateToTransition_allCapsTOWithoutBlankAbove_addsForcedGreater() {
        let result = ScreenplayLineMutator.mutate(
            line: "CUT TO:", to: .transition, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "> CUT TO:")
    }

    func test_mutateToTransition_lowercase_addsForcedGreater() {
        let result = ScreenplayLineMutator.mutate(
            line: "cut to:", to: .transition, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "> cut to:")
    }

    func test_mutateToTransition_alreadyForced_stripsToContextual() {
        // Strip-then-apply: "> SMASH CUT TO:" strips to "SMASH CUT TO:",
        // which satisfies the contextual transition rule (blankAbove + allCaps
        // + ends in TO:), so the forced marker is dropped.
        let result = ScreenplayLineMutator.mutate(
            line: "> SMASH CUT TO:", to: .transition, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "SMASH CUT TO:")
    }

    // MARK: - Lyric

    func test_mutateToLyric_addsTilde() {
        let result = ScreenplayLineMutator.mutate(
            line: "la la la", to: .lyric, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "~la la la")
    }

    func test_mutateToLyric_alreadyTilde_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "~la la la", to: .lyric, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "~la la la")
    }

    // MARK: - Round trip

    func test_roundTrip_characterToActionStripsAt() {
        let toCharacter = ScreenplayLineMutator.mutate(
            line: "barry", to: .character, neighborhood: blankAbove)
        XCTAssertEqual(toCharacter.text, "@barry")
        let toAction = ScreenplayLineMutator.mutate(
            line: toCharacter.text, to: .action, neighborhood: blankAbove)
        XCTAssertEqual(toAction.text, "barry")
    }

    func test_idempotent_parentheticalDoubleApply() {
        let first = ScreenplayLineMutator.mutate(
            line: "quietly", to: .parenthetical, neighborhood: nonBlankAbove)
        let second = ScreenplayLineMutator.mutate(
            line: first.text, to: .parenthetical, neighborhood: nonBlankAbove)
        XCTAssertEqual(first.text, second.text)
    }

    // MARK: - Cycle-cleanup (strip-then-apply)

    func test_mutateToTransition_stripsExistingParensFromCycle() {
        // Cycling Parenthetical -> Transition should strip the parens
        // before prepending the transition marker, so the result is just
        // "> " not "> ()".
        let result = ScreenplayLineMutator.mutate(
            line: "()", to: .transition, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "> ")
    }

    func test_mutateToCharacter_stripsExistingParensFromCycle() {
        let result = ScreenplayLineMutator.mutate(
            line: "()", to: .character, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "@")
    }
}
