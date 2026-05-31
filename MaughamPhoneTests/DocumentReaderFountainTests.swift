import XCTest
@testable import MaughamPhone
import MaughamCore

/// Regression tests for the Fountain reader's anchor-strip seam.
///
/// On the first TestFlight build, screenplays rendered with the manuscript's
/// `<!-- ¶id -->` anchors leaking through: each anchor line drew as `.action`
/// body text ("paragraph markers"), and a leading anchor made the title page
/// vanish (the tokenizer's first-line `Key:` probe saw the anchor). Root cause:
/// the Fountain path parsed RAW text while the markdown path stripped anchors
/// via `MarkdownDisplayFilter`. `DocumentReaderView.parseFountain` now strips
/// first. These tests pin both halves.
final class DocumentReaderFountainTests: XCTestCase {

    /// A manuscript-shaped screenplay EXACTLY as the Mac `Materializer` emits it:
    /// each paragraph block is preceded by its own-line `<!-- ¶id -->` anchor
    /// (anchor immediately above content, a blank line between blocks). The
    /// title-page key lines have no blank between them, so they're a single block
    /// with ONE leading anchor — which means the file's first non-empty line is
    /// the anchor, not `Title:`. That's what broke title-page detection on device.
    private let manuscript = """
    <!-- ¶ab12 -->
    Title: The Long Goodbye
    Author: P. Marlowe

    <!-- ¶cd34 -->
    INT. OFFICE - NIGHT

    <!-- ¶ef56 -->
    Marlowe pours a drink.
    """

    func test_parseFountain_detectsTitlePage_pastLeadingAnchorRegion() {
        let script = DocumentReaderView.parseFountain(manuscript)
        let keys = (script.titlePage ?? []).map(\.key)
        XCTAssertTrue(keys.contains("Title"), "title page must be parsed; got keys \(keys)")
        XCTAssertTrue(keys.contains("Author"))
    }

    func test_parseFountain_stripsParagraphAnchorsFromBody() {
        let script = DocumentReaderView.parseFountain(manuscript)
        for line in script.lines {
            XCTAssertFalse(line.content.contains("¶"),
                           "anchor leaked into a body line: \(line.content)")
            XCTAssertFalse(line.content.contains("<!--"),
                           "HTML comment leaked into a body line: \(line.content)")
        }
    }

    func test_parseFountain_classifiesElementsAfterStrip() {
        // With anchors gone and the blank lines between elements preserved, the
        // scene heading must classify correctly (it relies on a blank line above).
        let script = DocumentReaderView.parseFountain(manuscript)
        let hasSceneHeading = script.lines.contains {
            $0.element == .sceneHeading && $0.content == "INT. OFFICE - NIGHT"
        }
        XCTAssertTrue(hasSceneHeading, "scene heading must survive the strip + parse")
    }
}
