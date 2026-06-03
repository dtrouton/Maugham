import XCTest
@testable import MaughamCore

/// Unit tests that pin the `ScreenplayUppercase` decision values.
/// These are intentionally exhaustive so adding a new `ScreenplayElement`
/// without classifying it in `shouldDisplayUppercase` is a compile error,
/// and changing the set without updating these tests is a test failure.
final class ScreenplayUppercaseTests: XCTestCase {

    // MARK: – Uppercased elements

    func test_sceneHeading_isUppercased() {
        XCTAssertTrue(ScreenplayUppercase.shouldDisplayUppercase(.sceneHeading))
    }

    func test_transition_isUppercased() {
        XCTAssertTrue(ScreenplayUppercase.shouldDisplayUppercase(.transition))
    }

    // MARK: – As-typed elements

    func test_action_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.action))
    }

    func test_character_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.character))
    }

    func test_dialogue_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.dialogue))
    }

    func test_parenthetical_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.parenthetical))
    }

    func test_centered_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.centered))
    }

    func test_lyric_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.lyric))
    }

    func test_section_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.section(level: 1)))
    }

    func test_synopsis_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.synopsis))
    }

    func test_note_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.note))
    }

    func test_pageBreak_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.pageBreak))
    }

    func test_boneyard_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.boneyard))
    }

    func test_titlePage_isNotUppercased() {
        XCTAssertFalse(ScreenplayUppercase.shouldDisplayUppercase(.titlePage))
    }
}
