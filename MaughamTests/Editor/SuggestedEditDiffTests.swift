// MaughamTests/Editor/SuggestedEditDiffTests.swift
import XCTest
@testable import Maugham

/// Task 4a: the pure suggested-edit diff. `original` is the selected text;
/// `edited` is the reviewer's replacement. Returns nil when there's nothing
/// to suggest (unchanged after trimming, or empty).
final class SuggestedEditDiffTests: XCTestCase {

    func test_unchanged_returnsNil() {
        XCTAssertNil(SuggestedEditDiff.make(
            original: "the quick brown fox",
            edited: "the quick brown fox"))
    }

    func test_whitespaceOnlyChange_returnsNil() {
        // Differs only by surrounding whitespace → trimmed compare equal → nil.
        XCTAssertNil(SuggestedEditDiff.make(
            original: "the quick brown fox",
            edited: "  the quick brown fox\n"))
    }

    func test_emptyEdited_returnsNil() {
        XCTAssertNil(SuggestedEditDiff.make(
            original: "the quick brown fox",
            edited: ""))
    }

    func test_realChange_returnsSuggestion() {
        let result = SuggestedEditDiff.make(
            original: "the quick brown fox",
            edited: "the slow brown fox")
        XCTAssertEqual(result?.body, "")
        XCTAssertEqual(result?.suggestedText, "the slow brown fox")
    }

    func test_realChange_preservesEditedVerbatim() {
        // The suggestedText is the edited string verbatim (untrimmed), only the
        // *comparison* is trimmed.
        let result = SuggestedEditDiff.make(
            original: "alpha",
            edited: "beta gamma")
        XCTAssertEqual(result?.suggestedText, "beta gamma")
    }
}
