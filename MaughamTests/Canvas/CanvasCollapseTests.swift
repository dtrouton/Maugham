import XCTest
import SwiftUI
@testable import Maugham
import MaughamCore

/// `⌘\` gives the canvas the whole window (spec §8A.3).
///
/// **The decision is a pure function and it is asked over the whole product of
/// its inputs**, not over the one path this task's brief named. Both of this
/// window's routing bugs were found that way and neither was found by a test
/// written along the happy path — see `CanvasRouteTests`, whose doc comment
/// says so at length about `inspectorRoute`, the very predicate this reuses.
final class CanvasCollapseTests: XCTestCase {

    private let routes: [ProjectWindow.InspectorRoute] = [.canvas, .collectionPiece, .document]
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
    /// The properties are the whole contract — when a collapse may be answered,
    /// when a release may be, which memory a collapse remembers, and that
    /// neither ever names a visibility other than the two this window has a
    /// reason for.
    ///
    /// **A fifth dimension left in stage 2b Task 7**: the palette wall's own
    /// stash, which a collapse used to TAKE OVER when both folds ran in one
    /// update pass. The pass they shared was Plan's picker — palette → canvas
    /// was one click — and the strip is gone, so the wall cannot be open in the
    /// one persona a collapse can happen in.
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
                            XCTAssertEqual(
                                stashed, showInspector,
                                "what is showing is what is kept — \(where_)")
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
    /// and `CanvasCollapseModifier`'s `.onChange(of: persona)` runs in a LATER
    /// pass.
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
        if PersonaModifier.releasesCanvasCollapse(fromPersona: .plan,
                                                  toPersona: .author,
                                                  stash: window.canvasStash) {
            window.canvasStash = nil
            window.columnVisibility = .all
        }
        window.showInspector = true               // the unconditional force-open

        // Pass 3 — CanvasCollapseModifier's .onChange, one pass later.
        window.foldCollapse(route: .document, isNoChromeOn: true)
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

    // MARK: - The wall and the collapse

    // **The order test that stood here died with the state it was about**
    // (stage 2b Task 7). Palette → Canvas used to be ONE CLICK in Plan's
    // picker, so the wall's exit arm and this collapse ran in the SAME update
    // pass in whichever order SwiftUI picked — and collapse-first remembered
    // the wall's forced `false`, leaving the writer a collapsed canvas with the
    // pane still in it and a memory that closed the pane for good on the way
    // out. The fix was the takeover: a collapse took the wall's memory when one
    // was live and said so, and `test_theWallAndCanvasFoldsEndTheSameWayInEither
    // Order` pinned both orders against each other.
    //
    // The wall is `showsPaletteWall` since Task 5, its door is disabled in Plan
    // and `PersonaModifier` force-closes it on the way in — and a collapse
    // needs `route == .canvas`, which is Plan. Task 5 left the takeover dormant
    // because the picker was still there; Task 7 removed the picker, and the
    // branch, the parameter and these two tests went together. The sequence
    // that IS reachable — the wall open in Author, ⌘1, then ⌘\ — is the test
    // below.

    /// **The wall in Author, then ⌘1, then ⌘\, then ⌘\ again** — the sequence
    /// the two folds can still compose in, and the one that says the collapse
    /// did not simply hide the pane everywhere: the writer gets back what they
    /// had **before the wall**, which is the only value that was ever theirs.
    ///
    /// The wall's close here is what `PersonaModifier.clearsPaletteWallStash`
    /// drives on the way into Plan, a whole pass before any collapse.
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

    /// **Every persona pair, and the answer follows the two centre columns.**
    /// Asked over the whole product rather than the one pair that motivated it:
    /// the rule is "a live collapse over a centre that stops being the board",
    /// and a hand-picked pair is the sampling that lets a fifth persona answer
    /// wrong.
    func test_thePredicateFiresExactlyWhenALiveCollapseLeavesTheBoard() {
        for from in Persona.allCases {
            for to in Persona.allCases {
                let leaves = from.centresTheCanvas && !to.centresTheCanvas
                XCTAssertEqual(
                    PersonaModifier.releasesCanvasCollapse(
                        fromPersona: from, toPersona: to, stash: true),
                    leaves, "\(from) → \(to)")
                XCTAssertEqual(
                    PersonaModifier.releasesCanvasCollapse(
                        fromPersona: from, toPersona: to, stash: false),
                    leaves,
                    "\(from) → \(to): a stashed `false` is a live collapse just "
                    + "as much as a `true` — the flag is optionality, not the value")
            }
        }
    }

    /// The control on that loop: it really reaches both answers, so neither
    /// equality above is satisfied by a predicate that returns a constant.
    func test_thePredicateAnswersBothWaysAcrossThePersonaProduct() {
        var fired = 0
        var refused = 0
        for from in Persona.allCases {
            for to in Persona.allCases {
                if PersonaModifier.releasesCanvasCollapse(
                    fromPersona: from, toPersona: to, stash: true) {
                    fired += 1
                } else {
                    refused += 1
                }
            }
        }
        XCTAssertGreaterThan(fired, 0, "no pair leaves the board")
        XCTAssertGreaterThan(refused, 0, "every pair leaves the board")
    }

    func test_thePredicateIsFalseWhenTheCanvasSurvivesTheSwitch() {
        XCTAssertFalse(
            PersonaModifier.releasesCanvasCollapse(
                fromPersona: .plan, toPersona: .plan, stash: true),
            "⌘1 while already in Plan keeps the collapse")
    }

    func test_thePredicateIsFalseWhenNothingWasCollapsed() {
        XCTAssertFalse(
            PersonaModifier.releasesCanvasCollapse(
                fromPersona: .plan, toPersona: .author, stash: nil),
            "a persona switch off an UNCOLLAPSED canvas reopens nothing — the "
            + "writer may have dragged the sidebar shut themselves")
    }

    func test_thePredicateIsFalseWhenTheWriterWasNeverOnTheBoard() {
        XCTAssertFalse(
            PersonaModifier.releasesCanvasCollapse(
                fromPersona: .author, toPersona: .review, stash: true),
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

    // **The `.canvas` ↔ `.tree` flip tests died with the segments** (stage 2b
    // Task 7). Plan offered two left-hand tabs that both drew the board, so a
    // flip between them was not a way off the canvas and a `== .canvas`
    // spelling of the predicate would have handed the sidebar back and then
    // collapsed it again on the next pass — the sidebar moving under the writer
    // twice while the canvas never left the screen. Plan has one left column
    // now, so there is no flip to make and no pair to ask about;
    // `test_thePredicateIsFalseWhenTheCanvasSurvivesTheSwitch` is what the
    // guarantee reduces to.

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
                                             stash: canvasStash),
                columnVisibility: &columnVisibility,
                showInspector: &showInspector,
                stash: &canvasStash)
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
