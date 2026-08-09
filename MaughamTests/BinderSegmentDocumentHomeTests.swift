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

    // MARK: - The status footer's own question (slice 2 task 9, re-cut in
    //         shell-finish stage 2b Task 6)

    /// **Every window state answers, and the exhaustive switch below is what
    /// makes that true.**
    ///
    /// `shouldShowStatusFooter` once spelled this as
    /// `== .manuscript || == .scenes`, which answered "no" for `.canvas` and
    /// again for `.tree` by inheriting rather than by deciding — right both
    /// times, and by luck both times. Slice 2 made it an exhaustive switch over
    /// the segment; Task 6 re-based it onto the persona, because the segment was
    /// only ever a proxy for which persona's centre column the writer was
    /// looking at, and the segment enum dies in Task 7.
    ///
    /// **So the expectation below is now a switch over the PAIR**, and it is
    /// still exhaustive on the segment side with no `default:`: a new
    /// `BinderSegment` breaks the compile here as well as in production while
    /// the enum stands.
    ///
    /// The interesting row is `.find`, and it is asserted rather than skipped.
    /// It said `false` until 2026-08-02 — an oversight from before find had a
    /// centre column of its own, ruled as such by Denver when slice 2's task 9
    /// surfaced it. Find is an overlay of the LEFT column since Task 1, so the
    /// document never left the centre: the goal capsule, the live session words
    /// and the ¶id/element readout all remain true while a search panel is open
    /// beside them, and the footer follows the document rather than the shape of
    /// the left column. Under the new basis that answer falls out instead of
    /// being an entry in a switch, which is what Task 1's before-equals-after
    /// assertion predicted.
    func test_everyWindowStateDeclaresWhetherTheStatusFooterFollowsIt() {
        for persona in Persona.allCases {
            for segment in BinderSegment.allCases {
                let expected: Bool
                switch segment {
                case .manuscript, .scenes, .tree, .canvas:
                    // The centre column is a document — unless the persona's
                    // centre is the board. Word goals and a cursor's ¶id are
                    // manuscript facts; the canvas has neither.
                    expected = !persona.centresTheCanvas
                case .research, .palette, .trash:
                    // An old pane holds the centre, in any persona: a forced
                    // `.research` in Author is the reachable one.
                    expected = false
                case .find:
                    // The overlay is the left column's; the centre is whatever
                    // it was, so the answer is the persona's alone.
                    expected = !persona.centresTheCanvas
                }
                XCTAssertEqual(
                    ProjectWindow.showsStatusFooter(persona: persona,
                                                    interimSegment: segment,
                                                    subject: .item("doc1")),
                    expected,
                    "\(persona)/.\(segment) disagrees with the shipped rule")
            }
        }
    }

    /// The control. A gate that answered a constant would satisfy a loop whose
    /// expectations had been bent to match it, so both ends are pinned: the
    /// personas that centre a document say yes on every project type's home
    /// segment, and Plan says no on both of its own.
    func test_theFooterGateIsNotAConstant() {
        for type in ProjectType.allCases {
            for persona in Persona.allCases where !persona.centresTheCanvas {
                XCTAssertTrue(
                    ProjectWindow.showsStatusFooter(
                        persona: persona,
                        interimSegment: .documentHome(for: type),
                        subject: .item("doc1")),
                    "\(persona)/\(type): the persona whose centre IS the "
                    + "document must carry the footer")
            }
        }
        for segment in [BinderSegment.canvas, .tree] {
            XCTAssertFalse(
                ProjectWindow.showsStatusFooter(persona: .plan,
                                                interimSegment: segment,
                                                subject: .item("doc1")),
                "Plan centres the canvas, not the document — .\(segment)")
        }
    }
}
