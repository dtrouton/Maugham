import XCTest
import MaughamCore
@testable import Maugham

final class SlugifierTests: XCTestCase {

    func test_simpleTitle_lowercased_and_dashed() {
        XCTAssertEqual(Slugifier.slug(from: "Chapter 1"), "chapter-1")
    }

    func test_punctuation_isStripped() {
        XCTAssertEqual(Slugifier.slug(from: "The Razor's Edge!"), "the-razors-edge")
    }

    func test_consecutiveSpaces_collapseToSingleDash() {
        XCTAssertEqual(Slugifier.slug(from: "Chapter   One"), "chapter-one")
    }

    func test_leadingTrailingSpaces_areTrimmed() {
        XCTAssertEqual(Slugifier.slug(from: "  Hello World  "), "hello-world")
    }

    func test_emptyString_fallsBackToUntitled() {
        XCTAssertEqual(Slugifier.slug(from: ""), "untitled")
    }

    func test_onlyPunctuation_fallsBackToUntitled() {
        XCTAssertEqual(Slugifier.slug(from: "!!!???"), "untitled")
    }

    func test_unicode_isStrippedToAscii() {
        // "Über das Leben" — the umlaut decomposes via diacriticInsensitive folding
        XCTAssertEqual(Slugifier.slug(from: "Über das Leben"), "uber-das-leben")
    }

    func test_longTitle_truncatesTo40Chars() {
        let long = String(repeating: "a", count: 100)
        let slug = Slugifier.slug(from: long)
        XCTAssertEqual(slug.count, 40)
        XCTAssertEqual(slug, String(repeating: "a", count: 40))
    }

    func test_truncationDoesNotEndOnDash() {
        // 50 chars: 40 a's + dash + ... should truncate to 40 a's, not 39 a's + dash
        let title = String(repeating: "a", count: 40) + " " + String(repeating: "b", count: 10)
        let slug = Slugifier.slug(from: title)
        XCTAssertFalse(slug.hasSuffix("-"))
    }
}
