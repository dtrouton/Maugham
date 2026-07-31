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
                                             stash: nil),
                .collapse(columnVisibility: .doubleColumn,
                          showInspector: false,
                          stash: wasVisible),
                "the sidebar goes and the detail column empties, leaving the "
                + "middle column — which is where CanvasView lives — the window")
        }
    }

    /// The trap, spelled out on its own so a future edit that reaches for the
    /// obvious case fails against a test that says why it is wrong rather than
    /// against a tuple mismatch.
    func test_theCollapsedVisibilityIsNotDetailOnly() {
        guard case .collapse(let visibility, _, _) = ProjectWindow.canvasCollapse(
            route: .canvas, isNoChromeOn: true, showInspector: true, stash: nil)
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
                                                     stash: nil),
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
                                             stash: nil),
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
                                             stash: prior),
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
                                                 stash: prior),
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
                                             stash: prior),
                .unchanged,
                "the stash is the memory AND the already-collapsed flag")
        }
    }

    // MARK: - Exhaustively, over the product

    /// Every combination of (route × focus mode × inspector × stash) is asked,
    /// and the answer is characterised rather than mirrored: a table that
    /// restated the implementation would agree with it however wrong it was.
    ///
    /// The three properties are the whole contract — when a collapse may be
    /// answered, when a release may be, and that neither ever names a visibility
    /// other than the two this window has a reason for.
    func test_everyCombinationIsAnsweredAndOnlyTheRightOnesMove() {
        var collapses = 0
        var releases = 0
        var unchanged = 0
        for route in routes {
            for isNoChromeOn in [true, false] {
                for showInspector in [true, false] {
                    for stash in stashes {
                        let where_ = "route \(route), noChrome \(isNoChromeOn), "
                            + "inspector \(showInspector), stash \(String(describing: stash))"
                        let wantsTheWholeWindow = route == .canvas && isNoChromeOn
                        switch ProjectWindow.canvasCollapse(
                            route: route, isNoChromeOn: isNoChromeOn,
                            showInspector: showInspector, stash: stash) {
                        case .collapse(let visibility, let inspector, let stashed):
                            collapses += 1
                            XCTAssertTrue(wantsTheWholeWindow,
                                          "only the canvas in focus mode collapses — \(where_)")
                            XCTAssertNil(stash,
                                         "a collapse is never answered over a live stash — \(where_)")
                            XCTAssertEqual(visibility, .doubleColumn, where_)
                            XCTAssertFalse(inspector, where_)
                            XCTAssertEqual(stashed, showInspector,
                                           "what is stashed is what was showing — \(where_)")
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
        // The control on the loop itself: an `if` that never fires, or a product
        // that silently shrank to one route, satisfies every assertion above.
        XCTAssertEqual(collapses + releases + unchanged,
                       routes.count * 2 * 2 * stashes.count,
                       "every combination was asked exactly once")
        XCTAssertGreaterThan(collapses, 0, "the product reaches the collapse arm")
        XCTAssertGreaterThan(releases, 0, "the product reaches the release arm")
        XCTAssertGreaterThan(unchanged, 0, "the product reaches the untouched arm")
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
        var visibility = NavigationSplitViewVisibility.automatic
        var showInspector = false          // ⌘⌥I, before any of this
        var stash: Bool?

        func fold(route: ProjectWindow.InspectorRoute, isNoChromeOn: Bool) {
            ProjectWindow.applyCanvasCollapse(
                ProjectWindow.canvasCollapse(route: route,
                                             isNoChromeOn: isNoChromeOn,
                                             showInspector: showInspector,
                                             stash: stash),
                columnVisibility: &visibility,
                showInspector: &showInspector,
                stash: &stash)
        }

        // Pass 1 — ⌘\ on the canvas.
        fold(route: .canvas, isNoChromeOn: true)
        XCTAssertEqual(visibility, .doubleColumn)
        XCTAssertEqual(stash, false, "the closed inspector is what gets remembered")

        // Pass 2 — ⌘2. PersonaModifier's own handler, synchronously.
        var binderSegment = BinderSegment.canvas
        let destination = BinderSegment.manuscript
        if PersonaModifier.releasesCanvasCollapse(from: binderSegment,
                                                  to: destination,
                                                  stash: stash) {
            stash = nil
            visibility = .all
        }
        showInspector = true               // the unconditional force-open
        binderSegment = destination

        // Pass 3 — CanvasCollapseModifier's .onChange, one pass later.
        fold(route: .segment, isNoChromeOn: true)
        XCTAssertTrue(showInspector,
                      "the later pass must not restore the stash over the "
                      + "force-open — this is the assertion the predicate "
                      + "extension exists for")
        XCTAssertEqual(visibility, .all, "and the binder came back with it")
        XCTAssertNil(stash)

        // Pass 4 — ⌘1 back to Plan. Focus mode never went off, so the canvas
        // takes the window again.
        showInspector = true               // the force-open, again
        fold(route: .canvas, isNoChromeOn: true)
        XCTAssertEqual(visibility, .doubleColumn)
        XCTAssertFalse(showInspector)
        XCTAssertEqual(stash, true, "and remembers what it found this time")
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

    /// The palette's own predicate still answers exactly as it did, so the
    /// shared `leaves` helper underneath the two did not quietly widen either.
    func test_thePaletteStashRuleIsUnchanged() {
        XCTAssertTrue(PersonaModifier.clearsPaletteStash(from: .palette, to: .manuscript))
        XCTAssertFalse(PersonaModifier.clearsPaletteStash(from: .palette, to: .palette))
        XCTAssertFalse(PersonaModifier.clearsPaletteStash(from: .canvas, to: .manuscript),
                       "and the canvas is not the palette")
    }
}
