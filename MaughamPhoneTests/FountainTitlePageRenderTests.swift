import XCTest
@testable import MaughamPhone
import MaughamCore

/// Regression for the screenplay title-page DOUBLE RENDER.
///
/// The `FountainTokenizer` emits the title-page region BOTH as the structured
/// `script.titlePage` fields AND as individual `FountainLine`s with
/// `element == .titlePage`. `FountainSemanticRenderer` draws `script.titlePage`
/// in its dedicated `titlePageBlock`, so the raw `.titlePage` LINES must be hidden
/// from the body line list — otherwise the title page renders twice (once centered,
/// once as left-aligned body). This stayed latent until the anchor-strip fix made
/// title-page detection actually succeed (phone-v0.0.3 on device).
///
/// `FountainStyler` is the single place that decides per-element visibility, and
/// the renderer's `visibleLines` is exactly `lines.filter { !style(for:$0).hidden }`,
/// so asserting `.titlePage` is hidden + that the title text isn't in the filtered
/// body pins the fix without instantiating the SwiftUI view.
final class FountainTitlePageRenderTests: XCTestCase {

    private func line(_ element: ScreenplayElement, _ content: String) -> FountainLine {
        FountainLine(range: NSRange(location: 0, length: 1),
                     element: element, content: content,
                     isForced: false, sourceCase: .neutral)
    }

    func test_titlePageLine_isHidden() {
        let style = FountainStyler.style(for: line(.titlePage, "Title: Hurt"))
        XCTAssertTrue(style.hidden,
                      "title-page lines must be hidden — titlePageBlock renders that content")
    }

    /// End-to-end: parse a manuscript-shaped screenplay (anchored title page, as
    /// Materializer emits it) and apply the renderer's exact visibleLines filter.
    /// The title-page text must live ONLY in script.titlePage, never in the visible
    /// body — i.e. it renders exactly once.
    func test_parsedScreenplay_titleTextNotInVisibleBody() {
        let manuscript = """
        <!-- ¶ab12 -->
        Title: Hurt // Johnny Cash
        Credit: Written by
        Author: Denver Trouton

        <!-- ¶cd34 -->
        EXT. ABANDONED CITY IN RUINS - DAY

        <!-- ¶ef56 -->
        IVAN (V/O)
        """
        let script = DocumentReaderView.parseFountain(manuscript)

        // Title page parsed into the structured block.
        let keys = (script.titlePage ?? []).map(\.key)
        XCTAssertTrue(keys.contains("Title"), "title page must parse; keys: \(keys)")

        // The renderer's exact body filter.
        let visibleBody = script.lines.filter { !FountainStyler.style(for: $0).hidden }
        for l in visibleBody {
            XCTAssertNotEqual(l.element, .titlePage,
                              "a .titlePage line leaked into the visible body: \(l.content)")
            XCTAssertFalse(l.content.contains("Johnny Cash"),
                           "title-page text rendered in the body (double render): \(l.content)")
            XCTAssertFalse(l.content.contains("Denver Trouton"),
                           "title-page text rendered in the body (double render): \(l.content)")
        }

        // The scene heading still survives as visible body.
        XCTAssertTrue(visibleBody.contains { $0.element == .sceneHeading },
                      "scene heading must remain visible")
    }
}
