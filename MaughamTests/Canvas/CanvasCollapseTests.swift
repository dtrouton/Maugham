import XCTest
import SwiftUI
@testable import Maugham
import MaughamCore

/// `⌘\` gives the canvas the whole window (spec §8A.3).
///
/// **The decision is a pure function and it is asked over the whole product of
/// its inputs**, not over the one path this task's brief named. Both of this
/// window's routing bugs were found that way and neither was found by a test
/// written along the happy path — see `CanvasPersonaTests`, whose doc comment
/// says so at length about `inspectorRoute`, the very predicate this reuses.
final class CanvasCollapseTests: XCTestCase {

    private let routes: [ProjectWindow.InspectorRoute] = [.canvas, .collectionPiece, .segment]
    private let stashes: [Bool?] = [nil, true, false]

    // MARK: - The collapse

    /// **The enum case is named, and that is the whole point of this test.**
    /// `.detailOnly` is the value that reads as "everything else away" and it
    /// hides the canvas itself, because the canvas is the CONTENT column. An
    /// assertion of the form "not `.all`" is satisfied by the trap; only an
    /// equality is not.
    func test_focusModeOnTheCanvasCollapsesToDoubleColumnAndHidesTheInspector() {
        for wasVisible in [true, false] {
            XCTAssertEqual(
                ProjectWindow.canvasCollapse(route: .canvas,
                                             isNoChromeOn: true,
                                             showInspector: wasVisible,
                                             stash: nil,
                                             paletteStash: nil),
                .collapse(columnVisibility: .doubleColumn,
                          showInspector: false,
                          stash: wasVisible,
                          takesOverPaletteStash: false),
                "the sidebar goes and the detail column empties, leaving the "
                + "middle column — which is where CanvasView lives — the window")
        }
    }

    /// The trap, spelled out on its own so a future edit that reaches for the
    /// obvious case fails against a test that says why it is wrong rather than
    /// against a tuple mismatch.
    func test_theCollapsedVisibilityIsNotDetailOnly() {
        guard case .collapse(let visibility, _, _, _) = ProjectWindow.canvasCollapse(
            route: .canvas, isNoChromeOn: true, showInspector: true,
            stash: nil, paletteStash: nil)
        else { return XCTFail("focus mode on the canvas must collapse") }
        XCTAssertEqual(visibility, .doubleColumn)
        XCTAssertNotEqual(
            visibility, .detailOnly,
            "`.detailOnly` keeps the DETAIL column and drops the content one — "
            + "the canvas is the content column, so it would blank the surface "
            + "the writer just asked to see more of")
    }

    /// **The control.** Without it every assertion above is satisfied by a
    /// modifier that fires everywhere: `⌘\` in the editor must behave exactly as
    /// it did before this task — titlebar and traffic lights, no column.
    ///
    /// `.unchanged` is stronger than the brief's "leaves the split view at
    /// `.all`": nothing is written at all, so a sidebar the writer dragged shut
    /// by hand stays shut and a window that never collapses keeps the
    /// `.automatic` it was born with.
    func test_focusModeOffTheCanvasTouchesNoColumn() {
        for route in routes where route != .canvas {
            for isNoChromeOn in [true, false] {
                for showInspector in [true, false] {
                    XCTAssertEqual(
                        ProjectWindow.canvasCollapse(route: route,
                                                     isNoChromeOn: isNoChromeOn,
                                                     showInspector: showInspector,
                                                     stash: nil,
                                                     paletteStash: nil),
                        .unchanged,
                        "⌘\\ in the editor moves no column — \(route), "
                        + "noChrome \(isNoChromeOn), inspector \(showInspector)")
                }
            }
        }
    }

    /// And the other half of the control: on the canvas with focus mode OFF,
    /// which is every writer who has never pressed `⌘\`, nothing happens either.
    /// This is §8A.3's "never automatic on entering the persona" — you need the
    /// binder open to drag research and captures onto the canvas.
    func test_arrivingOnTheCanvasWithoutFocusModeCollapsesNothing() {
        for showInspector in [true, false] {
            XCTAssertEqual(
                ProjectWindow.canvasCollapse(route: .canvas,
                                             isNoChromeOn: false,
                                             showInspector: showInspector,
                                             stash: nil,
                                             paletteStash: nil),
                .unchanged,
                "entering Plan must not collapse anything by itself")
        }
    }

