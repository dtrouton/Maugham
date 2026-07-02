import XCTest
import MaughamCore
@testable import Maugham

/// Regression net for the 2026-07-02 smoke finding: the stats-window
/// navigate-to-document path (newly reachable after ADR 0021 re-scoped
/// `.maughamNavigateToDocument` to `.project`) forced `binderSegment =
/// .manuscript` on a screenplay project — a segment the screenplay binder
/// picker doesn't even offer — swapping the Scenes slugline navigator for the
/// one-row novel BinderView. The document's "home" segment is project-type
/// dependent and must come from ONE helper, not per-receiver re-derivation.
final class BinderSegmentDocumentHomeTests: XCTestCase {

    func test_screenplay_documentHome_isScenes() {
        XCTAssertEqual(BinderSegment.documentHome(for: .screenplay), .scenes,
            "a screenplay's binder has no Manuscript segment — navigating to its "
            + "document must land on the Scenes slugline navigator")
    }

    func test_nonScreenplayTypes_documentHome_isManuscript() {
        for type in ProjectType.allCases where type != .screenplay {
            XCTAssertEqual(BinderSegment.documentHome(for: type), .manuscript,
                "\(type) projects navigate to documents in the Manuscript segment")
        }
    }
}
