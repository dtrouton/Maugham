import XCTest
import MaughamCore
@testable import Maugham

final class FountainScriptPageCountTests: XCTestCase {
    private let parser = FountainTokenizer()

    func test_emptyScript_pageCountIsZero() {
        XCTAssertEqual(FountainScript.empty.estimatedPageCount, 0, accuracy: 0.0001)
    }

    func test_singleShortAction_pageCountUnderTwoPercent() {
        // "Larry sits." is one short action line. Should be tiny but nonzero
        // (action lines always count at least 1 line).
        let script = parser.parse("Larry sits.")
        XCTAssertGreaterThan(script.estimatedPageCount, 0)
        XCTAssertLessThan(script.estimatedPageCount, 0.05)
    }

    func test_longActionParagraph_wrapsToMultipleLines() {
        // 600 characters of action wraps at 60 chars/line ≈ 10 lines.
        // 10 / 55 ≈ 0.18 pages. Allow ±20% slack for ceil rounding.
        let action = String(repeating: "x", count: 600)
        let script = parser.parse(action)
        XCTAssertEqual(script.estimatedPageCount, 0.18, accuracy: 0.05)
    }

    func test_longDialogue_yieldsMoreLinesThanSameLengthAction() {
        // Same content as dialogue (35 chars/line) wraps to more lines
        // than as action (60 chars/line).
        let body = String(repeating: "x", count: 600)
        let actionScript = parser.parse(body)
        let dialogueScript = parser.parse("BARRY\n\(body)")
        XCTAssertGreaterThan(
            dialogueScript.estimatedPageCount,
            actionScript.estimatedPageCount)
    }

    func test_metadataElementsExcludedFromPageCount() {
        // A script with only sections, synopses, boneyard, notes, and a page
        // break should compute zero pages — none of these count.
        let text = """
        # ACT ONE

        = beat description

        /* cut content
        more cut content */

        [[ todo ]]

        ===
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.estimatedPageCount, 0, accuracy: 0.0001)
    }

    func test_sceneHeading_counts2Lines_perSpec() {
        // Each scene heading counts as 2 lines (heading + implicit blank).
        // 27 scene headings = 54 lines = ~0.98 pages. Just under one page.
        let blob = (1...27).map { "INT. ROOM \($0) - DAY\n\n" }.joined()
        let script = parser.parse(blob)
        XCTAssertEqual(script.estimatedPageCount, 0.98, accuracy: 0.05)
    }

    func test_referenceFixture_pageCountWithinFivePercent() throws {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(
            forResource: "sample-screenplay",
            withExtension: "fountain"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let script = parser.parse(text)
        // Fixture: two scenes, ~50 lines of action/dialogue/character cues.
        // Our heuristic (60-char action wrap, 35-char dialogue wrap, 55 lpp,
        // blank action lines skipped) computes ~0.82 pages.
        // Allow ±0.5 pages tolerance as a regression baseline.
        XCTAssertEqual(script.estimatedPageCount, 0.82, accuracy: 0.5)
    }

    // MARK: - Dual dialogue

    func test_dualPair_countsAsMaxNotSum() {
        // First block: BRICK + 3 lines of dialogue = 4 lines.
        // Second block: STEVE ^ + 1 line of dialogue = 2 lines.
        // Raw = 4 + 2 = 6. Adjustment = min(4,2) = 2. Net = 4.
        let source = """
        BRICK
        Line one of long dialogue here.
        Line two of long dialogue here.
        Line three of long dialogue here.

        STEVE ^
        Hi.
        """
        let script = parser.parse(source)
        // 55 lines per page; 4 lines / 55 ≈ 0.0727
        XCTAssertEqual(script.estimatedPageCount, 4.0 / 55.0, accuracy: 0.001)
    }

    func test_multipleDualPairs_accumulate() {
        // Two dual pairs separated by action.
        let source = """
        A
        Hello.

        B ^
        Hi.

        Some action here.

        C
        Bye.

        D ^
        Bye.
        """
        let script = parser.parse(source)
        // Pair 1: A+dialogue (2 lines) | B+dialogue (2 lines). max=2. saved=2.
        // Action: 1 line.
        // Pair 2: C+dialogue (2 lines) | D+dialogue (2 lines). max=2. saved=2.
        // Raw: 2+2+1+2+2 = 9. Adjustment: 2+2 = 4. Net: 5.
        XCTAssertEqual(script.estimatedPageCount, 5.0 / 55.0, accuracy: 0.001)
    }

    func test_soloDialogue_unchanged() {
        // Regression: no ^ markers means no adjustment.
        let source = """
        BRICK
        Hello.

        STEVE
        Hi.
        """
        let script = parser.parse(source)
        // Raw: BRICK(1) + dialogue(1) + STEVE(1) + dialogue(1) = 4. No adjustment.
        XCTAssertEqual(script.estimatedPageCount, 4.0 / 55.0, accuracy: 0.001)
    }

    func test_danglingDualSecond_noAdjustment() {
        // ^-marked cue with no preceding cue — no pair formed.
        let source = """
        STEVE ^
        Hi.
        """
        let script = parser.parse(source)
        XCTAssertEqual(script.estimatedPageCount, 2.0 / 55.0, accuracy: 0.001)
    }

    func test_chainOfThreeCues_greedyPairing() {
        // Cue 1 (no ^), Cue 2 (^), Cue 3 (^).
        // Greedy pairing: (cue1, cue2) form a pair. Cue 3 stands alone.
        let source = """
        A
        Hello.

        B ^
        Hi.

        C ^
        Bye.
        """
        let script = parser.parse(source)
        // Block A: 2 lines. Block B: 2 lines. Block C: 2 lines.
        // Pair (A,B): adjustment min(2,2)=2. Block C: solo, no adjustment.
        // Raw: 2+2+2 = 6. Adjustment: 2. Net: 4.
        XCTAssertEqual(script.estimatedPageCount, 4.0 / 55.0, accuracy: 0.001)
    }
}