    // MARK: - The release

    func test_turningFocusModeOffOnTheCanvasGivesTheColumnsBack() {
        for prior in [true, false] {
            XCTAssertEqual(
                ProjectWindow.canvasCollapse(route: .canvas,
                                             isNoChromeOn: false,
                                             showInspector: false,
                                             stash: prior,
                                             paletteStash: nil),
                .release(columnVisibility: .all, showInspector: prior),
                "the inspector comes back exactly as the writer left it")
        }
    }

    /// Leaving the canvas with the collapse still in force releases it too — a
    /// hidden binder in the editor with no visible way back is worse than the
    /// thing this feature fixes.
    func test_leavingTheCanvasWhileCollapsedGivesTheColumnsBack() {
        for route in routes where route != .canvas {
            for prior in [true, false] {
                XCTAssertEqual(
                    ProjectWindow.canvasCollapse(route: route,
                                                 isNoChromeOn: true,
                                                 showInspector: false,
                                                 stash: prior,
                                                 paletteStash: nil),
                    .release(columnVisibility: .all, showInspector: prior),
                    "focus mode stays on, but the columns are not the canvas's "
                    + "to keep once the centre stops being the canvas — \(route)")
            }
        }
    }

    /// **The idempotence that stops the stash eating itself.** Both of the
    /// modifier's triggers fold this decision, and on a project reopen that
    /// restores focus mode *and* the canvas from `UIState` they fire together.
    /// Without this arm the second fold would stash the `false` the first one
    /// wrote and the inspector would never come back.
    func test_anAlreadyCollapsedCanvasIsNotCollapsedTwice() {
        for prior in [true, false] {
            XCTAssertEqual(
                ProjectWindow.canvasCollapse(route: .canvas,
                                             isNoChromeOn: true,
                                             showInspector: false,
                                             stash: prior,
                                             paletteStash: nil),
                .unchanged,
                "the stash is the memory AND the already-collapsed flag")
        }
    }

    // MARK: - Exhaustively, over the product

    /// Every combination of (route × focus mode × inspector × stash × palette
    /// stash) is asked, and the answer is characterised rather than mirrored: a
    /// table that restated the implementation would agree with it however wrong
    /// it was.
    ///
    /// The properties are the whole contract — when a collapse may be answered,
    /// when a release may be, which memory a collapse remembers, and that
    /// neither ever names a visibility other than the two this window has a
    /// reason for.
    func test_everyCombinationIsAnsweredAndOnlyTheRightOnesMove() {
        var collapses = 0
        var releases = 0
        var unchanged = 0
        var takeovers = 0
        for route in routes {
            for isNoChromeOn in [true, false] {
                for showInspector in [true, false] {
                    for stash in stashes {
                        for paletteStash in stashes {
                            let where_ = "route \(route), noChrome \(isNoChromeOn), "
                                + "inspector \(showInspector), stash \(String(describing: stash))"
                                + ", palette \(String(describing: paletteStash))"
                            let wantsTheWholeWindow = route == .canvas && isNoChromeOn
                            switch ProjectWindow.canvasCollapse(
                                route: route, isNoChromeOn: isNoChromeOn,
                                showInspector: showInspector, stash: stash,
                                paletteStash: paletteStash) {
                            case .collapse(let visibility, let inspector,
                                           let stashed, let takesOver):
                                collapses += 1
                                if takesOver { takeovers += 1 }
                                XCTAssertTrue(wantsTheWholeWindow,
                                              "only the canvas in focus mode collapses — \(where_)")
                                XCTAssertNil(stash,
                                             "a collapse is never answered over a live stash — \(where_)")
                                XCTAssertEqual(visibility, .doubleColumn, where_)
                                XCTAssertFalse(inspector, where_)
                                XCTAssertEqual(
                                    stashed, paletteStash ?? showInspector,
                                    "a live palette memory is what gets remembered, and "
                                    + "what is showing only when there is none — \(where_)")
                                XCTAssertEqual(
                                    takesOver, paletteStash != nil,
                                    "and the takeover is declared exactly when it happened, "
                                    + "or the palette's exit arm restores over it — \(where_)")
                            case .release(let visibility, let inspector):
                                releases += 1
                                XCTAssertFalse(wantsTheWholeWindow,
                                               "a collapsed canvas is not released — \(where_)")
                                XCTAssertNotNil(stash,
                                                "nothing is released that was never collapsed — \(where_)")
                                XCTAssertEqual(visibility, .all, where_)
                                XCTAssertEqual(inspector, stash,
                                               "the inspector comes back as stashed — \(where_)")
                            case .unchanged:
                                unchanged += 1
                            }
                        }
                    }
                }
            }
        }
        // The control on the loop itself: an `if` that never fires, or a product
        // that silently shrank to one route, satisfies every assertion above.
        XCTAssertEqual(collapses + releases + unchanged,
                       routes.count * 2 * 2 * stashes.count * stashes.count,
                       "every combination was asked exactly once")
        XCTAssertGreaterThan(collapses, 0, "the product reaches the collapse arm")
        XCTAssertGreaterThan(releases, 0, "the product reaches the release arm")
        XCTAssertGreaterThan(unchanged, 0, "the product reaches the untouched arm")
        XCTAssertGreaterThan(takeovers, 0, "and it reaches a collapse that takes the palette's memory")
    }

