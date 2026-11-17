import XCTest
import MaughamCore
@testable import Maugham

/// **The tree's selection is a SET, and the window's subject is derived from
/// it** (shell-finish stage-2b Task 3).
///
/// Stage 2a gave every persona one left column and made its tree single-select,
/// because the window has exactly one subject. Stage 2b deletes the old research
/// panes — and with them the only surfaces in the app that can act on more than
/// one note at a time. So the tree learns what they knew: ⌘-click two notes and
/// the verbs act on both.
///
/// **The rules are pure and are tested here before anything is mounted.** The
/// routing-wants-a-pure-function lesson (1C-b): a decision spread across a
/// binding's setter is a decision no test can see. Every rule below is a static
/// over plain values, asked over its whole input; `BinderTreeMultiselectMountTests`
/// then drives the real `NSTableView` to prove the rules are wired to it.
final class BinderTreeMultiselectTests: XCTestCase {

    // MARK: - Fixtures

    private func note(_ id: String) -> ResearchItem {
        ResearchItem(id: id, title: id, type: .asset, kind: .document,
                     path: "research/\(id).md", addedAt: Date())
    }

    private func group(_ id: String, _ children: [ResearchItem]) -> ResearchItem {
        var g = ResearchItem(id: id, title: id, type: .group, kind: nil,
                             path: "research/\(id)", addedAt: Date())
        g.children = children
        return g
    }

    private func doc(_ id: String) -> StructureItem {
        StructureItem(id: id, title: id, type: .document, path: "\(id).md")
    }

    /// `[c1, c2]` in the structure; `[a, g[b], c]` in research.
    private var structure: [StructureItem] { [doc("c1"), doc("c2")] }
    private var research: [ResearchItem] { [note("a"), group("g", [note("b")]), note("c")] }
    private var figures: [String] { ["fig-00000002", "fig-00000001"] }

    /// A write over `subject`, the tree drawing `stored` as the rows its last
    /// click left (the subject unchanged since).
    private func resolve(
        written: Set<BinderSubject>,
        stored: Set<BinderSubject> = [],
        subject: WindowSubject
    ) -> (selection: Set<BinderSubject>, subject: WindowSubject) {
        BinderTreeSelection.resolved(
            written: written, stored: stored,
            shown: BinderTreeSelection.shown(stored, subject: subject, clickedAt: subject),
            subject: subject,
            structure: structure, research: research, figures: figures,
            projectType: .novel)
    }

    /// The Book open, `beside` opened next to it.
    private func beside(_ id: String) -> WindowSubject {
        WindowSubject(open: .project, faces: .project, beside: .research(id))
    }

    // MARK: - A single row is a click (shell p1 Task 3)

    /// **A write of one row is the click rule and nothing else**, from every
    /// subject, and the tree holds that row alone.
    func test_aSingleRowIsAClickThroughTheClickRule() {
        let subjects: [WindowSubject] = [
            .book, SubjectSamples.opened(.item("c1")), beside("a"),
            WindowSubject(open: .canvas, faces: .item("c1")),
        ]
        for subject in subjects {
            for written: BinderSubject in [.project, .item("c2"), .research("c"),
                                           .research("a"), .canvas] {
                let out = resolve(written: [written], stored: [.research("a")],
                                  subject: subject)
                XCTAssertEqual(
                    out.subject,
                    ClickRule.resolve(written, gesture: .click, current: subject,
                                      structure: structure, projectType: .novel),
                    "a one-row write is `ClickRule.resolve(_, .click, …)` "
                    + "(subject: \(subject), row: \(written))")
                // The row put away from beside is left unselected (I1).
                let dismissed = subject.beside == written
                XCTAssertEqual(out.selection, dismissed ? [] : [written])
            }
        }
    }

    /// A click on a research row opens it beside and leaves the centre alone.
    func test_aResearchRowClickedAloneGoesBeside() {
        let out = resolve(written: [.research("c")], subject: .book)
        XCTAssertEqual(out.subject, beside("c"))
    }

