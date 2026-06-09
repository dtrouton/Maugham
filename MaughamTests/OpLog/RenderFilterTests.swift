// MaughamTests/OpLog/RenderFilterTests.swift
import XCTest
import MaughamCore
@testable import Maugham

final class RenderFilterTests: XCTestCase {
    func test_stripComments_removesIdMarkers_keepsParagraphs() {
        let stored = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n"
        let display = RenderFilter.stripComments(stored)
        XCTAssertEqual(display, "First.\n\nSecond.")
    }

    func test_stripComments_keepsArbitraryHtmlCommentsThatAreNotIds() {
        let stored = "<!-- A real author note -->\n\nFirst.\n"
        XCTAssertEqual(RenderFilter.stripComments(stored),
            "<!-- A real author note -->\n\nFirst.")
    }

    func test_restoreComments_reattachesIdsByContentMatch() {
        let stored = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n"
        let displayEdited = "First, edited.\n\nSecond."
        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "a3f9")
        XCTAssertEqual(parsed[0].text, "First, edited.")
        XCTAssertEqual(parsed[1].id, "b21c")
        XCTAssertEqual(parsed[1].text, "Second.")
    }

    func test_restoreComments_paragraphInserted_mintsNewIdForIt() {
        let stored = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n"
        let displayEdited = "First.\n\nMiddle inserted.\n\nSecond."
        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].id, "a3f9")
        XCTAssertNotNil(parsed[1].id)
        XCTAssertNotEqual(parsed[1].id, "a3f9")
        XCTAssertNotEqual(parsed[1].id, "b21c")
        XCTAssertEqual(parsed[2].id, "b21c")
    }

    func test_restoreComments_paragraphRemoved_dropsItsId() {
        let stored = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n"
        let displayEdited = "First."
        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "a3f9")
    }

    // MARK: - Tier-2 (word-shingle) vs tier-3 (bigram) disagreement

    /// The missing focused tier-2-vs-tier-3 disagreement test (AREA.md /
    /// audit O1). Two stored candidates where the two reattach tiers would
    /// pair the same edited paragraph DIFFERENTLY:
    ///
    ///   needle  = "the cat sat on the mat"
    ///   candA `a3f9` = "the cat sat on the rug"  → word-shingle 0.667 (≥0.6),
    ///                                              bigram 0.867
    ///   candB `b21c` = "the mat"                 → word-shingle 0.0 (tier-2
    ///                                              MISS), bigram 1.0 (highest!)
    ///
    /// If the *bigram* tier ran on its own it would steal candB's id (`b21c`,
    /// overlap 1.0) — a near-duplicate-substring false positive = the silent
    /// corruption AREA.md warns about. The SAFE resolution, and the contract
    /// this test pins: **tier 2 (semantic word-shingle) runs first and wins**
    /// when it clears 0.6, so the edited line reattaches to candA (`a3f9`) and
    /// candB keeps its own id. The bigram tier is a *fallback*, reached only
    /// when word-shingles miss — it never overrides a tier-2 match.
    func test_restoreComments_tier2WordShingleWins_overTier3BigramFalsePositive() {
        let stored =
            "<!-- ¶a3f9 -->\n\nthe cat sat on the rug\n\n"
            + "<!-- ¶b21c -->\n\nthe mat\n"
        // The writer edits candA "…rug" → "…mat" and leaves candB "the mat".
        let displayEdited = "the cat sat on the mat\n\nthe mat"

        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 2)

        // The edited line reattaches to candA via the word-shingle tier — NOT
        // to candB via the higher bigram overlap (which would be an id-steal).
        XCTAssertEqual(
            parsed[0].id, "a3f9",
            "tier-2 word-shingle (0.667) must win over the tier-3 bigram "
                + "false-positive (candB bigram 1.0) — the bigram tier is a "
                + "fallback, never an override")
        XCTAssertEqual(parsed[0].text, "the cat sat on the mat")
        // candB is unchanged and keeps its own id — it was never stolen.
        XCTAssertEqual(parsed[1].id, "b21c")
        XCTAssertEqual(parsed[1].text, "the mat")
    }
}