    // MARK: - The three-pass sequence that broke the palette

    /// **Collapse on the canvas → switch persona → switch back**, driven through
    /// the SAME fold the window uses, in the pass order SwiftUI actually
    /// delivers: `PersonaModifier`'s handler runs synchronously on the command,
    /// and `CanvasCollapseModifier`'s `.onChange(of: binderSegment)` runs in a
    /// LATER pass.
    ///
    /// The writer here had already closed the inspector with `⌘⌥I` — the case
    /// that makes the hazard visible. With the release in the later pass alone,
    /// `showInspector` comes back as `false` over `PersonaModifier`'s
    /// unconditional force-open, and the writer lands in Author with a closed
    /// inspector column unlike every other persona switch. That is the palette
    /// bug exactly, one surface over.
    func test_theCollapseSurvivesAPersonaSwitchAndComesBack() {
        var window = WindowState(showInspector: false)   // ⌘⌥I, before any of this

        // Pass 1 — ⌘\ on the canvas.
        window.foldCollapse(route: .canvas, isNoChromeOn: true)
        XCTAssertEqual(window.columnVisibility, .doubleColumn)
        XCTAssertEqual(window.canvasStash, false, "the closed inspector is what gets remembered")

        // Pass 2 — ⌘2. PersonaModifier's own handler, synchronously.
        if PersonaModifier.releasesCanvasCollapse(from: .canvas,
                                                  to: .manuscript,
                                                  stash: window.canvasStash) {
            window.canvasStash = nil
            window.columnVisibility = .all
        }
        window.showInspector = true               // the unconditional force-open

        // Pass 3 — CanvasCollapseModifier's .onChange, one pass later.
        window.foldCollapse(route: .segment, isNoChromeOn: true)
        XCTAssertTrue(window.showInspector,
                      "the later pass must not restore the stash over the "
                      + "force-open — this is the assertion the predicate "
                      + "extension exists for")
        XCTAssertEqual(window.columnVisibility, .all, "and the binder came back with it")
        XCTAssertNil(window.canvasStash)

        // Pass 4 — ⌘1 back to Plan. Focus mode never went off, so the canvas
        // takes the window again.
        window.showInspector = true               // the force-open, again
        window.foldCollapse(route: .canvas, isNoChromeOn: true)
        XCTAssertEqual(window.columnVisibility, .doubleColumn)
        XCTAssertFalse(window.showInspector)
        XCTAssertEqual(window.canvasStash, true, "and remembers what it found this time")
    }

    // MARK: - The picker, and the pass the two surfaces used to share

