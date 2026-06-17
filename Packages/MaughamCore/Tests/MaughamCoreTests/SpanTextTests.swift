import XCTest
@testable import MaughamCore

final class SpanTextTests: XCTestCase {
    func test_normalize_canonicalizesSmartQuotesAndDashes() {
        XCTAssertEqual(SpanText.normalize("don\u{2019}t \u{201C}go\u{201D}"), "don't \"go\"")
        XCTAssertEqual(SpanText.normalize("a \u{2014} b"), "a - b")
        XCTAssertEqual(SpanText.normalize("a \u{2013} b"), "a - b")
    }
    func test_normalize_collapsesWhitespaceRuns() {
        XCTAssertEqual(SpanText.normalize("for   the\texercise"), "for the exercise")
    }
    func test_normalize_isIdempotent() {
        let once = SpanText.normalize("the  \u{201C}cat\u{201D}")
        XCTAssertEqual(SpanText.normalize(once), once)
    }

    /// Load-bearing invariant: the exact tier of SpanAnchorResolver searches the
    /// `normalized` output of `normalizeWithMap` but disambiguates/compares against
    /// `normalize`. If the two ever produced different normalized text, the index
    /// map would point into a string the matcher never saw. Pin them identical.
    func test_normalizeWithMap_normalizedOutput_equalsNormalize() {
        let fixtures: [String] = [
            "plain ascii sentence here",                       // plain ASCII
            "don\u{2019}t say \u{2018}hi\u{2019} \u{201C}now\u{201D}", // smart quotes
            "a \u{2014} b \u{2013} c",                          // em + en dash
            "well\u{2026} then",                               // ellipsis
            "   leading and trailing   ",                      // leading/trailing whitespace
            "for   the\t\texercise\nhere",                     // interior whitespace runs (spaces/tabs/newlines)
            "",                                                // empty string
            "She paused\u{2026} \u{201C}well\u{201D} \u{2014} then she\trested.", // mixed real sentence
        ]
        for s in fixtures {
            let mapped = String(SpanText.normalizeWithMap(s).normalized)
            XCTAssertEqual(mapped, SpanText.normalize(s),
                           "normalizeWithMap diverged from normalize for fixture: \(s.debugDescription)")
        }
    }
}
