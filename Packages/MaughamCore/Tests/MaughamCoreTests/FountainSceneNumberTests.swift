import XCTest
@testable import MaughamCore

/// Task 11: a scene heading may end with a `#<id>#` bracket (id = 1+ chars of
/// `[0-9A-Za-z.-]`). The tokenizer strips it (and any preceding spaces) from
/// `content`, lifts the id into `sceneNumber`, and reports the full marker
/// range (both `#` inclusive, document-relative) as a `.sceneNumber` inline
/// span so both surfaces can fade it in place.
final class FountainSceneNumberTests: XCTestCase {

    private func sceneNumberSpan(_ line: FountainLine) -> FountainInlineSpan? {
        line.inlineSpans.first {
            if case .sceneNumber = $0.kind { return true }; return false
        }
    }

    func test_sceneNumber_extractedAndStripped() {
        let s = FountainTokenizer().parse("INT. HOUSE - DAY #4A#\n")
        XCTAssertEqual(s.lines[0].element, .sceneHeading)
        XCTAssertEqual(s.lines[0].sceneNumber, "4A")
        XCTAssertEqual(s.lines[0].content, "INT. HOUSE - DAY")
        XCTAssertNotNil(sceneNumberSpan(s.lines[0]))
    }

    func test_sceneNumber_spanCoversBothHashes() {
        let text = "INT. HOUSE - DAY #4A#\n"
        let s = FountainTokenizer().parse(text)
        let span = sceneNumberSpan(s.lines[0])
        XCTAssertNotNil(span)
        // The marker is "#4A#" — 4 UTF-16 units at the document offset of the
        // first '#'. In this line the first '#' is at index 17.
        let ns = text as NSString
        let markerRange = ns.range(of: "#4A#")
        XCTAssertEqual(span?.range, markerRange)
    }

    func test_forcedSceneHeading_withNumber() {
        let s = FountainTokenizer().parse(".ROOFTOP #12#\n")
        XCTAssertEqual(s.lines[0].element, .sceneHeading)
        XCTAssertEqual(s.lines[0].sceneNumber, "12")
        XCTAssertEqual(s.lines[0].content, "ROOFTOP")
        XCTAssertNotNil(sceneNumberSpan(s.lines[0]))
    }

    func test_sceneNumber_alnumDotDash() {
        let s = FountainTokenizer().parse("EXT. STREET - NIGHT #1.A-2#\n")
        XCTAssertEqual(s.lines[0].sceneNumber, "1.A-2")
        XCTAssertEqual(s.lines[0].content, "EXT. STREET - NIGHT")
    }

    func test_sceneNumber_trailingSpacesAfterMarkerTolerated() {
        let s = FountainTokenizer().parse("INT. HOUSE - DAY #7#   \n")
        XCTAssertEqual(s.lines[0].sceneNumber, "7")
        XCTAssertEqual(s.lines[0].content, "INT. HOUSE - DAY")
    }

    func test_sceneHeadingWithoutNumber_unchanged() {
        let s = FountainTokenizer().parse("INT. HOUSE - DAY\n")
        XCTAssertEqual(s.lines[0].element, .sceneHeading)
        XCTAssertNil(s.lines[0].sceneNumber)
        XCTAssertNil(sceneNumberSpan(s.lines[0]))
        XCTAssertEqual(s.lines[0].content, "INT. HOUSE - DAY")
    }

    func test_hashLine_stillSection_notSceneNumber() {
        let s = FountainTokenizer().parse("# Act One\n")
        XCTAssertEqual(s.lines[0].element, .section(level: 1))
        XCTAssertNil(s.lines[0].sceneNumber)
    }

    func test_nonHeading_hashSuffix_untouched() {
        let s = FountainTokenizer().parse("He wrote #1# on the wall.\n")
        XCTAssertEqual(s.lines[0].element, .action)
        XCTAssertNil(s.lines[0].sceneNumber)
        XCTAssertNil(sceneNumberSpan(s.lines[0]))
    }

    func test_emptyBracket_notASceneNumber() {
        // "##" has no id character between the hashes — untouched.
        let s = FountainTokenizer().parse("INT. HOUSE - DAY ##\n")
        XCTAssertNil(s.lines[0].sceneNumber)
        XCTAssertEqual(s.lines[0].content, "INT. HOUSE - DAY ##")
    }

    func test_spaceInBracket_notASceneNumber() {
        // A space is not a valid id char, so "#1 #" does not qualify.
        let s = FountainTokenizer().parse("INT. HOUSE - DAY #1 #\n")
        XCTAssertNil(s.lines[0].sceneNumber)
    }

    func test_markerNotAtLineEnd_untouched() {
        // The bracket is not the final token → not a scene number.
        let s = FountainTokenizer().parse("INT. HOUSE #4A# - DAY\n")
        XCTAssertNil(s.lines[0].sceneNumber)
        XCTAssertEqual(s.lines[0].content, "INT. HOUSE #4A# - DAY")
    }

    func test_sourceCase_computedOnStrippedContent() {
        // Stripping the number must not change the all-caps classification.
        let s = FountainTokenizer().parse("INT. HOUSE - DAY #4A#\n")
        XCTAssertEqual(s.lines[0].sourceCase, .upper)
    }

    func test_nonASCIISceneHeading_withNumber() {
        let text = "INT. CAFÉ - DAY #4A#\n"
        let s = FountainTokenizer().parse(text)
        XCTAssertEqual(s.lines[0].element, .sceneHeading)
        XCTAssertEqual(s.lines[0].sceneNumber, "4A")
        XCTAssertEqual(s.lines[0].content, "INT. CAFÉ - DAY")
        let span = sceneNumberSpan(s.lines[0])
        XCTAssertEqual(span?.range, (text as NSString).range(of: "#4A#"))
    }
}