    /// **Palette → Canvas used to be ONE CLICK needing no persona switch**, and
    /// this pinned the two update orders — `PaletteSegmentModifier`'s exit arm
    /// and `CanvasCollapseModifier`'s collapse, both firing on the same
    /// `binderSegment` change — against disagreeing.
    ///
    /// **Dormant since stage 2b Task 5, not deleted.** `PaletteWallModifier`
    /// (the renamed `PaletteSegmentModifier`) keys its stash on
    /// `showsPaletteWall` now, which the picker's `.palette` segment does not
    /// touch at all — so clicking Palette then Canvas in Plan's picker no
    /// longer runs any wall fold in the same pass as the collapse; it can't,
    /// because `showsPaletteWall` is disabled and force-closed in Plan, so it
    /// and a canvas-centring segment can never both be live. Rewritten to drive
    /// `foldPalette`'s `Bool` shape directly rather than the picker, this still
    /// pins a true statement about how the two folds compose — a statement
    /// Task 6/7 may make reachable again a different way, and a test that
    /// deleted it here would have to re-derive it from nothing if so.
    func test_theWallAndCanvasFoldsEndTheSameWayInEitherOrder() {
        for priorInspector in [true, false] {
            // The wall is open: it has stashed what the writer had and forced
            // the pane shut. Then the wall closes and the canvas collapses.
            var wallFirst = WindowState(showInspector: priorInspector)
            wallFirst.foldPalette(from: false, to: true)
            XCTAssertEqual(wallFirst.paletteStash, priorInspector)
            XCTAssertFalse(wallFirst.showInspector, "the wall takes the width")
            var collapseFirst = wallFirst

            wallFirst.foldPalette(from: true, to: false)
            wallFirst.foldCollapse(route: .canvas, isNoChromeOn: true)

            collapseFirst.foldCollapse(route: .canvas, isNoChromeOn: true)
            collapseFirst.foldPalette(from: true, to: false)

            XCTAssertEqual(
                wallFirst, collapseFirst,
                "the two update orders must agree — prior inspector \(priorInspector)")
            XCTAssertEqual(wallFirst.columnVisibility, .doubleColumn,
                           "and the canvas got the window")
            XCTAssertFalse(wallFirst.showInspector,
                           "with the pane shut rather than reopened over the collapse")
            XCTAssertEqual(wallFirst.canvasStash, priorInspector,
                           "and what it remembers is what the writer had BEFORE the "
                           + "wall forced it shut, not the wall's own false")
            XCTAssertNil(wallFirst.paletteStash,
                         "the wall's memory was taken over, so its exit arm has "
                         + "nothing left to restore over the collapse")
        }
    }

    /// The half that says the fix did not simply hide the pane everywhere: the
    /// writer presses `⌘\` again and gets back what they had **before the
    /// wall**, which is the only value that was ever theirs. Dormant for
    /// `test_theWallAndCanvasFoldsEndTheSameWayInEitherOrder`'s reason.
    func test_leavingTheCollapseAfterTheWallRestoresWhatTheWriterHad() {
        for priorInspector in [true, false] {
            var window = WindowState(showInspector: priorInspector)
            window.foldPalette(from: false, to: true)
            window.foldPalette(from: true, to: false)
            window.foldCollapse(route: .canvas, isNoChromeOn: true)
            window.foldCollapse(route: .canvas, isNoChromeOn: false)   // ⌘\ off
            XCTAssertEqual(window.showInspector, priorInspector)
            XCTAssertEqual(window.columnVisibility, .all)
            XCTAssertNil(window.canvasStash)
        }
    }

    /// **The control for the takeover**, and without it a collapse that always
    /// cleared the palette's memory would satisfy everything above. Arriving on
    /// the canvas from anywhere that is not the wall leaves that memory alone,
    /// because there is none — and the collapse says so.
    func test_aCollapseThatMeetsNoWallTakesNothingOver() {
        for showInspector in [true, false] {
            guard case .collapse(_, _, let stashed, let takesOver) =
                    ProjectWindow.canvasCollapse(route: .canvas, isNoChromeOn: true,
                                                 showInspector: showInspector,
                                                 stash: nil, paletteStash: nil)
            else { return XCTFail("focus mode on the canvas must collapse") }
            XCTAssertFalse(takesOver, "there is no wall memory to take")
            XCTAssertEqual(stashed, showInspector, "so what is showing is what is kept")
        }
    }

