// MaughamTests/OpLog/ShingleMatcherTests.swift
import XCTest
@testable import Maugham

final class ShingleMatcherTests: XCTestCase {
    func test_overlapCoefficient_identicalText_isOne() {
        let s = "The morning began with toast and a sense of foreboding."
        XCTAssertEqual(ShingleMatcher.overlapCoefficient(s, s, k: 4), 1.0, accuracy: 0.001)
    }

    func test_overlapCoefficient_disjointText_isZero() {
        let a = "The cat sat on the mat in the morning light."
        let b = "Programming languages have evolved enormously over the decades."
        XCTAssertEqual(ShingleMatcher.overlapCoefficient(a, b, k: 4), 0.0, accuracy: 0.001)
    }

    func test_overlapCoefficient_minorEdit_returnsHighSimilarity() {
        let a = "The morning began with toast and a sense of foreboding she could not place."
        let b = "The morning began with burnt toast and a sense of foreboding she could not place."
        XCTAssertGreaterThan(ShingleMatcher.overlapCoefficient(a, b, k: 4), 0.6)
    }

    func test_bestMatch_returnsHighestAboveThreshold() {
        let needle = "The morning began with toast."
        let haystack = [
            "id-1": "Completely unrelated text about programming.",
            "id-2": "The morning began with burnt toast.",
            "id-3": "Another piece of unrelated content here."
        ]
        let match = ShingleMatcher.bestMatch(
            needle: needle, candidates: haystack, k: 4, threshold: 0.5)
        XCTAssertEqual(match?.id, "id-2")
    }

    func test_bestMatch_returnsNilBelowThreshold() {
        let needle = "Completely original content."
        let haystack = ["id-1": "Different text entirely with no overlap nearby."]
        let match = ShingleMatcher.bestMatch(
            needle: needle, candidates: haystack, k: 4, threshold: 0.6)
        XCTAssertNil(match)
    }

    func test_bigramOverlap_identicalShortText_isOne() {
        XCTAssertEqual(ShingleMatcher.bigramOverlap("hello", "hello"), 1.0, accuracy: 0.001)
    }

    func test_bigramOverlap_minorEditOnShortText_isHigh() {
        let score = ShingleMatcher.bigramOverlap("First.", "First, edited.")
        XCTAssertGreaterThan(score, 0.6)
    }

    func test_bigramOverlap_disjointText_isLow() {
        let score = ShingleMatcher.bigramOverlap("xyz", "abc")
        XCTAssertLessThan(score, 0.3)
    }
}
