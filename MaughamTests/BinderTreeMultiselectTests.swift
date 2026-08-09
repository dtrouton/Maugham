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

    private func resolve(
        written: Set<BinderSubject>,
        stored: Set<BinderSubject> = [],
        subject: BinderSubject?
    ) -> (selection: Set<BinderSubject>, subject: BinderSubject?) {
        BinderTreeSelection.resolved(
            written: written, stored: stored, subject: subject,
            structure: structure, research: research)
    }

    // MARK: - A single row is stage 2a's rule, unchanged

    /// **The regression net's other half.** Every mounted selection test written
    /// for 2a is still green, and this says why structurally: a write of one row
    /// does not go near the anchor rule — it goes through the very function 2a
    /// shipped, and the set becomes exactly that row.
    func test_aSingleRowIsTheRuleStageTwoAShipped() {
        for subject: BinderSubject? in [nil, .project, .item("c1"), .research("a")] {
            for written: BinderSubject in [.project, .item("c2"), .research("c")] {
                let out = resolve(written: [written], stored: [.research("a")],
                                  subject: subject)
                XCTAssertEqual(
                    out.subject,
                    BinderTreeSelection.subject(subject, whenListWrites: written),
                    "a one-row write must produce exactly what 2a's single-value "
                    + "rule produces (subject: \(String(describing: subject)))")
                XCTAssertEqual(
                    out.selection, [written],
                    "…and the tree holds that row and nothing else — a click "
                    + "replaces the selection, it does not add to it")
            }
        }
    }

    /// **The 2a nil-refusal, generalized.** An untagged row — an empty section's
    /// placeholder, a slugline — is selected anyway and writes *nothing* through
    /// a `Set` binding, exactly as it wrote `nil` through the old one (measured
    /// on macOS 26.5, `BinderTreeSectionsTests`). A `nil` subject blanks the
    /// centre column, so the write is refused; a set that emptied would take the
    /// writer's whole multi-selection with it as well.
    func test_anEmptyWriteChangesNeitherTheSelectionNorTheSubject() {
        let stored: Set<BinderSubject> = [.research("a"), .research("c")]
        let out = resolve(written: [], stored: stored, subject: .research("a"))
        XCTAssertEqual(out.subject, .research("a"),
                       "a placeholder row is not a subject and must not clear one")
        XCTAssertEqual(out.selection, stored,
                       "and it must not empty the selection either — clicking "
                       + "'No research yet.' would drop the two notes the writer "
                       + "had picked")
    }

    func test_anEmptyWriteOverNoSubjectStaysEmptyHanded() {
        let out = resolve(written: [], stored: [], subject: nil)
        XCTAssertNil(out.subject)
        XCTAssertEqual(out.selection, [])
    }

    // MARK: - The anchor

    /// The whole point of deriving rather than replacing: the window is still
    /// about what it was about. ⌘-clicking a second note must not move the
    /// editor off the first.
    func test_theAnchorSurvivesAGrownSet() {
        let out = resolve(written: [.research("a"), .research("c")],
                          stored: [.research("a")], subject: .research("a"))
        XCTAssertEqual(out.subject, .research("a"),
                       "the subject was in the set that grew — it stays put")
        XCTAssertEqual(out.selection, [.research("a"), .research("c")])
    }

    /// And when the writer ⌘-clicks the anchor itself away, the subject follows
    /// the tree's own order rather than a set's arbitrary one.
    func test_whenTheAnchorLeavesTheSetTheSubjectIsTheFirstRowTheTreeDraws() {
        let out = resolve(written: [.research("c"), .research("b")],
                          stored: [.research("a"), .research("b"), .research("c")],
                          subject: .research("a"))
        XCTAssertEqual(out.subject, .research("b"),
                       "b is drawn above c (it is inside group g, which comes "
                       + "before c) — the subject is the first of what is left, "
                       + "in TREE order, not whichever element the Set yields first")
    }

    /// Determinism, said out loud: a `Set` has no first element, so the rule
    /// above must give the same answer however the set was built.
    func test_theAnchorFallbackIsTheSameWhicheverWayTheSetWasAssembled() {
        let members: [BinderSubject] = [.research("c"), .research("b"), .research("a")]
        for _ in 0..<50 {
            let out = resolve(written: Set(members.shuffled()), subject: .project)
            XCTAssertEqual(out.subject, .research("a"),
                           "the fallback must be the tree's order, every time")
        }
    }

    // MARK: - Tree order

    func test_orderIsTheProjectThenTheStructureThenResearchAsDrawn() {
        let ordered = BinderTreeSelection.ordered(
            [.research("c"), .item("c2"), .project, .research("a"), .item("c1")],
            structure: structure, research: research)
        XCTAssertEqual(ordered,
                       [.project, .item("c1"), .item("c2"),
                        .research("a"), .research("c")],
                       "the project row heads every tree, its documents follow, "
                       + "and the Research and Palette sections are furniture at "
                       + "the foot — the order is the one the writer sees")
    }

    /// **This is where a dead id dies.** The order is built by WALKING the live
    /// manifest, so an id the manifest no longer holds cannot come out of it —
    /// which is why nothing here needs a sweep of its own to prune the set
    /// (`BinderTreeSelection`'s note on the missing sweep).
    func test_orderDropsIdsTheManifestNoLongerHolds() {
        let ordered = BinderTreeSelection.ordered(
            [.research("a"), .research("gone"), .item("c9")],
            structure: structure, research: research)
        XCTAssertEqual(ordered, [.research("a")])
    }

    // MARK: - What the tree shows

    /// A programmatic subject write — a creation, a restore, a navigation from
    /// another column — collapses the tree to that one row. There is no flag and
    /// no `.onChange` doing it (tripwire 2): the shown set is a projection of
    /// the stored one through the subject, so the two cannot get out of step.
    func test_aSubjectTheSelectionDoesNotHoldCollapsesTheTreeOntoIt() {
        XCTAssertEqual(
            BinderTreeSelection.shown([.research("a"), .research("c")],
                                      subject: .research("made-just-now")),
            [.research("made-just-now")])
    }

    func test_aSubjectTheSelectionDoesHoldLeavesTheRestSelected() {
        XCTAssertEqual(
            BinderTreeSelection.shown([.research("a"), .research("c")],
                                      subject: .research("c")),
            [.research("a"), .research("c")])
    }

    func test_noSubjectShowsNothing() {
        XCTAssertEqual(
            BinderTreeSelection.shown([.research("a")], subject: nil), [])
    }

    // MARK: - The acting set

    /// The shipped rule, reached from the tree: a row inside the selection acts
    /// for the whole selection, in visual order — `ResearchSelectionSync`'s
    /// `expandedDragIds`, called rather than restated.
    func test_aRowInsideTheSelectionActsForTheWholeSelectionInTreeOrder() {
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