    /// And the wall's own rule is unchanged by the extraction: opening stashes
    /// and hides, closing restores and forgets the selected card.
    func test_theWallsOwnRuleStillWorksWithNoCanvasInvolved() {
        var showInspector = true
        var stash: Bool?
        var card: String? = "card-1"
        ProjectWindow.applyPaletteWallChange(
            from: false, to: true, showInspector: &showInspector,
            stash: &stash, selectedPaletteCardId: &card)
        XCTAssertFalse(showInspector)
        XCTAssertEqual(stash, true)
        XCTAssertEqual(card, "card-1", "the card survives opening")

        ProjectWindow.applyPaletteWallChange(
            from: true, to: false, showInspector: &showInspector,
            stash: &stash, selectedPaletteCardId: &card)
        XCTAssertTrue(showInspector)
        XCTAssertNil(stash)
        XCTAssertNil(card, "and is cleared on the way out")
    }

    // MARK: - The predicate

    func test_thePredicateFiresOnlyWhenALiveCollapseLeavesTheCanvas() {
        XCTAssertTrue(
            PersonaModifier.releasesCanvasCollapse(from: .canvas, to: .manuscript, stash: true),
            "leaving the canvas with a collapse in force releases it")
        XCTAssertTrue(
            PersonaModifier.releasesCanvasCollapse(from: .canvas, to: .research, stash: false),
            "and a stashed `false` is a live collapse just as much as a `true` — "
            + "the flag is optionality, not the value")
    }

    /// The controls, one per way the predicate could be made to fire everywhere.
    func test_thePredicateIsFalseWhenTheCanvasSurvivesTheSwitch() {
        XCTAssertFalse(
            PersonaModifier.releasesCanvasCollapse(from: .canvas, to: .canvas, stash: true),
            "⌘1 while already in Plan keeps the collapse")
    }

    func test_thePredicateIsFalseWhenNothingWasCollapsed() {
        XCTAssertFalse(
            PersonaModifier.releasesCanvasCollapse(from: .canvas, to: .manuscript, stash: nil),
            "a persona switch off an UNCOLLAPSED canvas reopens nothing — the "
            + "writer may have dragged the sidebar shut themselves")
    }

    func test_thePredicateIsFalseWhenTheBinderWasNotOnTheCanvas() {
        XCTAssertFalse(
            PersonaModifier.releasesCanvasCollapse(from: .manuscript, to: .research, stash: true),
            "a switch that never touched the canvas is not this rule's business")
    }

    /// **Re-derived for `clearsPaletteWallStash`'s new shape** (stage 2b Task
    /// 5). It no longer shares the `leaves` helper with the canvas's predicate
    /// below — the wall is not a segment transition any more, so there is no
    /// `from`/`to` pair to fold a predicate over; the question collapses to
    /// "is the wall open, and is the destination Plan."
    func test_thePaletteWallStashRuleClearsExactlyWhenPlanCloses() {
        XCTAssertTrue(PersonaModifier.clearsPaletteWallStash(
            showsPaletteWall: true, enteringPersona: .plan))
        XCTAssertFalse(PersonaModifier.clearsPaletteWallStash(
            showsPaletteWall: true, enteringPersona: .author),
            "the wall survives every persona but Plan")
        XCTAssertFalse(PersonaModifier.clearsPaletteWallStash(
            showsPaletteWall: false, enteringPersona: .plan),
            "nothing to drop when the wall was already closed")
    }

    // MARK: - The tree centres the canvas, so it is not a way OFF it

