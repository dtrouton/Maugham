// MaughamTests/OpLog/RenderFilterTaskAnchorTests.swift
import XCTest
@testable import Maugham

final class RenderFilterTaskAnchorTests: XCTestCase {

    // MARK: - stripComments task-anchor extension

    func test_stripComments_removesTaskAnchor() {
        let stored = "- [ ] foo <!--t-9k2x6a-->"
        XCTAssertEqual(RenderFilter.stripComments(stored), "- [ ] foo")
    }

    func test_stripComments_removesMultipleTaskAnchorsAcrossLines() {
        let stored = """
        - [ ] foo <!--t-9k2x6a-->
        - [x] bar <!--t-p3rtab-->
        """
        let expected = """
        - [ ] foo
        - [x] bar
        """
        XCTAssertEqual(RenderFilter.stripComments(stored), expected)
    }

    func test_stripComments_removesInlineFountainAnchor() {
        let stored = "Anna walked [[todo: tighten]]<!--t-9k2x6a--> across the room."
        XCTAssertEqual(
            RenderFilter.stripComments(stored),
            "Anna walked [[todo: tighten]] across the room.")
    }

    func test_stripComments_preservesParagraphAnchors() {
        // Paragraph anchors are stripped by a different pass; the test
        // here asserts the task-anchor strip doesn't accidentally touch them.
        let stored = "<!-- ¶mnj6 -->\n\n- [ ] foo <!--t-9k2x6a-->"
        let stripped = RenderFilter.stripComments(stored)
        // Both passes run inside stripComments; the test confirms the
        // task-anchor strip eats the task comment without disturbing the
        // paragraph-anchor pass output.
        XCTAssertFalse(stripped.contains("<!--t-"))
        XCTAssertFalse(stripped.contains("<!-- ¶"))  // paragraph pass also strips
        XCTAssertTrue(stripped.contains("- [ ] foo"))
    }

    // MARK: - restoreTaskAnchors single-paragraph helper

    func test_restoreComments_reInjectsTaskAnchorOnUnchangedLine() {
        let prior = "- [ ] foo <!--t-9k2x6a-->"
        let displayed = "- [ ] foo"
        XCTAssertEqual(RenderFilter.restoreTaskAnchors(
            prior: prior, displayed: displayed), prior)
    }

    func test_restoreComments_reInjectsAnchorOnRenamedLine_positionMatch() {
        let prior = "- [ ] foo <!--t-9k2x6a-->"
        let displayed = "- [ ] Tighten foo"
        // Body changed but line position is the same — anchor follows via LCS.
        XCTAssertEqual(
            RenderFilter.restoreTaskAnchors(prior: prior, displayed: displayed),
            "- [ ] Tighten foo <!--t-9k2x6a-->")
    }

    func test_restoreComments_inlineFountainTodo() {
        let prior = "Anna [[todo: tighten]]<!--t-9k2x6a--> walked."
        let displayed = "Anna [[todo: tighten]] walked."
        XCTAssertEqual(
            RenderFilter.restoreTaskAnchors(prior: prior, displayed: displayed),
            prior)
    }

    func test_roundTrip_property_unchangedTextStripsAndRestores() {
        let cases: [String] = [
            "- [ ] foo <!--t-9k2x6a-->",
            "- [x] done it <!--t-p3rtab-->",
            "Anna [[todo: tighten]]<!--t-w8mqcd--> walked.",
            "[[todo: scene rework]]<!--t-jqdz7n--> Opening line of paragraph.",
            // Multiple anchored lines:
            """
            - [ ] foo <!--t-aaaaaa-->
            - [ ] bar <!--t-bbbbbb-->
            - [x] baz <!--t-cccccc-->
            """,
        ]
        for input in cases {
            let stripped = RenderFilter.stripComments(input)
            let restored = RenderFilter.restoreTaskAnchors(
                prior: input, displayed: stripped)
            XCTAssertEqual(restored, input, "round-trip failed for: \(input)")
        }
    }

    // MARK: - Aggressive property + edge-case tests

    func test_property_strip_then_restore_yieldsOriginal_acrossManyInputs() {
        // Round-trip the per-paragraph helper directly: strip task anchors
        // line-by-line (the multi-paragraph stripComments trims leading/
        // trailing whitespace at the doc edges, which is the document-level
        // contract — but the per-paragraph helper Task 2 ships preserves
        // indentation, which the round-trip property here pins down).
        let cases: [String] = [
            "- [ ] foo <!--t-aaaaaa-->",
            "- [x] done <!--t-bbbbbb-->",
            "  - [ ] indented <!--t-cccccc-->",
            "Anna [[todo: foo]]<!--t-dddddd--> walked.",
            "[[done: scene rework]]<!--t-eeeeee--> Opening.",
            "Some prose.",  // no anchors — should round-trip unchanged
            "",  // empty — should round-trip
            // Multi-line:
            "- [ ] a <!--t-aaaaaa-->\n- [ ] b <!--t-bbbbbb-->",
            "- [ ] a <!--t-aaaaaa-->\n- [ ] a <!--t-bbbbbb-->\n- [ ] a <!--t-cccccc-->",  // duplicates
            // Mixed:
            "Prose paragraph with [[todo: inline]]<!--t-aaaaaa--> and more.\n- [ ] follow-up <!--t-bbbbbb-->",
        ]
        for input in cases {
            // Strip per-line via the inline helper (the document-level
            // stripComments trims edges — that's its contract for the
            // paragraph-anchor pass).
            let strippedLines = input.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map { RenderFilter.stripTaskAnchorsInline(String($0)) }
            let stripped = strippedLines.joined(separator: "\n")
            let restored = RenderFilter.restoreTaskAnchors(
                prior: input, displayed: stripped)
            XCTAssertEqual(restored, input, "round-trip failed for: \(input)")
        }
    }