    /// A click on the row beside, when the tree was drawing another row
    /// selected, puts it away (controller ruling 2).
    ///
    /// **And the row it put away is not left selected** (fix round, I1): the
    /// tree draws nothing selected, so the table lets go of the note and the
    /// next click on it is a write the `List` delivers — which reopens it.
    func test_aClickOnTheRowBesidePutsItAway() {
        let out = resolve(written: [.research("a")], stored: [.project],
                          subject: beside("a"))
        XCTAssertEqual(out.subject, .book)
        XCTAssertEqual(out.selection, [])
        let shown = BinderTreeSelection.shown(out.selection, subject: out.subject,
                                              clickedAt: out.subject)
        XCTAssertFalse(shown.contains(.research("a")),
                       "the dismissed note is drawn selected, so the next click "
                       + "on it writes nothing and is swallowed")
        let again = BinderTreeSelection.resolved(
            written: [.research("a")], stored: out.selection, shown: shown,
            subject: out.subject, structure: structure, research: research,
            figures: figures, projectType: .novel)
        XCTAssertEqual(again.subject, beside("a"), "the next click reopens it beside")
        XCTAssertEqual(again.selection, [.research("a")])
    }

    /// **A plain click on the anchor of a live set** is the `List`'s write
    /// alone (the table collapses the set, so it writes): it puts the note
    /// away, and the watcher — which only answers a click on the table's ONE
    /// selected row — adds nothing, whatever order the two arrive in.
    func test_aPlainClickOnTheAnchorOfASetPutsItAwayOnOnePath() {
        let stored: Set<BinderSubject> = [.research("a"), .research("c")]
        let out = resolve(written: [.research("a")], stored: stored, subject: beside("a"))
        XCTAssertEqual(out.subject, .book)
        XCTAssertEqual(out.selection, [])
        for current in [beside("a"), out.subject] {
            XCTAssertEqual(
                TreeTravel.clickOnTheSelectedRow(.research("a"), rowWasSelected: false,
                                                 current: current, structure: structure,
                                                 projectType: .novel),
                current, "inside a set of several rows the watcher answers nothing")
        }
    }

    /// **The untagged-row refusal.** An untagged row — an empty section's
    /// placeholder, a slugline — is selected anyway and writes *nothing* through
    /// a `Set` binding (measured on macOS 26.5, `BinderTreeSectionsTests`). The
    /// write moves nothing: not the subject, not the multi-selection.
    func test_anEmptyWriteChangesNeitherTheSelectionNorTheSubject() {
        let stored: Set<BinderSubject> = [.research("a"), .research("c")]
        let out = resolve(written: [], stored: stored, subject: beside("a"))
        XCTAssertEqual(out.subject, beside("a"),
                       "a placeholder row is not a subject and must not clear one")
        XCTAssertEqual(out.selection, stored,
                       "and it must not empty the selection either — clicking "
                       + "'No research yet.' would drop the two notes the writer "
                       + "had picked")
    }

    /// **A set handed back unchanged** is not a click.
    func test_aSetHandedBackUnchangedChangesNothing() {
        let stored: Set<BinderSubject> = [.research("a"), .research("c")]
        let out = resolve(written: stored, stored: stored, subject: beside("a"))
        XCTAssertEqual(out.subject, beside("a"))
        XCTAssertEqual(out.selection, stored)
    }

    // MARK: - The anchor

    /// **A modifier click extends from the row beside**, which stays the
    /// anchor.
    func test_aModifierClickExtendsFromTheRowBeside() {
        let out = resolve(written: [.research("a"), .research("c")],
                          stored: [.research("a")], subject: beside("a"))
        XCTAssertEqual(out.selection, [.research("a"), .research("c")])
        XCTAssertEqual(out.subject, beside("a"),
                       "the note beside was in the set that grew — it stays put")
    }

    /// And when the writer ⌘-clicks the anchor itself away, what is beside
    /// follows the tree's own order rather than a set's arbitrary one.
    func test_whenTheAnchorLeavesTheSetTheFirstRowTheTreeDrawsGoesBeside() {
        let out = resolve(written: [.research("c"), .research("b")],
                          stored: [.research("a"), .research("b"), .research("c")],
                          subject: beside("a"))
        XCTAssertEqual(out.subject, beside("b"),
                       "b is drawn above c — inside g, which sits between a and c")
        XCTAssertEqual(out.selection, [.research("b"), .research("c")])
    }

