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
    /// This is §8A.3's "never automatic on arriving at the canvas" — you need the
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
    /// update pass. The wall and the canvas are each the subject's `open` now,
    /// so they cannot both be the centre.
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

    // MARK: - Leaving the canvas and coming back

    /// **Collapse on the canvas → open a piece → open the canvas again**,
    /// driven through the SAME fold the window uses, with the route asked of
    /// the subject as `CanvasCollapseModifier` asks it.
    ///
    /// The writer here had already closed the inspector with `⌘⌥I`: leaving the
    /// canvas hands back exactly that, and returning collapses again.
    func test_theCollapseIsGivenBackWhenThePieceTakesTheCentreAndReturnsWithTheCanvas() {
        var window = WindowState(showInspector: false)   // ⌘⌥I, before any of this
        let canvas = SubjectSamples.opened(.canvas)
        let piece = ClickRule.resolve(.item(SubjectSamples.pieceID), gesture: .openInCentre,
                                      current: canvas, structure: SubjectSamples.structure,
                                      projectType: .novel)

        window.foldCollapse(subject: canvas, isNoChromeOn: true)
        XCTAssertEqual(window.columnVisibility, .doubleColumn)
        XCTAssertEqual(window.canvasStash, false, "the closed inspector is what gets remembered")

        window.foldCollapse(subject: piece, isNoChromeOn: true)
        XCTAssertFalse(window.showInspector, "what the writer had is what comes back")
        XCTAssertEqual(window.columnVisibility, .all, "and the binder came back with it")
        XCTAssertNil(window.canvasStash)

        // Focus mode never went off, so the canvas takes the window again.
        window.showInspector = true
        window.foldCollapse(subject: canvas, isNoChromeOn: true)
        XCTAssertEqual(window.columnVisibility, .doubleColumn)
        XCTAssertFalse(window.showInspector)
        XCTAssertEqual(window.canvasStash, true, "and remembers what it found this time")
    }

    /// **The faces moving to a piece is not leaving the canvas**: the collapse
    /// stays.
    func test_theFacesMovingToAPieceKeepsTheCollapse() {
        var window = WindowState(showInspector: true)
        window.foldCollapse(subject: SubjectSamples.opened(.canvas), isNoChromeOn: true)
        let before = window
        window.foldCollapse(subject: WindowSubject(open: .canvas,
                                                   faces: .item(SubjectSamples.pieceID)),
                            isNoChromeOn: true)
        XCTAssertEqual(window, before)
    }

    // MARK: - The wall and the collapse

    /// **The wall, then the canvas, then ⌘\, then ⌘\ again** — the sequence
    /// the two folds can compose in, and the one that says the collapse did
    /// not simply hide the pane everywhere: the writer gets back what they had
    /// **before the wall**, which is the only value that was ever theirs.
    func test_leavingTheCollapseAfterTheWallRestoresWhatTheWriterHad() {
        for priorInspector in [true, false] {
            var window = WindowState(showInspector: priorInspector)
            let piece = SubjectSamples.opened(.item(SubjectSamples.pieceID))
            var wall = piece
            wall = ClickRule.resolve(.palette, gesture: .click, current: wall, structure: SubjectSamples.structure, projectType: .novel)
            window.foldPalette(from: piece, to: wall)
            let canvas = SubjectSamples.opened(.canvas)
            window.foldPalette(from: wall, to: canvas)
            window.foldCollapse(subject: canvas, isNoChromeOn: true)
            window.foldCollapse(subject: canvas, isNoChromeOn: false)   // ⌘\ off
            XCTAssertEqual(window.showInspector, priorInspector)
            XCTAssertEqual(window.columnVisibility, .all)
            XCTAssertNil(window.canvasStash)
        }
    }

    /// And the wall's own rule is unchanged by the extraction: opening stashes
    /// and hides, closing restores and forgets the selected card.
    func test_theWallsOwnRuleStillWorksWithNoCanvasInvolved() {
        var showInspector = true
        var wall = PaletteWallState()
        var card: String? = "card-1"
        let before = SubjectSamples.opened(.item(SubjectSamples.pieceID))
        var open = before
        open = ClickRule.resolve(.palette, gesture: .click, current: open, structure: SubjectSamples.structure, projectType: .novel)
        wall.applyPaletteWallChange(
            from: before, to: open, showInspector: &showInspector,
            selectedPaletteCardId: &card)
        XCTAssertFalse(showInspector)
        XCTAssertEqual(wall.inspectorWasVisibleBefore, true)
        XCTAssertEqual(wall.subjectBeforeWall, before)
        XCTAssertEqual(card, "card-1", "the card survives opening")
        XCTAssertEqual(wall.closingWall(open), before,
                       "the wall's own Close goes back where the writer was")

        wall.applyPaletteWallChange(
            from: open, to: before, showInspector: &showInspector,
            selectedPaletteCardId: &card)
        XCTAssertTrue(showInspector)
        XCTAssertNil(wall.inspectorWasVisibleBefore)
        XCTAssertNil(wall.subjectBeforeWall)
        XCTAssertNil(card, "and is cleared on the way out")
    }

    // The persona-switch release predicate (`PersonaModifier
    // .releasesCanvasCollapse`) and its five tests retired with the personas
    // (shell p1 Task 6): leaving the canvas is a subject change, and
    // `test_leavingTheCanvasWhileCollapsedGivesTheColumnsBack` holds that path.

    /// **Any subject change that takes the wall away restores what the writer
    /// had** — a tree click, a navigation, the wall's own Close: the wall is
    /// `open == .palette`, so there is one transition and one fold. And a
    /// change that keeps the wall open (the faces moving) touches nothing.
    func test_anySubjectChangeLeavingTheWallRestoresTheInspector() {
        for next in SubjectSamples.everySubject where next.open != .palette {
            var showInspector = false
            var card: String? = "card-1"
            var wall = PaletteWallState()
            let before = SubjectSamples.opened(.project)
            var open = before
            open = ClickRule.resolve(.palette, gesture: .click, current: open, structure: SubjectSamples.structure, projectType: .novel)
            showInspector = true
            wall.applyPaletteWallChange(from: before, to: open,
                                        showInspector: &showInspector,
                                        selectedPaletteCardId: &card)
            var facesMoved = open
            facesMoved.faces = .item(SubjectSamples.pieceID)
            wall.applyPaletteWallChange(from: open, to: facesMoved,
                                        showInspector: &showInspector,
                                        selectedPaletteCardId: &card)
            XCTAssertFalse(showInspector, "the wall is still open")
            wall.applyPaletteWallChange(from: facesMoved, to: next,
                                        showInspector: &showInspector,
                                        selectedPaletteCardId: &card)
            XCTAssertTrue(showInspector, "\(next.open): restored")
            XCTAssertNil(wall.inspectorWasVisibleBefore)
        }
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
    /// Both `fold` methods call production's own folds; nothing here mirrors a
    /// rule.
    private struct WindowState: Equatable {
        var columnVisibility: NavigationSplitViewVisibility = .automatic
        var showInspector: Bool
        var canvasStash: Bool?
        var paletteWall = PaletteWallState()
        var selectedPaletteCardId: String?

        /// The route asked of the subject, as `CanvasCollapseModifier` asks it.
        mutating func foldCollapse(subject: WindowSubject, isNoChromeOn: Bool) {
            foldCollapse(route: ProjectWindow.inspectorRoute(subject: subject,
                                                             projectType: .novel),
                         isNoChromeOn: isNoChromeOn)
        }

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

        mutating func foldPalette(from old: WindowSubject, to new: WindowSubject) {
            paletteWall.applyPaletteWallChange(
                from: old, to: new,
                showInspector: &showInspector,
                selectedPaletteCardId: &selectedPaletteCardId)
        }
    }
}