    /// **A `.canvas` ↔ `.tree` flip must move no column at all.**
    ///
    /// Both segments draw the canvas in the centre, so a writer in focus mode
    /// flipping between them has not left the canvas. Spelled as `== .canvas`
    /// this predicate would answer `true` and hand the sidebar back — and
    /// `CanvasCollapseModifier`, which re-derives through `inspectorRoute` on
    /// `.onChange(of: binderSegment)`, would then collapse it again on the next
    /// pass: the sidebar moving under the writer twice while the canvas never
    /// left the screen.
    ///
    /// Asked over the whole product of the two canvas-centring segments rather
    /// than over the one flip that motivated it.
    func test_aFlipBetweenTheTwoCanvasSegmentsReleasesNothing() {
        for from in [BinderSegment.canvas, .tree] {
            for to in [BinderSegment.canvas, .tree] {
                XCTAssertFalse(
                    PersonaModifier.releasesCanvasCollapse(from: from, to: to, stash: true),
                    "\(from) → \(to): the canvas is the centre on both sides")
            }
        }
    }

    /// And the half that says the widening did not swallow the rule: leaving the
    /// canvas centre ALTOGETHER still releases, from either segment.
    func test_leavingTheCanvasCentreFromEitherSegmentStillReleases() {
        for from in [BinderSegment.canvas, .tree] {
            for to in [BinderSegment.manuscript, .scenes, .research, .palette] {
                XCTAssertTrue(
                    PersonaModifier.releasesCanvasCollapse(from: from, to: to, stash: true),
                    "\(from) → \(to): the canvas is gone, so the sidebar comes back")
            }
        }
    }

    /// The modifier's own re-derivation, driven rather than described:
    /// `CanvasCollapseModifier` asks `inspectorRoute`, so the tree must produce
    /// the SAME collapse decision the canvas does. Without this the predicate
    /// above could be right while the modifier that actually runs is not.
    func test_theCollapseDecisionIsTheSameOnTheTreeAsOnTheCanvas() {
        for type in ProjectType.allCases {
            for isNoChromeOn in [true, false] {
                for stash in stashes {
                    let onCanvas = ProjectWindow.canvasCollapse(
                        route: ProjectWindow.inspectorRoute(binderSegment: .canvas,
                                                            projectType: type),
                        isNoChromeOn: isNoChromeOn, showInspector: true,
                        stash: stash, paletteStash: nil)
                    let onTree = ProjectWindow.canvasCollapse(
                        route: ProjectWindow.inspectorRoute(binderSegment: .tree,
                                                            projectType: type),
                        isNoChromeOn: isNoChromeOn, showInspector: true,
                        stash: stash, paletteStash: nil)
                    XCTAssertEqual(onCanvas, onTree,
                                   "\(type)/noChrome=\(isNoChromeOn)/stash="
                                   + "\(String(describing: stash))")
                }
            }
        }
    }

    // MARK: - The window's state, as a value

    /// The pieces of `ProjectWindow` state these folds move, carried together so
    /// a sequence test can compare two update orders **whole**. Comparing them
    /// field by field is how an order test comes to pass while disagreeing about
    /// the field nobody listed — which is also why this sentence counts nothing:
    /// it said "the four pieces" over five stored properties, and a prose count
    /// beside the thing it counts is what this slice measured eleven times.
    /// Read the fields.
    ///
    /// Both `fold` methods call the production statics; nothing here mirrors a
    /// rule.
    private struct WindowState: Equatable {
        var columnVisibility: NavigationSplitViewVisibility = .automatic
        var showInspector: Bool
        var canvasStash: Bool?
        var paletteStash: Bool?
        var selectedPaletteCardId: String?

        mutating func foldCollapse(route: ProjectWindow.InspectorRoute, isNoChromeOn: Bool) {
            ProjectWindow.applyCanvasCollapse(
                ProjectWindow.canvasCollapse(route: route,
                                             isNoChromeOn: isNoChromeOn,
                                             showInspector: showInspector,
                                             stash: canvasStash,
                                             paletteStash: paletteStash),
                columnVisibility: &columnVisibility,
                showInspector: &showInspector,
                stash: &canvasStash,
                paletteStash: &paletteStash)
        }

        mutating func foldPalette(from old: Bool, to new: Bool) {
            ProjectWindow.applyPaletteWallChange(
                from: old, to: new,
                showInspector: &showInspector,
                stash: &paletteStash,
                selectedPaletteCardId: &selectedPaletteCardId)
        }
    }
}