    /// Structure has no plural verbs: a modifier click on a chapter is a click
    /// on that chapter.
    func test_aModifierClickOnAChapterIsAClickOnIt() {
        let out = resolve(written: [.research("a"), .item("c2")],
                          stored: [.research("a")], subject: beside("a"))
        XCTAssertEqual(out.subject,
                       WindowSubject(open: .item("c2"), faces: .item("c2"),
                                     beside: .research("a"), besideIsLatest: false),
                       "the chapter was clicked after the note: it is the part clicked last")
        XCTAssertEqual(out.selection, [.item("c2")])
    }

    // MARK: - Tree order

    func test_orderIsTheProjectThenTheStructureThenResearchAsDrawn() {
        let ordered = BinderTreeSelection.ordered(
            [.research("c"), .item("c2"), .project, .research("a"), .item("c1")],
            structure: structure, research: research, figures: figures)
        XCTAssertEqual(ordered,
                       [.project, .item("c1"), .item("c2"),
                        .research("a"), .research("c")],
                       "the project row heads every tree, its documents follow, "
                       + "and the Research and Palette sections are furniture at "
                       + "the foot — the order is the one the writer sees")
    }

    /// **The Figures section sits between the manuscript and Research**, and
    /// its rows keep the order the section draws, not the ids' order.
    func test_figuresComeAfterTheStructureAndBeforeResearchInDrawnOrder() {
        let ordered = BinderTreeSelection.ordered(
            [.research("a"), .figure("fig-00000001"), .item("c1"),
             .figure("fig-00000002"), .figure("fig-gone")],
            structure: structure, research: research, figures: figures)
        XCTAssertEqual(ordered,
                       [.item("c1"), .figure("fig-00000002"), .figure("fig-00000001"),
                        .research("a")],
                       "a figure the section does not draw is dropped like any dead id")
    }

    /// A figure row written alone takes the centre, like every tagged row
    /// that is not reference material.
    func test_aSingleFigureRowTakesTheCentre() {
        let next = resolve(written: [.figure("fig-00000001")],
                           subject: SubjectSamples.opened(.item("c1")))
        XCTAssertEqual(next.subject, SubjectSamples.opened(.figure("fig-00000001")))
        XCTAssertEqual(next.selection, [.figure("fig-00000001")])
    }

    /// **This is where a dead id dies.** The order is built by WALKING the live
    /// manifest, so an id the manifest no longer holds cannot come out of it —
    /// which is why nothing here needs a sweep of its own to prune the set
    /// (`BinderTreeSelection`'s note on the missing sweep).
    func test_orderDropsIdsTheManifestNoLongerHolds() {
        let ordered = BinderTreeSelection.ordered(
            [.research("a"), .research("gone"), .item("c9")],
            structure: structure, research: research, figures: figures)
        XCTAssertEqual(ordered, [.research("a")])
    }

    // MARK: - What the tree shows

    /// **The `List` draws the rows last clicked**, while the subject is the
    /// one that click made; any other change of subject shows the window's own
    /// last-clicked row — the measured reason is `BinderTreeSelection`'s doc.
    func test_theListDrawsTheClickedRowsUntilTheSubjectMovesElsewhere() {
        let afterClick = WindowSubject(open: .project, faces: .project,
                                       beside: .research("a"))
        XCTAssertEqual(BinderTreeSelection.shown([.project], subject: afterClick,
                                                 clickedAt: afterClick),
                       [.project], "the Book row the writer clicked stays selected")
        XCTAssertEqual(BinderTreeSelection.shown([.project], subject: beside("made-just-now"),
                                                 clickedAt: afterClick),
                       [.research("made-just-now")],
                       "a subject moved from elsewhere collapses the tree onto it")
        XCTAssertEqual(BinderTreeSelection.shown([], subject: .book, clickedAt: nil),
                       [.project], "nothing clicked yet: the window's own row")
    }