    func test_renameThenRestore_preservesAnchor() {
        let prior = "- [ ] foo <!--t-aaaaaa-->"
        let displayed = "- [ ] Tighten foo"  // body edited
        XCTAssertEqual(
            RenderFilter.restoreTaskAnchors(prior: prior, displayed: displayed),
            "- [ ] Tighten foo <!--t-aaaaaa-->")
    }

    func test_reorderWithinParagraph_preservesBothAnchors() {
        let prior = """
        - [ ] A <!--t-aaaaaa-->
        - [ ] B <!--t-bbbbbb-->
        """
        let displayedSwapped = """
        - [ ] B
        - [ ] A
        """
        let restored = RenderFilter.restoreTaskAnchors(
            prior: prior, displayed: displayedSwapped)
        // Body-match (pass 1a) should pair B↔B and A↔A across the position swap.
        XCTAssertEqual(restored, """
        - [ ] B <!--t-bbbbbb-->
        - [ ] A <!--t-aaaaaa-->
        """)
    }

    func test_deleteLine_remainingAnchorsPreserved() {
        let prior = """
        - [ ] A <!--t-aaaaaa-->
        - [ ] B <!--t-bbbbbb-->
        - [ ] C <!--t-cccccc-->
        """
        let displayedAfterDelete = """
        - [ ] A
        - [ ] C
        """
        let restored = RenderFilter.restoreTaskAnchors(
            prior: prior, displayed: displayedAfterDelete)
        XCTAssertEqual(restored, """
        - [ ] A <!--t-aaaaaa-->
        - [ ] C <!--t-cccccc-->
        """)
        // The B anchor is dropped; Task 5 will emit the .taskArchive op.
    }

    func test_insertNewLine_isUnanchored() {
        let prior = """
        - [ ] A <!--t-aaaaaa-->
        - [ ] B <!--t-bbbbbb-->
        """
        let displayedAfterInsert = """
        - [ ] A
        - [ ] new
        - [ ] B
        """
        let restored = RenderFilter.restoreTaskAnchors(
            prior: prior, displayed: displayedAfterInsert)
        XCTAssertEqual(restored, """
        - [ ] A <!--t-aaaaaa-->
        - [ ] new
        - [ ] B <!--t-bbbbbb-->
        """)
    }

    func test_unchangedSinglePlainLine_returnsAsIs() {
        XCTAssertEqual(
            RenderFilter.restoreTaskAnchors(prior: "hello", displayed: "hello"),
            "hello")
    }

    func test_emptyPrior_returnsDisplayed() {
        XCTAssertEqual(
            RenderFilter.restoreTaskAnchors(prior: "", displayed: "new content"),
            "new content")
    }

    // MARK: - Additional edge cases discovered during impl design

    func test_duplicateBodies_greedyFirstMatchPairsInOrder() {
        // 3 prior anchored "foo" lines, 2 displayed "foo" lines: greedy
        // pairs displayed[0]↔prior[0] (anchor A), displayed[1]↔prior[1]
        // (anchor B). Prior[2] (anchor C) is dropped.
        let prior = """
        - [ ] foo <!--t-aaaaaa-->
        - [ ] foo <!--t-bbbbbb-->
        - [ ] foo <!--t-cccccc-->
        """
        let displayed = """
        - [ ] foo
        - [ ] foo
        """
        let restored = RenderFilter.restoreTaskAnchors(
            prior: prior, displayed: displayed)
        XCTAssertEqual(restored, """
        - [ ] foo <!--t-aaaaaa-->
        - [ ] foo <!--t-bbbbbb-->
        """)
    }

    func test_unanchoredPriorLine_stripDoesNotAffect_andRestoreLeavesAlone() {
        let prior = "- [ ] no anchor here"
        let displayed = "- [ ] no anchor here"
        XCTAssertEqual(
            RenderFilter.restoreTaskAnchors(prior: prior, displayed: displayed),
            prior)
    }

    func test_mixedAnchoredAndUnanchoredLines_eachPreservedAppropriately() {
        let prior = """
        - [ ] anchored <!--t-aaaaaa-->
        - [ ] plain
        - [x] done <!--t-bbbbbb-->
        """
        // displayed identical after strip:
        let displayed = """
        - [ ] anchored
        - [ ] plain
        - [x] done
        """
        let restored = RenderFilter.restoreTaskAnchors(
            prior: prior, displayed: displayed)
        XCTAssertEqual(restored, prior)
    }

    func test_inlineAnchorWithFollowingText_reinjectedAfterClosingBrackets() {
        // The anchor sits right after `]]` with no space; the rest of the
        // sentence follows. Restore must place it back in that exact spot.
        let prior = "Opening [[todo: tighten]]<!--t-aaaaaa--> the prose here."
        let displayed = "Opening [[todo: tighten]] the prose here."
        XCTAssertEqual(
            RenderFilter.restoreTaskAnchors(prior: prior, displayed: displayed),
            prior)
    }

    func test_inlineAnchorAtLineEnd_reinjectedAtEnd() {
        let prior = "Trailing inline [[todo: x]]<!--t-aaaaaa-->"
        let displayed = "Trailing inline [[todo: x]]"
        XCTAssertEqual(
            RenderFilter.restoreTaskAnchors(prior: prior, displayed: displayed),
            prior)
    }
}
