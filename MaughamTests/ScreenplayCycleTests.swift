import XCTest
@testable import Maugham

final class ScreenplayCycleTests: XCTestCase {

    // MARK: - cycleForward

    func test_cycleForward_action_returnsCharacter() {
        XCTAssertEqual(ScreenplayCycle.cycleForward(from: .action), .character)
    }

    func test_cycleForward_character_returnsDialogue() {
        XCTAssertEqual(ScreenplayCycle.cycleForward(from: .character), .dialogue)
    }

    func test_cycleForward_dialogue_returnsParenthetical() {
        XCTAssertEqual(ScreenplayCycle.cycleForward(from: .dialogue), .parenthetical)
    }

    func test_cycleForward_parenthetical_returnsTransition() {
        XCTAssertEqual(ScreenplayCycle.cycleForward(from: .parenthetical), .transition)
    }

    func test_cycleForward_transition_wrapsToAction() {
        XCTAssertEqual(ScreenplayCycle.cycleForward(from: .transition), .action)
    }

    // MARK: - cycleBackward

    func test_cycleBackward_action_wrapsToTransition() {
        XCTAssertEqual(ScreenplayCycle.cycleBackward(from: .action), .transition)
    }

    func test_cycleBackward_character_returnsAction() {
        XCTAssertEqual(ScreenplayCycle.cycleBackward(from: .character), .action)
    }

    func test_cycleBackward_dialogue_returnsCharacter() {
        XCTAssertEqual(ScreenplayCycle.cycleBackward(from: .dialogue), .character)
    }

    // MARK: - startingElement(after:)

    func test_startingElement_afterAction_isCharacter() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .action), .character)
    }

    func test_startingElement_afterCharacter_isDialogue() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .character), .dialogue)
    }

    func test_startingElement_afterParenthetical_isDialogue() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .parenthetical), .dialogue)
    }

    func test_startingElement_afterDialogue_isParenthetical() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .dialogue), .parenthetical)
    }

    func test_startingElement_afterTransition_isSceneHeading() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .transition), .sceneHeading)
    }

    func test_startingElement_afterSceneHeading_isAction() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .sceneHeading), .action)
    }

    func test_startingElement_afterCentered_isAction() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .centered), .action)
    }

    func test_startingElement_afterSection_isAction() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .section(level: 1)), .action)
    }
}
