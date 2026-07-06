import XCTest
@testable import MaughamCore

/// E1 (MCP smoke): a Fountain "held blank" — a whitespace-only line (length >= 1,
/// canonically two spaces) that pauses a dialogue block without ending it
/// (Task 13, `FountainTokenizer`) — was eaten by the op-log paragraph layer.
/// `ParagraphParser` split the whitespace-only line as a blank separator, so the
/// held line re-materialized as a REAL blank line and the dialogue continuation
/// downstream became `.action`. These tests pin the mode-aware fix: Fountain
/// documents preserve the held line inside the paragraph verbatim; prose keeps
/// whitespace-only = blank (writers leave invisible trailing spaces on separator
/// lines and paragraph identity must not hinge on them).
final class ParagraphParserHeldBlankTests: XCTestCase {

    /// The canonical E1 fixture: two dialogue lines separated by a two-space
    /// held blank, no truly-empty line anywhere.
    private let heldBlankFixture = """
    ALICE
    I wrote you every day for a *year*.
    \u{20}\u{20}
    And you never answered once.
    """

    // MARK: - Fountain mode preserves the held blank

    func test_fountainMode_heldBlank_staysOneParagraph() {
        let p = ParagraphParser.parse(
            heldBlankFixture, preservesHeldBlankLines: true)
        XCTAssertEqual(p.count, 1,
            "a two-space held blank must NOT split a Fountain paragraph")
        XCTAssertEqual(p[0].text, heldBlankFixture,
            "the held line must survive verbatim inside the paragraph")
    }

    func test_fountainMode_heldBlank_materializesByteIdentical() {
        let p = ParagraphParser.parse(
            heldBlankFixture, preservesHeldBlankLines: true)
        let id = "a3f9"
        let materialized = Materializer.materialize(
            paragraphs: [id: p[0].text], sequence: [id])
        // The two-space held line survives the round trip to the stored form
        // verbatim (ADR 0019: it is legitimate Fountain manuscript content).
        XCTAssertTrue(materialized.contains("\n\u{20}\u{20}\n"),
            "materialized stored form must keep the two-space held line intact")
    }

    func test_fountainMode_reparseOfMaterialized_isStable() {
        // parse -> materialize -> parse must reproduce the same single-paragraph
        // split (idempotence: the op-log join key must not flap between parses).
        let first = ParagraphParser.parse(
            heldBlankFixture, preservesHeldBlankLines: true)
        let id = "a3f9"
        let materialized = Materializer.materialize(
            paragraphs: [id: first[0].text], sequence: [id])
        let second = ParagraphParser.parse(
            materialized, preservesHeldBlankLines: true)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].id, id)
        XCTAssertEqual(second[0].text, first[0].text,
            "a second Fountain-mode parse must yield the identical split + text")
    }

    // MARK: - Prose mode is unchanged (the split is pinned)

    func test_proseMode_heldBlankFixture_splitsIntoTwo() {
        let p = ParagraphParser.parse(heldBlankFixture)  // default: prose
        XCTAssertEqual(p.count, 2,
            "prose keeps whitespace-only = blank; the fixture splits in two")
        XCTAssertEqual(p[0].text, "ALICE\nI wrote you every day for a *year*.")
        XCTAssertEqual(p[1].text, "And you never answered once.")
    }

    func test_proseMode_trailingSpaceSeparator_stillSplits() {
        // A trailing-space "blank" separator in PROSE must still split — writers
        // routinely leave invisible trailing spaces on separator lines and ¶
        // identity must not hinge on them.
        let p = ParagraphParser.parse("para A\n\u{20}\u{20}\npara B")
        XCTAssertEqual(p.map(\.text), ["para A", "para B"])
    }

    // MARK: - Fountain mode still splits on TRULY empty lines

    func test_fountainMode_trulyEmptyLine_stillSplits() {
        // A length-0 line separates paragraphs in every mode — only a
        // whitespace-only (length >= 1) line is a held blank.
        let text = "First speech.\n\nSecond speech."
        let p = ParagraphParser.parse(text, preservesHeldBlankLines: true)
        XCTAssertEqual(p.map(\.text), ["First speech.", "Second speech."])
    }

    func test_fountainMode_leadingWhitespaceOnlyLine_dropsIt() {
        // A whitespace-only line with no paragraph in progress is not a held
        // pause (nothing precedes it) — it is dropped, keeping the stored form
        // clean, exactly as a blank separator would be.
        let p = ParagraphParser.parse(
            "\u{20}\u{20}\nReal.", preservesHeldBlankLines: true)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].text, "Real.")
    }

    func test_fountainMode_noHeldBlanks_matchesProse() {
        // A Fountain doc with no whitespace-only lines must parse identically to
        // prose — the flag only changes held-blank handling, nothing else.
        let text = """
        INT. KITCHEN - DAY

        Aaron pours coffee.

        AARON
        Morning.
        """
        let fountain = ParagraphParser.parse(text, preservesHeldBlankLines: true)
        let prose = ParagraphParser.parse(text)
        XCTAssertEqual(fountain, prose)
    }
}
