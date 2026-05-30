import XCTest
import MaughamCore

/// Phone-side coverage of the shared `MarkdownDisplayFilter` (MaughamCore) that
/// the Read tab uses to strip manuscript anchors before rendering. The Mac side
/// exercises the same code through `RenderFilterTests` /
/// `RenderFilterTaskAnchorTests`; this proves it from the iOS target and pins
/// the task-anchor case the phone's old stripper missed.
final class MarkdownDisplayFilterTests: XCTestCase {
    /// Build a fixture using the REAL emitted paragraph-anchor format so the
    /// test can't drift from production.
    private func anchor(_ id: String) -> String { ParagraphID.formatComment(id) }

    func test_stripsRealFormatAnchors_keepsProseAndParagraphBreaks() {
        let doc = """
        \(anchor("ab2c"))

        First paragraph of prose.

        \(anchor("9xyz"))

        Second paragraph of prose.
        """

        let out = MarkdownDisplayFilter.stripAnchors(doc)

        XCTAssertFalse(out.contains("<!--"), "all paragraph anchors should be gone")
        XCTAssertFalse(out.contains("¶"), "no sentinel should remain")
        XCTAssertTrue(out.contains("First paragraph of prose."))
        XCTAssertTrue(out.contains("Second paragraph of prose."))
        // The paragraph break between the two prose blocks survives; the blank
        // that followed each anchor is collapsed away.
        XCTAssertTrue(out.contains("prose.\n\nSecond"),
                      "paragraph break must survive; got:\n\(out)")
    }

    func test_stripsInlineTaskAnchors() {
        // The gap the phone's old stripper had: inline `<!--t-XXXXXX-->` task
        // anchors must be removed too (with the leading space), or the reader
        // shows raw anchor noise. 6 chars from the restricted alphabet.
        let doc = "She paused at the door. <!--t-k3mn7p-->\n\nThen left."
        let out = MarkdownDisplayFilter.stripAnchors(doc)

        XCTAssertFalse(out.contains("<!--t-"), "task anchor must be stripped")
        XCTAssertFalse(out.contains("door. \n"), "the anchor's leading space is consumed")
        XCTAssertTrue(out.contains("She paused at the door."))
        XCTAssertTrue(out.contains("Then left."))
        XCTAssertTrue(out.contains("\n\n"), "paragraph break preserved")
    }

    func test_noAnchorProse_contentPreserved() {
        // A no-anchor doc is returned with its content intact (the display strip
        // trims only outer whitespace).
        let doc = "Just some prose.\n\nWith two paragraphs."
        XCTAssertEqual(MarkdownDisplayFilter.stripAnchors(doc), doc)
    }

    func test_unrelatedHTMLComment_isLeftIntact() {
        // `<!-- TODO -->` lacks the ¶ sentinel / task shape, so it survives —
        // proving the strip is anchor-specific, not "any comment".
        let doc = "<!-- TODO -->\n\nProse here."
        let out = MarkdownDisplayFilter.stripAnchors(doc)
        XCTAssertTrue(out.contains("<!-- TODO -->"))
        XCTAssertTrue(out.contains("Prose here."))
    }

    func test_commentWithWrongIdLength_isLeftIntact() {
        // 5-char id is outside ParagraphID.parseComment's gate, so not an anchor.
        let doc = "<!-- ¶abcde -->\n\nProse."
        let out = MarkdownDisplayFilter.stripAnchors(doc)
        XCTAssertTrue(out.contains("<!-- ¶abcde -->"),
                      "wrong-length id is not a real anchor; got:\n\(out)")
    }
}
