import XCTest
@testable import Maugham

final class ScrapTextTests: XCTestCase {

    func test_renderThenParse_roundTrips() {
        let scraps: [CanvasNodeID: String] = [
            CanvasNodeID("s1"): "The falls at night.",
            CanvasNodeID("s2"): "October's doctor was kind about it.",
        ]
        let parsed = ScrapText.parse(ScrapText.render(scraps))
        XCTAssertEqual(parsed, scraps)
    }

    func test_render_ordersScrapsById() {
        // Ids chosen so their sorted order is obviously not insertion order.
        let scraps: [CanvasNodeID: String] = [
            CanvasNodeID("f"): "sixth",
            CanvasNodeID("c"): "third",
            CanvasNodeID("a"): "first",
            CanvasNodeID("e"): "fifth",
            CanvasNodeID("b"): "second",
            CanvasNodeID("d"): "fourth",
        ]
        let rendered = ScrapText.render(scraps)

        // Extract ids in the order their `##` headings appear in the output.
        let renderedOrder = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("## ") }
            .map { (line: Substring) -> String in
                String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }

        let expectedOrder = scraps.keys.sorted { $0.raw < $1.raw }.map(\.raw)

        XCTAssertEqual(renderedOrder, expectedOrder,
                       "scraps must render in id order, or every save churns the "
                       + "diff with an arbitrary dictionary-iteration reordering")
    }

    func test_parse_keepsMultipleParagraphsAndBlankLines() {
        let md = """
        <!-- maugham:canvas-scraps -->

        ## s1

        First paragraph.

        Second paragraph.
        """
        XCTAssertEqual(ScrapText.parse(md)[CanvasNodeID("s1")],
                       "First paragraph.\n\nSecond paragraph.")
    }

    func test_parse_toleratesAnUnknownPreamble() {
        let md = """
        Some writer wrote a note at the top of the file.

        ## s1

        Body.
        """
        XCTAssertEqual(ScrapText.parse(md)[CanvasNodeID("s1")], "Body.")
    }

    func test_parse_emptyFileYieldsNoScraps() {
        XCTAssertTrue(ScrapText.parse("").isEmpty)
    }

    func test_roundTrip_preservesTextThatLooksLikeAHeading() {
        let scraps = [CanvasNodeID("s1"): "## not a scrap heading\n\nbody"]
        // A scrap whose own text starts with ## must survive; the renderer
        // indents it so the parser cannot mistake it for a new scrap.
        XCTAssertEqual(ScrapText.parse(ScrapText.render(scraps)), scraps)
    }

    func test_roundTrip_preservesTextThatAlreadyBeginsWithSpaceThenHashes() {
        // The escape adds ONE space to any line that reads as a heading once its
        // leading spaces are stripped, and the unescape removes exactly one from
        // the same class of line. A naive `hasPrefix(" ## ")` unescape eats a
        // space the writer typed.
        let scraps = [CanvasNodeID("s1"): " ## indented on purpose\n\nbody"]
        XCTAssertEqual(ScrapText.parse(ScrapText.render(scraps)), scraps)
    }

    func test_roundTrip_preservesAnEmptyScrap() {
        // A freshly created scrap has no text yet and must still round-trip,
        // or double-click-then-quit loses the node's very existence.
        let scraps = [CanvasNodeID("s1"): ""]
        XCTAssertEqual(ScrapText.parse(ScrapText.render(scraps)), scraps)
    }

    func test_roundTrip_preservesDeliberateLeadingAndTrailingBlankLines() {
        // The renderer adds exactly ONE blank line on each side of a body; the
        // parser must therefore strip AT MOST one from each end — the old
        // `while` loops ate every blank line the writer put there on purpose.
        let scraps = [CanvasNodeID("s1"): "\n\nBody.\n\n"]
        XCTAssertEqual(ScrapText.parse(ScrapText.render(scraps)), scraps)
    }
}