    /// **The marks**: the open row when the `List` is not drawing it, and the
    /// faces and what is beside when neither drawn nor open.
    func test_theOpenRowAndTheBesideRowAreMarkedWhenTheListDrawsAnother() {
        let canvas = WindowSubject(open: .canvas, faces: .item("c1"))
        let shown: Set<BinderSubject> = [.item("c1")]
        XCTAssertEqual(BinderTreeSelection.openMark(shown: shown, subject: canvas), .canvas)
        XCTAssertEqual(BinderTreeSelection.outlined(shown: shown, subject: canvas), [])
        let withNote = WindowSubject(open: .project, faces: .project, beside: .research("a"))
        XCTAssertNil(BinderTreeSelection.openMark(shown: [.project], subject: withNote))
        XCTAssertEqual(BinderTreeSelection.outlined(shown: [.project], subject: withNote),
                       [.research("a")])
        XCTAssertEqual(BinderTreeSelection.openMark(shown: [.research("a")], subject: withNote),
                       .project)
        XCTAssertEqual(BinderTreeSelection.outlined(shown: [.research("a")], subject: withNote),
                       [])
    }

    // MARK: - The acting set

    /// The shipped rule, reached from the tree: a row inside the selection acts
    /// for the whole selection, in visual order — `ResearchSelectionSync`'s
    /// `expandedDragIds`, called rather than restated.
    func test_aRowInsideTheSelectionActsForTheWholeSelectionInTreeOrder() {
        XCTAssertEqual(
            BinderTreeSelection.batch([.research("c"), .research("a")], subject: beside("a"),
                                      clickedAt: beside("a")),
            [.research("c"), .research("a")], "a live set is the batch")
        XCTAssertEqual(
            BinderTreeSelection.batch([.research("a")], subject: beside("a"),
                                      clickedAt: beside("a")), [],
            "one note is no batch")
        XCTAssertEqual(
            BinderTreeSelection.batch([.research("c"), .research("a")], subject: beside("a"),
                                      clickedAt: .book), [],
            "a set the subject has moved away from acts for nothing")
        XCTAssertEqual(
            BinderTreeSelection.actingResearchIds(
                forRow: "c", selection: [.research("c"), .research("a")],
                research: research),
            ["a", "c"])
    }

    func test_aRowOutsideTheSelectionActsAlone() {
        XCTAssertEqual(
            BinderTreeSelection.actingResearchIds(
                forRow: "b", selection: [.research("c"), .research("a")],
                research: research),
            ["b"],
            "standard Mac behaviour: acting on a row you have not selected acts "
            + "on that row only")
    }

    /// **Batch verbs offer only on a homogeneous research selection.** Structure
    /// has no batch verbs — no plural delete, no plural move — so a set holding
    /// the project row or a chapter degrades every research verb to the row it
    /// was aimed at rather than inventing one.
    func test_aSelectionHoldingAnythingButResearchDegradesToTheRow() {
        for intruder: BinderSubject in [.project, .item("c1")] {
            XCTAssertEqual(
                BinderTreeSelection.actingResearchIds(
                    forRow: "a", selection: [.research("a"), .research("c"), intruder],
                    research: research),
                ["a"],
                "a set containing \(intruder) is not a research batch")
        }
    }

    func test_aSingleSelectionActsOnItsOwnRow() {
        XCTAssertEqual(
            BinderTreeSelection.actingResearchIds(
                forRow: "a", selection: [.research("a")], research: research),
            ["a"])
    }

    /// The acting set is walked out of the manifest, so a note deleted from
    /// under a stale selection never reaches a plural store verb — no second
    /// sweep required, and no "Delete 3 Items" over two live notes.
    func test_theActingSetCannotCarryAnIdTheManifestHasLost() {
        XCTAssertEqual(
            BinderTreeSelection.actingResearchIds(
                forRow: "a", selection: [.research("a"), .research("gone")],
                research: research),
            ["a"],
            "the ghost drops out — `deleteResearchItems` would throw "
            + "`structureMissing` on it and take the live note down with it")
    }
}
