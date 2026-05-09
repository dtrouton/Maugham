import XCTest
@testable import Maugham

final class ElementGutterAbbreviationTests: XCTestCase {

    func test_abbreviation_action_isNil() {
        XCTAssertNil(ElementGutterView.abbreviation(for: .action))
    }

    func test_abbreviation_sceneHeading_isSCENE() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .sceneHeading), "SCENE")
    }

    func test_abbreviation_character_isCHAR() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .character), "CHAR")
    }

    func test_abbreviation_dialogue_isDLG() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .dialogue), "DLG")
    }

    func test_abbreviation_parenthetical_isPAR() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .parenthetical), "PAR")
    }

    func test_abbreviation_transition_isTRANS() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .transition), "TRANS")
    }

    func test_abbreviation_centered_isCTR() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .centered), "CTR")
    }

    func test_abbreviation_lyric_isLYR() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .lyric), "LYR")
    }

    func test_abbreviation_section1_isSection1() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .section(level: 1)), "§1")
    }

    func test_abbreviation_section3_isSection3() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .section(level: 3)), "§3")
    }

    func test_abbreviation_synopsis_isSYN() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .synopsis), "SYN")
    }

    func test_abbreviation_pageBreak_isPAGE() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .pageBreak), "PAGE")
    }

    func test_abbreviation_boneyard_isCUT() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .boneyard), "CUT")
    }

    func test_abbreviation_note_isNOTE() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .note), "NOTE")
    }
}
