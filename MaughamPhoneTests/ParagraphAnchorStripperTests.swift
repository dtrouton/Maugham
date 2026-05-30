import XCTest
@testable import MaughamPhone
import MaughamCore

final class ParagraphAnchorStripperTests: XCTestCase {
    /// Build a fixture using the REAL emitted anchor format
    /// (`ParagraphID.formatComment`) so the test can't drift from production.
    private func anchor(_ id: String) -> String { ParagraphID.formatComment(id) }

    func test_stripsRealFormatAnchors_keepsProseAndParagraphBreaks() {
        let doc = """
        \(anchor("ab2c"))

        First paragraph of prose.

        \(anchor("9xyz"))

        Second paragraph of prose.
        """

        let out = ParagraphAnchorStripper.strip(doc)

        XCTAssertFalse(out.contains("<!--"), "all anchors should be gone")
        XCTAssertFalse(out.contains("¶"), "no sentinel should remain")
        XCTAssertTrue(out.contains("First paragraph of prose."))
        XCTAssertTrue(out.contains("Second paragraph of prose."))
        // Paragraph break between the two prose blocks is preserved (a blank
        // line separates them).
        XCTAssertTrue(out.contains("prose.\n\nSecond"),
                      "paragraph break must survive; got:\n\(out)")
    }

    func test_noAnchorInput_isUnchanged() {
        let doc = "Just some prose.\n\nWith two paragraphs.\n"
        XCTAssertEqual(ParagraphAnchorStripper.strip(doc), doc)
    }

    func test_unrelatedHTMLComment_isLeftIntact() {
        // `<!-- TODO -->` lacks the `¶` sentinel and isn't the 4-char alphabet
        // shape, so it must NOT be stripped — proves the regex is anchor-
        // specific, not "any comment".
        let doc = "<!-- TODO -->\n\nProse here."
        let out = ParagraphAnchorStripper.strip(doc)
        XCTAssertTrue(out.contains("<!-- TODO -->"))
        XCTAssertTrue(out.contains("Prose here."))
    }

    func test_commentWithWrongIdLength_isLeftIntact() {
        // 5 chars, not 4 — outside the parseComment gate, so not an anchor.
        let doc = "<!-- ¶abcde -->\n\nProse."
        let out = ParagraphAnchorStripper.strip(doc)
        XCTAssertTrue(out.contains("<!-- ¶abcde -->"),
                      "wrong-length id is not a real anchor; got:\n\(out)")
    }

    func test_inlineAnchor_trailingWhitespaceTrimmed_noBlankLineCollapse() {
        // An anchor mid-line should be removed and the trailing space cleaned,
        // but the surrounding blank-line structure preserved.
        let doc = "Para one. \(anchor("k3mn"))\n\nPara two."
        let out = ParagraphAnchorStripper.strip(doc)
        XCTAssertFalse(out.contains("<!--"))
        XCTAssertTrue(out.contains("Para one."))
        XCTAssertTrue(out.contains("Para two."))
        // No dangling trailing whitespace after "Para one."
        XCTAssertFalse(out.contains("Para one. \n"),
                       "trailing whitespace should be trimmed; got:\n\(out)")
        // Blank line between paragraphs preserved.
        XCTAssertTrue(out.contains("\n\n"), "paragraph break preserved")
    }
}
