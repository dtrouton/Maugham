import XCTest
@testable import MaughamCore

/// Task 12: a scene heading may start with a dot-less stem — `INT`, `EXT`,
/// `EST`, `INT/EXT`, `EXT/INT`, `I/E` (case-insensitive) — followed by `.`
/// (as before) OR a space. The space form requires at least one more
/// non-whitespace character on the line; a bare stem or `"INT "` alone is
/// action. The stem must not be a prefix of a longer word (`INTERIOR` stays
/// action because `INT` is followed by `E`, not a delimiter).
final class FountainDotlessStemTests: XCTestCase {

    private let parser = FountainTokenizer()

    private func element(_ text: String) -> ScreenplayElement {
        parser.parse(text).lines[0].element
    }

    // MARK: - Space-delimited stems now classify as headings

    func test_intSpaceForm_afterBlank_isSceneHeading() {
        XCTAssertEqual(element("INT ROOM - DAY"), .sceneHeading)
    }

    func test_ieSpaceForm_afterBlank_isSceneHeading() {
        XCTAssertEqual(element("I/E CAR - NIGHT"), .sceneHeading)
    }

    func test_extIntDottedForm_afterBlank_isSceneHeading() {
        XCTAssertEqual(element("EXT/INT. HOUSE"), .sceneHeading)
    }

    func test_intExtSpaceForm_afterBlank_isSceneHeading() {
        XCTAssertEqual(element("INT/EXT WAREHOUSE - DAWN"), .sceneHeading)
    }

    // MARK: - Dotted forms unchanged (today's behavior preserved)

    func test_intDotAlone_isSceneHeading() {
        XCTAssertEqual(element("INT."), .sceneHeading)
    }

    func test_intDotSpaceContent_isSceneHeading() {
        XCTAssertEqual(element("INT. KITCHEN - DAY"), .sceneHeading)
    }

    // MARK: - Guards: not a heading

    func test_interiorShot_isNotSceneHeading() {
        // Stem INT is followed by 'E' (not a delimiter) → the stem-boundary
        // guard rejects it as a scene heading. (An all-caps line with a blank
        // above is a tentative character cue, not action — that heuristic is
        // untouched by this task; the point here is that it never becomes a
        // slugline.)
        XCTAssertNotEqual(element("INTERIOR SHOT"), .sceneHeading)
    }

    func test_mixedCaseInteriorShot_isAction() {
        // "INTERIOR shot" — INT followed by 'E' (no delimiter) → not a
        // heading; mixed case → not a cue candidate → plain action.
        XCTAssertEqual(element("INTERIOR shot"), .action)
    }

    func test_bareIntStem_isNotSceneHeading() {
        // Bare "INT" with no delimiter → not a heading. (All-caps with a blank
        // above → tentative character cue, not action; the guarantee this task
        // makes is only that it never becomes a slugline.)
        XCTAssertNotEqual(element("INT"), .sceneHeading)
    }

    func test_intSpaceNothingAfter_isNotSceneHeading() {
        // "INT " with nothing after the space → not a heading.
        XCTAssertNotEqual(element("INT "), .sceneHeading)
    }

    func test_bareIntStem_lowercase_isAction() {
        // Lowercase "int" alone: not a heading (no delimiter) and not a cue
        // candidate (lowercase) → plain action.
        XCTAssertEqual(element("int"), .action)
    }

    func test_lowercaseInterestingProse_isAction() {
        // "Interesting…" — after INT comes 'e', not a delimiter → action.
        XCTAssertEqual(element("Interesting things happened."), .action)
    }

    // MARK: - Case-insensitive stems are spec-correct (documented for Task 16)

    /// `Int room` after a blank line WILL now classify as a scene heading:
    /// the Fountain spec accepts case-insensitive stems, so a line beginning
    /// `Int`/`int` at line start (blank above) reads as a slugline. Pinned
    /// here and noted in the syntax docs.
    func test_mixedCaseIntRoom_afterBlank_isSceneHeading() {
        XCTAssertEqual(element("Int room"), .sceneHeading)
    }

    // MARK: - Contextual gate unchanged (no blank line above → action)

    func test_intSpaceForm_midParagraph_isAction() {
        let s = parser.parse("He yelled.\nINT ROOM - DAY")
        XCTAssertEqual(s.lines[1].element, .action)
    }
}
