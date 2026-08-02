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

    // MARK: - The status footer's own question (slice 2, task 9)

    /// **Every segment answers, and the switch below is what makes that true.**
    ///
    /// `shouldShowStatusFooter` spelled this as `== .manuscript || == .scenes`,
    /// which answered "no" for `.canvas` and again for `.tree` by inheriting
    /// rather than by deciding — right both times, and by luck both times. The
    /// production predicate is now an exhaustive `switch` with no `default:`,
    /// and so is this test: a new `BinderSegment` case breaks the compile HERE
    /// as well as there, so the expectation cannot be quietly inherited on the
    /// test side either.
    ///
    /// The interesting row is `.find`, and it is asserted rather than skipped.
    /// It said `false` until 2026-08-02 — an oversight from before find had a
    /// centre column of its own, ruled as such by Denver when slice 2's task 9
    /// surfaced it. Find centres the document (`existingEditorSwitch` joins it
    /// to `.manuscript, .scenes`), so the goal capsule, the live session words
    /// and the ¶id/element readout all remain true while a search panel is open
    /// on the left, and the footer now follows the document rather than the
    /// shape of the left column.
    func test_everySegmentDeclaresWhetherTheStatusFooterFollowsIt() {
        for segment in BinderSegment.allCases {
            let expected: Bool
            switch segment {
            case .manuscript, .scenes:
                expected = true
            case .tree, .canvas:
                // Plan's two centre-is-the-canvas segments. Word goals and a
                // cursor's ¶id are manuscript facts; the canvas has neither.
                expected = false
            case .research, .palette, .trash:
                expected = false
            case .find:
                // The document is still in the centre while the search panel is
                // on the left, so every fact the footer reports is still true.
                expected = true
            }
            XCTAssertEqual(segment.showsManuscriptStatusFooter, expected,
                           "\(segment) disagrees with the shipped rule")
        }
    }

    /// The control. A predicate that answered a constant would satisfy an
    /// `allCases` loop whose expectations had been bent to match it, so the two
    /// ends are pinned against each other: the document home says yes on every
    /// project type, and Plan's own two segments say no.
    func test_theFooterPredicateIsNotAConstant() {
        for type in ProjectType.allCases {
            XCTAssertTrue(
                BinderSegment.documentHome(for: type).showsManuscriptStatusFooter,
                "\(type): the segment whose centre IS the document must carry "
                + "the footer")
        }
        XCTAssertFalse(BinderSegment.canvas.showsManuscriptStatusFooter)
        XCTAssertFalse(BinderSegment.tree.showsManuscriptStatusFooter,
                       "Plan's tree centres the canvas, not the document")
    }
}
