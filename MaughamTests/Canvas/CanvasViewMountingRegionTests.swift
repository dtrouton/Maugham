import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// The mounted canvas's STRUCTURE: sweeping a region and binding it, what a
/// move, a resize or a drop does to membership (tripwire 31, on the delivery
/// path), and the lines drawn between cards. Harness in
/// `CanvasViewMountingCase`.
final class CanvasViewMountingRegionTests: CanvasViewMountingCase {

    // MARK: - Regions, through the real event view

    /// **The other half of `CanvasRegionInteractionTests`, and the half that
    /// would have caught both of 1C-a's shipped defects.** That file drives the
    /// state machine directly; these four drive a real `CanvasEventNSView`
    /// through the same `mouseDown`/`mouseDragged`/`mouseUp` seam the AppKit
    /// overrides call, and assert on what reached disk through the real
    /// debounced save. A gesture that never reaches `handleDrag`, or a routing
    /// change that sends it somewhere else, is invisible to the state machine's
    /// own tests and fails here.
    ///
    /// `pumpUntilSaved()`, not `waitOut`: the save debounce is itself a
    /// scheduled run-loop source, so pumping against "nothing pending" really
    /// does wait for it — and nothing below turns on wall clock elapsing with
    /// the loop empty, which is the one thing `waitOut` is for.
    func test_aDragOnBareCanvasDrawsARegionThatReachesDisk() throws {
        let root = try projectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 400, y: 300),
             through: [CGPoint(x: 600, y: 460), CGPoint(x: 600, y: 460)])
        pumpUntilSaved()

        let regions = sceneOnDisk(root).regions
        XCTAssertEqual(regions.count, 1,
                       "a drag on bare canvas made no region: 1C-a documents an "
                       + "empty-canvas drag as a no-op, so nothing but this task's "
                       + "wiring can turn it into the create gesture")
        XCTAssertEqual(regions.first?.frame.width, 200)
        XCTAssertEqual(regions.first?.frame.height, 160)
        XCTAssertTrue(regions.first!.homeMembers.isEmpty,
                      "a sweep over BARE canvas took something in. The fixture's "
                      + "card is (20,20)–(260,58) with its centre at (140,39) and "
                      + "this rect starts at (400,300), so there was nothing to "
                      + "absorb — the absorbing case is the test below")
        XCTAssertEqual(model.selection, .region(regions.first!.id),
                       "the region the writer just drew is not selected, so the "
                       + "inspector in the other column has nothing to name it with")
    }

    /// **Creation absorbs, on the delivery path** (Denver, 2026-07-28) — and one
    /// ⌘Z takes back the region and every membership it made, as ONE step.
    ///
    /// The step's NAME is asserted, not only the scene after the undo: a scene
    /// assertion alone cannot tell one step from two that happen to compose, and
    /// two would leave a ⌘Z that appears to do nothing. `canUndo` going false
    /// afterwards is the other half of the same claim — the stack held exactly
    /// one thing.
    func test_sweepingAroundACardTakesItInAndOneUndoTakesBackBoth() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertFalse(manager.canUndo, "precondition: nothing on the stack yet")

        // The fixture's card is (20,20)–(260,58), centre (140,39). Sweep from
        // bare canvas below-left of it, up and around it — backwards and
        // upwards, so this also drives the normalised rect on the real path.
        drag(events, from: CGPoint(x: 320, y: 240),
             through: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)])
        pumpUntilSaved()

        let region = try XCTUnwrap(sceneOnDisk(root).regions.first,
                                   "the sweep made no region at all")
        XCTAssertTrue(region.livesHere(scrapID),
                      "the writer drew a box around a card and the card did not "
                      + "join it — creation absorbs (2026-07-28); it is move and "
                      + "resize that change nothing")

        XCTAssertTrue(manager.canUndo)
        XCTAssertTrue(manager.undoMenuItemTitle.contains("New Region"),
                      "the Edit menu offers \"\(manager.undoMenuItemTitle)\" — the "
                      + "absorption was registered under some other name, or in a "
                      + "bracket of its own")
        manager.undo()
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 0, "⌘Z left the region behind")
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 20, y: 20),
                       "the card was moved by a gesture that only drew a box "
                       + "around it")
        XCTAssertFalse(manager.canUndo,
                       "a second step is on the stack, so the region and the "
                       + "membership it created were TWO ⌘Zs — the writer presses "
                       + "it once, sees the box go, presses it again expecting "
                       + "their last edit back and instead re-runs a membership "
                       + "change they cannot see")
    }

    // MARK: - §4.1's invariant: while the board is dimmed, a sweep binds

    /// **The whole of slice 3's mode, on the delivery path** (spec §4.1): the
    /// tree names a chapter, the board dims, and the region the writer sweeps is
    /// already bound to that chapter when they let go.
    ///
    /// The card the sweep took in is asserted as well as the binding, because the
    /// two together are what the writer sees: a lit region holding lit cards.
    /// `CanvasHighlight.resolve` is asked of the scene that reached DISK rather
    /// than of the live view's private cache — what it proves is that the sweep
    /// left behind a scene the dim will light, which is the half a binding
    /// written in the wrong place would still get right and a binding written
    /// nowhere would not.
    func test_aSweptRegionBindsToTheDocumentTheTreeNames() throws {
        let root = try projectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1")))
        let events = try eventView(in: window)
        let revisionBefore = model.sceneRevision

        // Around the fixture's card at (20,20)–(260,58), centre (140,39).
        drag(events, from: CGPoint(x: 320, y: 240),
             through: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        let region = try XCTUnwrap(onDisk.regions.first, "the sweep made no region at all")
        XCTAssertEqual(region.boundPieceID, "ch1",
                       "the board was dimmed to a chapter and the region the writer "
                       + "swept came back unbound — §4.1's invariant is the whole "
                       + "mode: while anything is dimmed a sweep binds, and there is "
                       + "no second signal on screen saying whether it will")
        XCTAssertTrue(region.livesHere(scrapID), "precondition: creation still absorbs")

        let lit = CanvasHighlight.resolve(subject: .piece("ch1"), in: onDisk)
        XCTAssertTrue(lit.regions.contains(region.id),
                      "the region the writer just bound is not in that chapter's lit "
                      + "set, so it draws dimmed on a board dimmed to it")
        XCTAssertTrue(lit.nodes.contains(scrapID),
                      "the card the sweep took in is not lit — a bound region's "
                      + "residents ARE the piece's context (§4)")
        XCTAssertGreaterThan(model.sceneRevision, revisionBefore,
                             "the structural counter did not move, so the cached lit "
                             + "set is never rebuilt and the new region stays dim "
                             + "until something unrelated happens to bump it")
    }

    /// **One ⌘Z takes back the whole act — in BOTH of the sweep's shapes.**
    ///
    /// `canUndo` going false afterwards is the assertion that matters: a bind
    /// written outside `handleDrag`'s open bracket — through `mutate`, or through
    /// the inspector's verb, or after `endGesture` — leaves a SECOND step on the
    /// stack. The writer presses ⌘Z once, watches the box go, presses it again
    /// expecting their last sentence back, and re-runs a binding change nothing
    /// on screen can show them.
    ///
    /// **Both shapes are here rather than in two tests** (§4.1's assign case,
    /// added 2026-08-03) because they are one gesture with one rule, and a
    /// parallel test is what lets a fix to one of them quietly stop covering the
    /// other. The board this runs on already has a region and a resident card, so
    /// shape one sweeps bare canvas clear of it and shape two sweeps across it.
    ///
    /// The Edit menu is read in both, and it says something different in each:
    /// the bracket is named "New Region" at `.began`, before the sweep's answer
    /// exists, so an assign that left that name would offer *Undo New Region* for
    /// a gesture that made nothing.
    func test_oneUndoTakesBackTheSweptRegionAndItsBindingTogether() throws {
        let root = try arrangedBoardRoot()
        let existing = CanvasRegionID("r1")
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1")))
        let events = try eventView(in: window)
        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertFalse(manager.canUndo, "precondition: nothing on the stack yet")

        // --- Shape one: the sweep MINTED. Bare canvas above and left of r1.
        drag(events, from: CGPoint(x: 320, y: 240),
             through: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)])
        pumpUntilSaved()
        let afterMint = sceneOnDisk(root)
        XCTAssertEqual(afterMint.regionCount, 2, "precondition: the sweep minted")
        let minted = try XCTUnwrap(afterMint.unorderedRegions.first { $0.id != existing })
        XCTAssertEqual(minted.boundPieceID, "ch1", "precondition: the sweep bound")
        XCTAssertTrue(manager.undoMenuItemTitle.contains("New Region"),
                      "the Edit menu offers \"\(manager.undoMenuItemTitle)\" — the "
                      + "binding was registered under a name of its own, so it is "
                      + "not part of the gesture the writer made")

        manager.undo()
        pumpUntilSaved()

        XCTAssertEqual(sceneOnDisk(root).regionCount, 1, "⌘Z left the region behind")
        XCTAssertFalse(manager.canUndo,
                       "a second step is on the stack: the region and the binding "
                       + "were TWO ⌘Zs")

        // --- Shape two: the sweep ASSIGNED, across r1's centre at (400,375).
        drag(events, from: CGPoint(x: 280, y: 280),
             through: [CGPoint(x: 600, y: 500), CGPoint(x: 600, y: 500)])
        pumpUntilSaved()
        XCTAssertEqual(sceneOnDisk(root).region(existing)?.boundPieceID, "ch1",
                       "precondition: the sweep bound what it caught")
        XCTAssertTrue(manager.undoMenuItemTitle.contains("Bind Region"),
                      "the Edit menu offers \"\(manager.undoMenuItemTitle)\" for a "
                      + "gesture that created nothing — the bracket kept the name it "
                      + "was given before the sweep's answer existed")

        manager.undo()
        pumpUntilSaved()

        let afterUndo = sceneOnDisk(root)
        XCTAssertEqual(afterUndo.regionCount, 1,
                       "the undo of an assign took a region away — the assign made "
                       + "none, so it has none to take back")
        XCTAssertNil(try XCTUnwrap(afterUndo.region(existing)).boundPieceID,
                     "⌘Z left the binding behind")
        XCTAssertFalse(manager.canUndo,
                       "a second step is on the stack: binding what the sweep caught "
                       + "is ONE act, and several regions bound at once are one too")
    }

    /// The second half of the invariant, and it is what keeps the mode legible:
    /// **on an undimmed board a sweep is just a sweep.** The project row is the
    /// way out of the dim (§4), so this is also what the way out is FOR.
    func test_aSweepOnAnUndimmedBoardBindsNothing() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .wholeProject))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 320, y: 240),
             through: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)])
        pumpUntilSaved()

        let region = try XCTUnwrap(sceneOnDisk(root).regions.first)
        XCTAssertNil(region.boundPieceID,
                     "a sweep on the whole board bound itself to something: the dim "
                     + "IS the mode indicator, so binding without one makes the "
                     + "binding invisible at the moment it happens")
    }

    /// **A group makes a PLAIN region** (§4.1) — the one deliberate exception to
    /// the invariant. A dimmed board with Part One selected says *"here is
    /// everything under Part One"*, not *"put something here"*, and there is
    /// nothing a sweep could bind to: a `boundPieceID` only ever holds a document
    /// id, and picking one of the group's children would be the canvas guessing.
    func test_aSweepWithAGroupSelectedMakesAPlainRegion() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .group(["ch1", "ch2"])))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 320, y: 240),
             through: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)])
        pumpUntilSaved()

        let region = try XCTUnwrap(sceneOnDisk(root).regions.first)
        XCTAssertNil(region.boundPieceID,
                     "a sweep under a GROUP bound the region to one of the group's "
                     + "chapters — the canvas picked a piece the writer never named")
    }

    /// **A second sweep binds too**, and nothing downstream needs teaching: the
    /// projection already unions across regions, so both regions' residents are
    /// one piece's context.
    func test_aSecondSweepBindsToTheSameDocument() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1")))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 320, y: 240),
             through: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)])
        pump(0.3)
        drag(events, from: CGPoint(x: 420, y: 300),
             through: [CGPoint(x: 700, y: 500), CGPoint(x: 700, y: 500)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 2, "precondition: two sweeps, two regions")
        XCTAssertEqual(onDisk.unorderedRegions.filter { $0.boundPieceID == "ch1" }.count, 2,
                       "the second sweep did not bind — a chapter's context is every "
                       + "region bound to it, not the first one the writer drew")
    }

    // MARK: - §4.1's assign case: a sweep that catches regions binds them

    /// **The smoke finding, 2026-08-03, on the delivery path.** Denver, sweeping
    /// across a board that already had regions on it: *"my issue is it creates a
    /// new region which is pointless and a horrible user experience… it literally
    /// makes zero sense as a user experience."*
    ///
    /// §4.1's ruling is one formula used twice — the sweep asks the centre
    /// question of everything it passes over, **regions included** — and every
    /// assertion here is a different way of saying "nothing was created":
    ///
    /// - the region COUNT, which is the third rectangle laid over the other two;
    /// - the resident card's home, which a minted region would have stolen by
    ///   absorption (*"nothing is stolen"*);
    /// - the loose card, which a minted region would have taken in.
    ///
    /// And the last pair is the acceptance criterion rather than a nicety: the
    /// bound area **undims within the same gesture**. The lit set is rebuilt from
    /// `sceneRevision`, so a bind that does not bump it leaves the region the
    /// writer just claimed dim until something unrelated moves.
    func test_aSweepAcrossExistingRegionsBindsThemAndCreatesNothing() throws {
        let root = try arrangedBoardRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1")))
        let events = try eventView(in: window)
        let revisionBefore = model.sceneRevision

        drag(events, from: CGPoint(x: 280, y: 280),
             through: [CGPoint(x: 600, y: 500), CGPoint(x: 600, y: 500)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 1,
                       "the sweep minted a region over the one it passed over — "
                       + "§4.1: when the sweep catches a region, that region binds "
                       + "and nothing is created")
        let r1 = try XCTUnwrap(onDisk.region(CanvasRegionID("r1")),
                               "the region the writer already had is gone")
        XCTAssertEqual(r1.boundPieceID, "ch1",
                       "the sweep caught this region's centre and did not bind it")
        XCTAssertTrue(r1.livesHere(scrapID),
                      "the card was stolen out of the region it lived in — the "
                      + "assign path touches no membership at all")
        XCTAssertNil(CanvasMembership.homeRegion(of: secondScrapID, in: onDisk),
                     "a loose card inside the swept rect was absorbed, so something "
                     + "was created after all")

        let lit = CanvasHighlight.resolve(subject: .piece("ch1"), in: onDisk)
        XCTAssertTrue(lit.regions.contains(r1.id),
                      "the region the writer just bound is not in that chapter's lit "
                      + "set, so it draws dimmed on a board dimmed to it")
        XCTAssertTrue(lit.nodes.contains(scrapID),
                      "the bound region's resident is not lit — a bound region's "
                      + "residents ARE the piece's context (§4)")
        XCTAssertGreaterThan(model.sceneRevision, revisionBefore,
                             "the structural counter did not move on a sweep that "
                             + "bound without minting, so the cached lit set is never "
                             + "rebuilt and the area the writer just claimed stays "
                             + "dim until something unrelated bumps it")
    }

    /// **Several regions at once, and it is ONE act** (§4.1) — because the sweep
    /// asked one question of everything it passed over.
    func test_aSweepAcrossTwoRegionsBindsBothAsOneStep() throws {
        let root = try twoRegionBoardRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1")))
        let events = try eventView(in: window)
        let manager = try XCTUnwrap(events.undoManager)

        drag(events, from: CGPoint(x: 60, y: 60),
             through: [CGPoint(x: 760, y: 560), CGPoint(x: 760, y: 560)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 2, "the sweep minted a third region")
        XCTAssertEqual(onDisk.unorderedRegions.filter { $0.boundPieceID == "ch1" }.count, 2,
                       "the sweep bound only some of what it passed over, so the "
                       + "board came back part lit and part dim with nothing to say "
                       + "which")
        XCTAssertTrue(manager.undoMenuItemTitle.contains("Bind Regions"),
                      "the Edit menu offers \"\(manager.undoMenuItemTitle)\" for two "
                      + "regions")

        manager.undo()
        pumpUntilSaved()
        XCTAssertEqual(sceneOnDisk(root).unorderedRegions.filter { $0.boundPieceID != nil }.count, 0,
                       "one ⌘Z took back only one of the bindings")
        XCTAssertFalse(manager.canUndo,
                       "binding two regions cost two ⌘Zs — it is one act of the "
                       + "writer's and one step on the stack")
    }

    /// **The undimmed board is untouched** (§4.1), on the delivery path: with
    /// nothing selected there is nothing to bind, so a sweep across a region is a
    /// plain region draw and the assign path does not leak into it.
    ///
    /// The resident card DOES move into the new region here, and that is the
    /// 2026-07-28 creation-absorbs ruling working as designed rather than the
    /// stealing §4.1 removed — something was created, so it absorbs.
    func test_aSweepAcrossARegionOnAnUndimmedBoardStillDrawsANewOne() throws {
        let root = try arrangedBoardRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .wholeProject))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 280, y: 280),
             through: [CGPoint(x: 600, y: 500), CGPoint(x: 600, y: 500)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 2,
                       "a sweep on the project row drew no region — the assign path "
                       + "leaked onto an undimmed board, where there is nothing to "
                       + "bind and a sweep is just a sweep")
        XCTAssertNil(try XCTUnwrap(onDisk.region(CanvasRegionID("r1"))).boundPieceID,
                     "a sweep on the whole board bound something: the dim IS the "
                     + "mode indicator, so binding without one is invisible at the "
                     + "moment it happens")
    }

    /// **A group still makes a plain region** (§4.1's one deliberate exception),
    /// and it holds over a region as well as over bare canvas — a dimmed board
    /// with Part One selected says *"here is everything under Part One"*, not
    /// *"put something here"*, and a `boundPieceID` holds a document id.
    func test_aSweepAcrossARegionWithAGroupSelectedStillDrawsANewOne() throws {
        let root = try arrangedBoardRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .group(["ch1", "ch2"])))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 280, y: 280),
             through: [CGPoint(x: 600, y: 500), CGPoint(x: 600, y: 500)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 2,
                       "a sweep under a GROUP took the assign path — the dim there "
                       + "means \"here is everything beneath this\", and there is "
                       + "nothing a sweep could bind to")
        XCTAssertNil(try XCTUnwrap(onDisk.region(CanvasRegionID("r1"))).boundPieceID,
                     "a sweep under a GROUP bound a region to one of the group's "
                     + "chapters — the canvas picked a piece the writer never named")
    }

    /// **A sweep never re-binds, and a sweep that can bind nothing creates
    /// nothing** (Denver, 2026-08-03) — the ruling, on the delivery path.
    /// `CanvasRegionInteractionTests` carries the argument and the sub-cases.
    ///
    /// The region-count assertion is the one that matters here rather than a
    /// tidy-up: *"I caught no bindable region"* is not *"I caught no region"*,
    /// and a sweep that fell through to the create arm would lay a fresh
    /// rectangle over the board that produced the finding in the first place —
    /// the defect arriving through its own fix.
    ///
    /// `canUndo` is the third assertion because the gesture must cost the writer
    /// nothing at all: an act that changed no part of the scene must leave no
    /// step behind for a later ⌘Z to spend itself on.
    func test_aSweepCatchingOnlyAnAlreadyBoundRegionDoesNothingAtAll() throws {
        let root = try arrangedBoardRoot(bound: "ch2")
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1")))
        let events = try eventView(in: window)
        let manager = try XCTUnwrap(events.undoManager)

        drag(events, from: CGPoint(x: 280, y: 280),
             through: [CGPoint(x: 600, y: 500), CGPoint(x: 600, y: 500)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 1,
                       "the sweep could bind nothing and minted a region instead — "
                       + "\"I caught no bindable region\" is not \"I caught no "
                       + "region\", and this is the finding arriving through its "
                       + "own fix")
        XCTAssertEqual(try XCTUnwrap(onDisk.region(CanvasRegionID("r1"))).boundPieceID,
                       "ch2",
                       "the sweep took a region away from the document it was "
                       + "already bound to — moving a binding is the Piece picker's "
                       + "job, and a sweep cannot express the \"no\" that undoes it")
        XCTAssertTrue(try XCTUnwrap(onDisk.region(CanvasRegionID("r1"))).livesHere(scrapID),
                      "a card moved on a gesture that was supposed to change nothing")
        XCTAssertFalse(manager.canUndo,
                       "a gesture that changed no part of the scene left a step on "
                       + "the stack, so the writer's next ⌘Z appears to do nothing")
    }

    // MARK: - The standing offer (§4's third row)

    /// **The offer is really on screen**, read in pixels — which is the only
    /// instrument available: which arm of a `_ConditionalContent` renders cannot
    /// be asserted, and a `Text` in an `NSHostingView` is not a view a
    /// descendant walk can find. `CanvasBindingOfferTests` owns the RULE; this
    /// owns "anything mounts it, and nothing draws over it".
    ///
    /// It also owns **standing-ness**: the second reading is taken a second of
    /// wall clock later, which is where a self-dismissing notification would
    /// already have gone. The offer is state-derived and has nowhere to keep a
    /// timer, so this is belt and braces — but it is the assertion that fails if
    /// somebody later gives it one (§4.1, constitution: nothing is pushed).
    func test_theStandingOfferIsOnScreenForADocumentWithNothingBound() throws {
        let root = try emptyProjectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .piece("ch1")))
        let hosted = try XCTUnwrap(window.contentView)
        pump(0.3)

        // The middle of the 800×600 stack, where centred chrome lands. The
        // canvas is empty, so anything found here is the offer.
        let middle = CGRect(x: 180, y: 265, width: 440, height: 70)
        XCTAssertGreaterThan(try ink(in: middle, of: hosted), 0,
                             "a chapter with nothing bound dims the whole board and "
                             + "the canvas says nothing at all — the one state where "
                             + "a dim reads as a dead end (§4)")

        // Long enough to outlive any auto-dismiss a regression could plant —
        // every timer the canvas schedules under the test clocks has fired by
        // 0.3 s — without holding the suite for a full second of stillness.
        waitOut(0.3)
        XCTAssertGreaterThan(try ink(in: middle, of: hosted), 0,
                             "the offer went away on its own: it is STANDING chrome "
                             + "and the state it belongs to has not changed, so a "
                             + "writer who looked away has lost it for good")
    }

    /// The control, and it is half of what makes the reading above mean
    /// anything: the same box is bare on the project row. The offer is not
    /// canvas furniture.
    func test_theStandingOfferIsAbsentOnTheProjectRow() throws {
        let root = try emptyProjectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .wholeProject))
        let hosted = try XCTUnwrap(window.contentView)
        pump(0.3)
        XCTAssertEqual(try ink(in: CGRect(x: 180, y: 265, width: 440, height: 70),
                               of: hosted), 0,
                       "the canvas offers to bind a region while the whole board is "
                       + "undimmed — the offer belongs to one state and is standing "
                       + "furniture otherwise")
    }

    /// **§4.1's group ruling, at the pixels.** `CanvasHighlight.litNothing` is
    /// true here — nothing under the group is bound — so a mount that read one
    /// signal instead of two would draw the offer, and only the second signal
    /// stops it. The rule is unit-tested; this is the half that proves the VIEW
    /// asks for both.
    func test_theStandingOfferIsAbsentUnderAGroup() throws {
        let root = try emptyProjectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] },
                                     subject: .group(["ch1", "ch2"])))
        let hosted = try XCTUnwrap(window.contentView)
        pump(0.3)
        XCTAssertEqual(try ink(in: CGRect(x: 180, y: 265, width: 440, height: 70),
                               of: hosted), 0,
                       "the offer appeared under a group — a sweep there makes a "
                       + "PLAIN region, so the offer promises something the gesture "
                       + "does not do")
    }

    /// **A scrap made inside a region belongs to it**, on the delivery path.
    ///
    /// The double-click is the create gesture, so this is the second half of the
    /// 2026-07-28 ruling — and the ordering it depends on is invisible from
    /// outside: a new scrap has no measured height until `rebuildLayouts()`, so
    /// asking `joinTarget` one line earlier reads a card with no frame and joins
    /// nothing, on every scrap the writer ever makes.
    func test_aScrapMadeInsideARegionJoinsIt() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // Inside the region (20,20)–(420,300) and clear of its resident card at
        // (60,60)–(300,98), so this is bare canvas *within* the region.
        events.applyMouseDown(at: CGPoint(x: 60, y: 150), clickCount: 2)
        pump(0.3)
        type("Rain.", into: try XCTUnwrap(
            try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                          "the double-click made no scrap").textView))
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.count, 2, "precondition: the new scrap exists")
        let made = try XCTUnwrap(onDisk.unorderedNodes.first { $0.id != scrapID }).id
        XCTAssertTrue(onDisk.region(CanvasRegionID("r1"))!.livesHere(made),
                      "a scrap made inside a region did not join it — the likeliest "
                      + "cause is asking joinTarget before rebuildLayouts(), where "
                      + "the new card has no frame and so has no centre")
    }

    /// **The half that did NOT change, asked on the delivery path.** Creation
    /// absorbs; a MOVE still takes nothing in, and neither does a resize.
    ///
    /// This is the property most at risk from the 2026-07-28 ruling: the obvious
    /// way to implement absorption is a rule in `setRegionFrame`, which would
    /// pass every creation test here and quietly hand tldraw's, Obsidian's and
    /// Scapple's bugs back at once.
    func test_draggingARegionOverACardStillTakesNothingIn() throws {
        // The card at (20,20)–(260,58); the region starts clear of it, down and
        // to the right, and is dragged up over it.
        let root = try cardAndRegionRoot(regionFrame: CGRect(x: 300, y: 200,
                                                             width: 300, height: 200))
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Grab the chrome bar at (400,210) — grab offset (100,10) — and carry
        // the region to the origin, where it covers the card entirely.
        drag(events, from: CGPoint(x: 400, y: 210),
             through: [CGPoint(x: 100, y: 10), CGPoint(x: 100, y: 10)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        let region = try XCTUnwrap(onDisk.region(CanvasRegionID("r1")))
        XCTAssertEqual(region.frame.origin, CGPoint(x: 0, y: 0),
                       "precondition: the drag landed where this test needs it")
        XCTAssertTrue(region.frame.contains(onDisk.node(scrapID)!.frame!),
                      "precondition: the region was dragged clean over the card")
        XCTAssertFalse(region.livesHere(scrapID),
                       "a region dragged over a card absorbed it — §4.2's firewall "
                       + "still holds for TRANSITIONS, which is the half all three "
                       + "of the tools it cites were bitten on")
    }

    /// The other transition, and the one with a shipped bug behind it: tldraw
    /// #6017 ejected children on resize. This is the same rule from the opposite
    /// side — growing a region over a card must not take it in either.
    func test_resizingARegionOverACardStillTakesNothingIn() throws {
        // A small region at the origin, up and to the left of the card, so
        // growing its bottom-right corner sweeps it over the card's centre.
        let root = try cardAndRegionRoot(regionFrame: CGRect(x: 0, y: 0,
                                                             width: 100, height: 100))
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // The corner square is (86,86)–(100,100), which is below the card's
        // bottom edge at y 58, so the press reaches the region rather than the
        // card that overlaps its chrome.
        drag(events, from: CGPoint(x: 94, y: 94),
             through: [CGPoint(x: 300, y: 200), CGPoint(x: 300, y: 200)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        let region = try XCTUnwrap(onDisk.region(CanvasRegionID("r1")))
        XCTAssertEqual(region.frame, CGRect(x: 0, y: 0, width: 306, height: 206),
                       "precondition: the corner really was dragged out — a resize "
                       + "holds the origin and moves the far corner")
        XCTAssertTrue(region.frame.contains(onDisk.node(scrapID)!.frame!),
                      "precondition: and the region now covers the card entirely")
        XCTAssertFalse(region.livesHere(scrapID),
                       "a resized region absorbed a card — creation absorbs and "
                       + "transitions do not, and a resize that changes membership "
                       + "is tldraw #6017 with the sign flipped")
    }

    /// **The rubber band is on screen for the WHOLE sweep, not after it.**
    ///
    /// This is the shape of 1C-a's resize defect asked of the new gesture: every
    /// other assertion about drawing a region looks after `.ended`, and the
    /// middle of the gesture is the only part the writer actually steers by.
    /// With nothing drawn there is no way to tell a drag that is sweeping out a
    /// region from a drag that is doing nothing.
    ///
    /// Read in PIXELS because there is nothing else to read: the sweep is not in
    /// the model at all — it lives in `CanvasInteraction`, has no view, no frame
    /// and no accessibility element — so `CanvasRegionRenderTests` can pin the
    /// renderer and only this can pin that anything ever hands it the rect.
    ///
    /// **It does NOT cover the `revision` counter, and an earlier draft of this
    /// comment claimed it did.** Measured: deleting `revision += 1` from
    /// `handleDrag(.changed)` leaves this test and all its neighbours green.
    /// `.changed` mutates `interaction`, which is `@State`, so the mutation is
    /// itself an invalidation and the redraw arrives either way. The band was
    /// never a client of that counter in the first place — `CanvasView` reads it
    /// in `body` and passes it as a view ARGUMENT, so it is recomputed on any
    /// invalidated pass. Nothing here can pin the counter; do not write that it
    /// does.
    func test_theSweptRegionOutlineIsOnScreenForTheWholeDrag() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // A strip along where the sweep's LEFT edge will run — bare ground now,
        // and well clear of the fixture's card at (20,20)–(260,58) and of the
        // corner `ink` samples the ground brightness from.
        let onTheEdge = CGRect(x: 148, y: 220, width: 6, height: 80)
        XCTAssertEqual(try ink(in: onTheEdge, of: hosted), 0,
                       "precondition: nothing is drawn along this line yet, so ink "
                       + "found there during the drag can only be the sweep")

        // Press on bare canvas and drag out a 300×200 rect — and DO NOT release.
        // This is the state the writer steers by, and the state nothing else in
        // this file ever looks at.
        events.applyMouseDown(at: CGPoint(x: 150, y: 150), clickCount: 1)
        events.applyMouseDragged(to: CGPoint(x: 450, y: 350))
        pump(0.05)

        XCTAssertGreaterThan(try ink(in: onTheEdge, of: hosted), 0,
                             "the writer is sweeping out a region and the canvas shows "
                             + "nothing at all until they let go — a gesture with no "
                             + "feedback is indistinguishable from a gesture that is "
                             + "not happening")

        // …and it is GONE once the region exists, replaced by the region's own
        // outline. A band that outlived its gesture would leave a dashed ghost
        // on the canvas for the rest of the session.
        events.applyMouseUp(at: CGPoint(x: 450, y: 350))
        pumpUntilSaved()
        XCTAssertEqual(sceneOnDisk(root).regionCount, 1,
                       "precondition: the sweep really did make a region")
    }

    func test_draggingARegionByItsLabelBarCarriesItsResidentToDisk() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Onto the chrome bar, then 100pt right and 40pt down.
        drag(events, from: CGPoint(x: 200, y: 30),
             through: [CGPoint(x: 300, y: 70), CGPoint(x: 300, y: 70)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.frame.origin,
                       CGPoint(x: 120, y: 60))
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 160, y: 100),
                       "the resident travelled — through the real event view, the "
                       + "real gesture routing and the real debounced save")
    }

    /// **A region resize, through the real event view, asserted DURING the drag
    /// as well as after it.**
    ///
    /// Every other region test here drives a move or a sweep, so nothing proved
    /// that a press in a region's corner square is routed to `.resizingRegion`
    /// at all. And 1C-a's shipped defect was precisely a resize whose every test
    /// asserted after `.ended` — the card was gone for the whole gesture and the
    /// suite was green. That is the one shape this slice cannot afford to leave
    /// unasked of a new gesture.
    ///
    /// The fixture's region is (20,20)–(420,320), so its corner square is
    /// (406,306)–(420,320); the drag adds 200pt on each axis.
    func test_resizingARegionByItsCornerKeepsItDrawnAndReachesDisk() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // A strip across where the region's RIGHT edge will land. Bare ground
        // now — the region ends at x = 420 — and the outline is what will cross
        // it. The region's own wash is far below `ink`'s threshold, so what this
        // counts is the stroke.
        let newEdge = CGRect(x: 617, y: 380, width: 6, height: 80)
        XCTAssertEqual(try ink(in: newEdge, of: hosted), 0,
                       "precondition: nothing is drawn out here yet, so ink found "
                       + "during the drag can only be the region having grown")

        events.applyMouseDown(at: CGPoint(x: 414, y: 314), clickCount: 1)
        events.applyMouseDragged(to: CGPoint(x: 614, y: 514))
        pump(0.05)

        XCTAssertGreaterThan(try ink(in: newEdge, of: hosted), 0,
                             "the region is not drawn at its new size while the "
                             + "writer is dragging its corner — a region that only "
                             + "resizes on release tells the writer nothing about "
                             + "the size they are choosing, which is the 1C-a resize "
                             + "defect in a second place")

        events.applyMouseUp(at: CGPoint(x: 614, y: 514))
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.frame,
                       CGRect(x: 20, y: 20, width: 600, height: 500),
                       "the resized frame did not reach disk — the likeliest cause "
                       + "is a corner press being routed to a MOVE, which would "
                       + "have shifted the origin instead")
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 60, y: 60),
                       "resizing a region dragged its residents along with it: only "
                       + "a MOVE carries the cards, and a resize that moves them "
                       + "rearranges the writer's canvas behind their back")
        XCTAssertTrue(onDisk.region(CanvasRegionID("r1"))!.livesHere(scrapID),
                      "the resize ejected its resident — tldraw #6017, which §4.2 "
                      + "exists to make impossible")
    }

    /// **Dropping a card outside every region does NOT take it out of its home**
    /// (§4.2: removal is always its own act), and the tether is what makes the
    /// resulting state legible.
    ///
    /// `CanvasRegionInteractionTests` asks this of `joinTarget`, which is a pure
    /// query with no removal in it to omit — so that assertion cannot fail for
    /// the reason it gives. The real constraint is the ABSENCE of an `else`
    /// beside the join in `handleDrag(.ended)`, and nothing would notice one
    /// being added. This is what notices.
    func test_draggingAResidentOutOfItsRegionLeavesItAMemberAndTethered() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Grab the card at (100,80) — on it, clear of its resize corner — and
        // carry it out to the right of the region, which ends at x = 420.
        drag(events, from: CGPoint(x: 100, y: 80),
             through: [CGPoint(x: 700, y: 80), CGPoint(x: 700, y: 80)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 660, y: 60),
                       "precondition: the card really was carried out of the region")
        XCTAssertFalse(onDisk.region(CanvasRegionID("r1"))!.frame
                        .intersects(onDisk.node(scrapID)!.frame!),
                       "precondition: and it is entirely outside it now")
        XCTAssertTrue(onDisk.region(CanvasRegionID("r1"))!.livesHere(scrapID),
                      "dragging a card out of its region silently took it out of "
                      + "the region: removal is its own act (§4.2), and a drop that "
                      + "quietly unmakes a relationship is how a writer loses track "
                      + "of what belongs where")
        XCTAssertEqual(CanvasRenderer.tethers(in: onDisk).map(\.node), [scrapID],
                       "the card is a member sitting outside its region and no "
                       + "tether explains why — which is the only thing that makes "
                       + "this state readable rather than a bug")
    }

    func test_oneUndoTakesBackARegionDragAndTheCardsItCarried() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 200, y: 30),
             through: [CGPoint(x: 300, y: 70), CGPoint(x: 300, y: 70)])
        pumpUntilSaved()
        XCTAssertEqual(sceneOnDisk(root).node(scrapID)?.origin, CGPoint(x: 160, y: 100),
                       "precondition: the drag really happened")

        // What a click on bare canvas does. The testable seam `drag` goes
        // through does no event-level responder work — synthesizing `NSEvent`s
        // is unreliable, see `CanvasEventNSView` — so the claim
        // `mouseDown(with:)` makes is made here in its place. Without it the
        // chain walk below starts at the window, finds `NSWindow.undo:`, and
        // measures the window's stack rather than the canvas's.
        XCTAssertTrue(window.makeFirstResponder(events))

        let undo = try editMenuItem(#selector(CanvasEventNSView.undo(_:)), in: window)
        XCTAssertTrue(undo.isEnabled,
                      "a ⌘Z the Edit menu greys out is a feature the writer cannot reach")
        XCTAssertTrue(undo.item.title.contains("Move Region"),
                      "the menu item reads \"\(undo.item.title)\" rather than naming the "
                      + "gesture it will take back — a region drag opened a bracket "
                      + "under some other gesture's name")
        _ = undo.target.perform(undo.item.action, with: undo.item)
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.frame.origin, CGPoint(x: 20, y: 20))
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 60, y: 60),
                       "one ⌘Z takes back the frame AND every resident it carried — "
                       + "which is why the recorder snapshots the scene rather than "
                       + "inverting properties")
    }

    /// **The PREMISE under the region inspector's gate, which nothing pinned.**
    ///
    /// `RegionInspector`'s member lists and its "Cite a Card" offer are rebuilt
    /// only when `(CanvasModel.sceneRevision, regionID)` moves, and
    /// `RegionBindingTests.test_theMemberListsAreRebuiltOnlyOnAStructuralChange`
    /// pins that gate in both directions — by driving the bump BY HAND. Its
    /// docstring then asserted, in prose only, that *"every production path that
    /// changes membership bumps: a drop at `.ended`"*. It did not. The drop
    /// bumped `CanvasView`'s own `@State` copy, the mirror runs model → view and
    /// never back, and every one of the seventeen `sceneRevision` references
    /// across the test tree was either a hand-driven bump or an inspector commit.
    /// So the gate was pinned and its premise was not, and the shipped inspector
    /// read "No cards live in this region yet" over a card the canvas had
    /// already drawn inside the region — still offering it under "Cite a Card",
    /// where choosing it returned on `cite`'s `!region.mentions(node)` guard and
    /// did nothing at all.
    ///
    /// **A test that drove the bump by hand would reproduce that blind spot
    /// exactly**, so this one drops a real card through `CanvasEventNSView` and
    /// then asks the inspector — through `refreshedRows`, the one function the
    /// shipping view drives — what it would now show. Both halves are asserted:
    /// the card is a resident, and it is no longer on offer.
    ///
    /// Mutation, 2026-07-28: restoring `sceneRevision += 1` at the `.ended` bump
    /// leaves `test_droppingACardIntoARegionJoinsItAndOneUndoTakesBackBoth`
    /// green (the join reaches disk either way) and turns this red.
    func test_aDropIntoARegionReachesThatRegionsInspector() throws {
        let region = CanvasRegionID("r1")
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 500, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: region, label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300)))
        let root = try projectRoot(scene: scene, scraps: [scrapID: scrapText])
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // What the inspector holds before the drop — the same call its
        // `.onChange(of: currentRowsKey, initial: true)` makes when it appears.
        let inspector = RegionInspector(model: model, regionID: region, pieces: [],
                        artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                        onOpenResearchItem: { _ in })
        let before = inspector.refreshedRows(from: RegionInspector.MemberRows())
        XCTAssertTrue(before.residents.isEmpty,
                      "precondition: the card starts outside and unowned")
        XCTAssertEqual(before.candidates.map(\.node), [scrapID],
                       "precondition: and it is what \"Cite a Card\" is offering")

        // Grab the card at (540, 90) and carry it 340pt left, so its centre
        // lands at (250, 130) — squarely inside the region.
        drag(events, from: CGPoint(x: 540, y: 90),
             through: [CGPoint(x: 200, y: 90), CGPoint(x: 200, y: 90)])
        pumpUntilSaved()

        XCTAssertTrue(model.scene.region(region)!.livesHere(scrapID),
                      "precondition: the drop itself joined the card, so what "
                      + "follows is about the inspector being TOLD")

        let after = inspector.refreshedRows(from: before)
        XCTAssertEqual(after.residents.map(\.node), [scrapID],
                       "the drop did not move the counter the inspector's gate "
                       + "reads, so the region still says no cards live in it "
                       + "while the canvas draws one inside it")
        XCTAssertTrue(after.candidates.isEmpty,
                      "and \"Cite a Card\" still offers a card that is already "
                      + "here — a live menu row that silently does nothing, "
                      + "because `cite` returns on its `mentions` guard")
    }

    /// **The same defect on the one path where the writer keeps looking at the
    /// region while a scrap is edited beside it** — and the path that makes
    /// `RegionInspector`'s "it refreshes when the writer leaves the scrap" a
    /// claim rather than a hope.
    ///
    /// **The route is the region's own CHROME BAR, and it is tripwire 32's
    /// documented repro.** Click 1 selects the region; click 2 finds no node
    /// under that point, takes `handleClick`'s `.emptyCanvas` branch, mints a
    /// scrap and opens "Edit Scrap" — and `guard clickCount >= 2` returns before
    /// the selection assignment, so the region is still selected while the
    /// writer types. `test_aRegionStaysSelectedWhileADoubleClickOpensAScrap`
    /// pins that; this reads what the inspector beside it then shows.
    ///
    /// **It is NOT a double-click on a card, and that distinction cost this
    /// slice a wrong repro five times.** AppKit sends `clickCount: 1` first, and
    /// that click selects the card — `test_aDoubleClickOnACardDeselectsTheRegion`
    /// is next door asserting exactly that. So every click here sends the real
    /// two-event sequence rather than jumping straight to `clickCount: 2`, which
    /// would keep the region selected by a shortcut of the test's own and prove
    /// nothing about the surface.
    ///
    /// The observable is the minted scrap's title in the inspector's **residents**
    /// list. It enters that list titled "Empty scrap" and has to be re-read once
    /// the writer leaves it, or the region lists a card by a line it no longer
    /// starts with.
    ///
    /// **It was the CANDIDATES list until 2026-07-28**, when creation began
    /// absorbing: a scrap minted over this region's chrome bar now lands inside
    /// the region's frame and so joins it, which moves it out of the "cards you
    /// could cite" offer and into the residents. Same repro, same subject, same
    /// staleness — one list to the left.
    func test_leavingAScrapRefreshesTheRegionInspectorItIsSittingBeside() throws {
        let region = CanvasRegionID("r1")
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 60, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: region, label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300),
                                        homeMembers: [scrapID]))
        let root = try projectRoot(scene: scene, scraps: [scrapID: "Rain."])
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // The chrome bar runs (20,20)–(420,44); the fixture's card starts at
        // y 60, so both points below are on the bar and on no card.
        func click(at point: CGPoint, count: Int) {
            events.applyMouseDown(at: point, clickCount: count)
            events.applyMouseUp(at: point)
        }

        // The real double-click: clickCount 1 THEN 2, as AppKit delivers it.
        let mintPoint = CGPoint(x: 200, y: 30)
        click(at: mintPoint, count: 1)
        click(at: mintPoint, count: 2)
        pump(0.3)
        XCTAssertEqual(model.selection, .region(region),
                       "precondition: click 1 selected the region and click 2 never "
                       + "reassigned it, so the inspector is still open on it")
        XCTAssertEqual(model.scene.count, 2,
                       "precondition: click 2 minted a scrap over the chrome bar")

        // What the inspector holds with the new scrap minted and still empty.
        let inspector = RegionInspector(model: model, regionID: region, pieces: [],
                        artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                        onOpenResearchItem: { _ in })
        let before = inspector.refreshedRows(from: RegionInspector.MemberRows())
        let minted = try XCTUnwrap(before.residents.first { $0.node != scrapID }?.node,
                                   "precondition: the minted scrap is a resident — "
                                   + "it was made inside the region's frame, and "
                                   + "creation absorbs (2026-07-28)")
        XCTAssertEqual(before.residents.first { $0.node == minted }?.title,
                       CanvasAccessibility.emptyScrapValue,
                       "precondition: and it is listed as an empty scrap")

        type("Rain at the falls.", into: try XCTUnwrap(
            try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                          "the double-click mounted no editor").textView))
        pump(0.3)

        // Leaving the scrap — back onto the chrome bar, clear of the card the
        // second click minted at x 200. This is a single click, so it DOES
        // reassign the selection: to the same region, which is why the inspector
        // and its cached rows survive it.
        click(at: CGPoint(x: 60, y: 30), count: 1)
        pump(0.5)
        XCTAssertEqual(model.selection, .region(region),
                       "precondition: the writer is still looking at this region")

        let after = inspector.refreshedRows(from: before)
        XCTAssertEqual(after.residents.first { $0.node == minted }?.title,
                       "Rain at the falls.",
                       "the writer left the scrap and the region beside it still "
                       + "lists that card as an empty one — `commitActiveEdit` "
                       + "bumped a counter this gate does not read")
    }

    /// **A press that drifted must not be mistaken for a sweep that minted.**
    ///
    /// `applyMouseDown` opens a drag session on EVERY mouse-down, and on a
    /// trackpad a click routinely drifts a point or two — which takes
    /// `interaction.hasMoved`. `createRegion` still refuses anything under
    /// `CanvasRegionMetrics.minimumSide`, so the scene does not change; before
    /// the guard, the structural counter moved anyway. That is one accessibility
    /// tree rebuilt — a sort of the whole scene and a copy of every scrap's
    /// string — plus, now the bump reaches the model, one rebuild of the region
    /// inspector's member lists and its scene-wide candidate walk, per click on
    /// nothing.
    ///
    /// Both directions, because a guard that simply stopped bumping would pass
    /// the first assertion and take the drop-to-join and the region sweep down
    /// with it.
    func test_aBareCanvasPressThatDriftedIsNotAStructuralChange() throws {
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        pump(0.3)

        let atRest = model.sceneRevision
        // One point of drift, well under the 80pt minimum side.
        drag(events, from: CGPoint(x: 600, y: 400), through: [CGPoint(x: 601, y: 400)])
        pump(0.3)
        XCTAssertEqual(model.sceneRevision, atRest,
                       "a click on bare canvas that drifted a point minted no "
                       + "region and changed nothing, and still bumped the "
                       + "structural counter — so every trackpad click on the "
                       + "canvas sorts the scene and rebuilds two cached lists")
        XCTAssertEqual(model.scene.regionCount, 0,
                       "precondition: the drift really did mint nothing, or the "
                       + "assertion above is about a different gesture")

        // The control: a sweep clear of the minimum side, which really does mint.
        drag(events, from: CGPoint(x: 600, y: 400), through: [CGPoint(x: 400, y: 200)])
        pump(0.3)
        XCTAssertEqual(model.scene.regionCount, 1, "precondition: this one minted")
        XCTAssertGreaterThan(model.sceneRevision, atRest,
                             "and a sweep that DID mint a region has to reach the "
                             + "accessibility tree and the inspector — a guard "
                             + "that just stopped bumping would pass the "
                             + "assertion above and lose this one")
    }

    func test_droppingACardIntoARegionJoinsItAndOneUndoTakesBackBoth() throws {
        // The same region, and a scrap that starts OUTSIDE it.
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 500, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300)))
        let root = try projectRoot(scene: scene, scraps: [scrapID: scrapText])
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        XCTAssertFalse(sceneOnDisk(root).region(CanvasRegionID("r1"))!.livesHere(scrapID),
                       "precondition: it starts outside and unowned")

        // Grab the card at (540, 90) and carry it 340pt left, so its centre
        // lands at (250, 130) — squarely inside the region.
        drag(events, from: CGPoint(x: 540, y: 90),
             through: [CGPoint(x: 200, y: 90), CGPoint(x: 200, y: 90)])
        pumpUntilSaved()

        XCTAssertTrue(sceneOnDisk(root).region(CanvasRegionID("r1"))!.livesHere(scrapID),
                      "the drop joined it")

        XCTAssertTrue(window.makeFirstResponder(events))
        let undo = try editMenuItem(#selector(CanvasEventNSView.undo(_:)), in: window)
        _ = undo.target.perform(undo.item.action, with: undo.item)
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 500, y: 60))
        XCTAssertFalse(onDisk.region(CanvasRegionID("r1"))!.livesHere(scrapID),
                       "ONE ⌘Z, because the join lands inside the move's own "
                       + "gesture — a second bracket would leave the card back "
                       + "outside a region that still claimed it")
    }

    /// **A resize is not a drop.** The join is read off `interaction.kind ==
    /// .movingNode`, and dropping that filter is invisible everywhere else: a
    /// region drag reports no `activeNodeID`, so the only gesture the filter
    /// actually excludes is a card RESIZE — where `hasMoved` is true and the
    /// card's centre walks as the width changes.
    ///
    /// The geometry is chosen so it walks across the line: the card starts with
    /// its centre exactly on the region's right edge, and narrowing it to the
    /// floor carries the centre 60pt inside. Without the filter the writer
    /// rewraps a card near a region and it silently changes owner.
    func test_narrowingACardUntilItsCentreIsInsideARegionDoesNotJoinIt() throws {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 300, y: 60),
                                width: 240, cachedHeight: 38))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300)))
        let root = try projectRoot(scene: scene, scraps: [scrapID: scrapText])
        let window = host(CanvasView(model: makeModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // 2pt inside the card's bottom-right corner square. The card is 38pt
        // tall — `rewrappingScrapText` records the measurement, and `scrapText`
        // is one line at every width from 240 down to the floor — so the corner
        // is at (540, 98). A press that missed it would leave the width at 240,
        // which the first assertion below reads.
        drag(events, from: CGPoint(x: 538, y: 96),
             through: [CGPoint(x: 100, y: 96)])
        pumpUntilSaved()

        let onDisk = sceneOnDisk(root)
        let card = try XCTUnwrap(onDisk.node(scrapID))
        XCTAssertEqual(card.width, CanvasInteraction.minimumCardWidth,
                       "precondition: the resize really ran to the floor")
        XCTAssertEqual(card.origin, CGPoint(x: 300, y: 60),
                       "precondition: a resize holds the origin, so the centre "
                       + "moved by half the width it lost and by nothing else")
        XCTAssertTrue(onDisk.region(CanvasRegionID("r1"))!.frame
                        .contains(CGPoint(x: card.frame!.midX, y: card.frame!.midY)),
                      "precondition: the narrowed card's centre really is inside "
                      + "the region, so a missing filter WOULD have joined it")
        XCTAssertFalse(onDisk.region(CanvasRegionID("r1"))!.livesHere(scrapID),
                       "rewrapping a card near a region silently changed its owner "
                       + "— the drop is a DROP, and only a move ends in one")
    }

    /// **The fast route, end to end.** A real ⇧-flagged `NSEvent` through
    /// `window.sendEvent(_:)`, so the modifier is read where production reads it
    /// and the answer travels the whole way to the scene.
    func test_aShiftDragBetweenTwoCardsReachesTheSceneThroughTheRealEventPath() throws {
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: try twoCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        XCTAssertTrue(model.scene.lines.isEmpty, "precondition: nothing is connected yet")
        let origin = try XCTUnwrap(model.scene.node(scrapID)?.origin)

        try sendRealDrag(in: window, from: insideTheFirstCard,
                         through: [CGPoint(x: 250, y: 120), insideTheSecondCard],
                         shift: true)

        XCTAssertEqual(model.scene.lines.count, 1,
                       "a ⇧-drag from one card to another made no line — the modifier "
                       + "reached no further than the event")
        let line = try XCTUnwrap(model.scene.lines.first)
        XCTAssertEqual(line.from, scrapID)
        XCTAssertEqual(line.to, secondScrapID)
        XCTAssertNil(line.label)
        XCTAssertEqual(model.scene.node(scrapID)?.origin, origin,
                       "and the source card did not move: without ⇧ this drag is a "
                       + "MOVE, so an unmoved card is what says the flag was read")
        XCTAssertEqual(model.selection, .line(line.id),
                       "the new line is what the writer is left holding, so ⌫ and the "
                       + "inspector are pointed at it")
    }

    /// **The discoverable route, end to end, knowing nothing.** The card is
    /// selected by a real CLICK rather than by assigning `model.selection`,
    /// because the whole claim of this route is that a writer finds it without
    /// being told; a test that set the selection by hand would be told.
    ///
    /// No modifier anywhere in it.
    func test_aDragFromTheSelectedCardsConnectHandleReachesTheSceneTheSameWay() throws {
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: try twoCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))

        try sendRealClick(in: window, at: insideTheFirstCard)
        XCTAssertEqual(model.selection, .node(scrapID),
                       "precondition: a plain click selects the card, and selection is "
                       + "what draws the mark")
        let origin = try XCTUnwrap(model.scene.node(scrapID)?.origin)

        try sendRealDrag(in: window, from: try connectMarkCentre(of: scrapID, in: model),
                         through: [CGPoint(x: 350, y: 150), insideTheSecondCard],
                         shift: false)

        XCTAssertEqual(model.scene.lines.count, 1,
                       "a drag out of the mark on a selected card made no line — the "
                       + "route the writer can SEE is the one that must not be missing")
        let line = try XCTUnwrap(model.scene.lines.first)
        XCTAssertEqual(line.from, scrapID)
        XCTAssertEqual(line.to, secondScrapID)
        XCTAssertEqual(model.scene.node(scrapID)?.origin, origin,
                       "and the card stayed put: a press inside the mark is a line, "
                       + "not a move")
    }

    /// **The press that SELECTS a card must not also draw a line out of it.**
    ///
    /// `applyMouseDown` fires `onClick` strictly before `onDrag(.began)`, so by
    /// the time a drag begins the card under the pointer is already selected —
    /// which is why the gesture asks what was selected when the press ARRIVED.
    /// Without that, a 14 pt patch on the right edge of every unselected card on
    /// the canvas would refuse to move it, and would instead do something the
    /// writer could not have predicted from anything on screen.
    func test_theFirstPressOnAnUnselectedCardsMarkPositionMovesItRatherThanDrawingALine() throws {
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: try twoCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        XCTAssertNil(model.selection, "precondition: nothing is selected, so no mark is drawn")
        let origin = try XCTUnwrap(model.scene.node(scrapID)?.origin)
        // Where the mark WOULD be, if the card were selected.
        let markPosition = try connectMarkCentre(of: scrapID, in: model)

        try sendRealDrag(in: window, from: markPosition,
                         through: [CGPoint(x: 350, y: 150), insideTheSecondCard],
                         shift: false)

        XCTAssertTrue(model.scene.lines.isEmpty,
                      "the mark was not on screen when the writer pressed, so they "
                      + "cannot have aimed at it")
        XCTAssertNotEqual(model.scene.node(scrapID)?.origin, origin,
                          "and the press did what a press on a card does: it moved it")
    }

    /// **A line minted by a press and a release with no drag sample between them
    /// must still reach DISK.**
    ///
    /// `hasMoved` is set by `update`, and `update` runs only on `.changed` — so a
    /// mouse-down on one card and a mouse-up over another with nothing in between
    /// inserts a line under `persist: false` and then meets the `hasMoved`
    /// bail-out, which returns above `model.scheduleSave()`. A line in memory
    /// that never reaches the sidecar, and the writer has no way to know.
    ///
    /// **The sweep is structurally immune and the line path is not**, which is
    /// the non-obvious half: a sweep's rect comes from the mode's own `current`,
    /// so with no `.changed` it is a zero rect and `createRegion` refuses it —
    /// there is nothing to lose. `endLine` reads the RELEASE point directly, so
    /// it is the first gesture on this surface that can mint something without a
    /// single drag sample.
    func test_aLineMadeWithoutASingleDragSampleStillReachesDisk() throws {
        let root = try twoCardProjectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Down on the first card, up over the second, and no `.changed` at all.
        events.applyMouseDown(at: insideTheFirstCard, clickCount: 1, shiftHeld: true)
        events.applyMouseUp(at: insideTheSecondCard)
        pump()

        XCTAssertEqual(model.scene.lines.count, 1,
                       "precondition: the line is in memory, so a missing line below "
                       + "is a save that never happened rather than a gesture that "
                       + "never landed")
        XCTAssertEqual(savedScene(after: window, root: root).lines.count, 1,
                       "the line never reached the sidecar: the writer drew it, saw "
                       + "it, quit, and it was gone")
    }

    /// **A line drag that minted nothing is not a structural change**, and one
    /// that minted a line is — the sweep's own guard, asked of a third gesture.
    ///
    /// It is reachable exactly the way the sweep's is: every ⇧-press on a card
    /// opens a drag session, a trackpad press routinely drifts a point, and a
    /// release that is still over the source card makes no line. Without the
    /// guard each one sorts the scene, copies every scrap's string and rebuilds
    /// the region inspector's two cached lists in the other column.
    ///
    /// Both directions, because the "no bump" half alone is satisfied by a build
    /// that never bumps at all.
    func test_aShiftPressThatDriftedAndMadeNoLineIsNotAStructuralChange() throws {
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: try twoCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        let before = model.sceneRevision

        // Pressed with ⇧ on a card and released a point away — still over the
        // card it started from, which is not a line.
        try sendRealDrag(in: window, from: insideTheFirstCard,
                         through: [CGPoint(x: 61, y: 31)], shift: true)
        XCTAssertTrue(model.scene.lines.isEmpty,
                      "precondition: the release was over the source card, so there "
                      + "is no line")
        XCTAssertEqual(model.sceneRevision, before,
                       "a connect drag that made nothing changed nothing, and must "
                       + "not rebuild the accessibility tree or the inspector's lists")

        try sendRealDrag(in: window, from: insideTheFirstCard,
                         through: [CGPoint(x: 250, y: 120), insideTheSecondCard],
                         shift: true)
        XCTAssertEqual(model.scene.lines.count, 1, "precondition: this one made a line")
        XCTAssertGreaterThan(model.sceneRevision, before,
                             "and a line that WAS made is a structural change — "
                             + "without this the other column never hears about it")
    }

    /// **The step's NAME, through both routes.**
    ///
    /// An undo test whose only observable is the post-⌘Z scene cannot tell "its
    /// own step" from "folded into the neighbour's" — demonstrated twice in this
    /// area on a nesting bug. So this reads `undoMenuItemTitle`, which is the
    /// string the writer sees in the Edit menu.
    ///
    /// Run through BOTH routes: they share one implementation today, and a later
    /// change is exactly what would give them two.
    func test_drawingALineIsOneUndoStepCalledDrawLine() throws {
        for byShift in [true, false] {
            let route = byShift ? "⇧-drag" : "the connect mark"
            let model = makeModel()
            let window = host(CanvasView(model: model, projectRoot: try twoCardProjectRoot(),
                                         paletteSwatchHexes: { [] }))
            var start = insideTheFirstCard
            if !byShift {
                try sendRealClick(in: window, at: insideTheFirstCard)
                start = try connectMarkCentre(of: scrapID, in: model)
            }

            try sendRealDrag(in: window, from: start,
                             through: [CGPoint(x: 350, y: 150), insideTheSecondCard],
                             shift: byShift)
            XCTAssertEqual(model.scene.lines.count, 1,
                           "precondition for \(route): a line was drawn, so an "
                           + "unchanged stack below means the step went missing "
                           + "rather than that nothing happened")

            XCTAssertTrue(model.undo.undoMenuItemTitle.contains("Draw Line"),
                          "drawing a line by \(route) must be its own named step — "
                          + "the Edit menu reads \"Undo Draw Line\". Got: "
                          + model.undo.undoMenuItemTitle)

            model.undo.undo()
            XCTAssertTrue(model.scene.lines.isEmpty,
                          "and one ⌘Z takes the line back (\(route))")
            XCTAssertEqual(model.scene.count, 2,
                           "and takes nothing else with it: both cards are still "
                           + "there (\(route))")
        }
    }

    /// **A double click on a line must not mint a scrap under it.**
    ///
    /// Both clicks are sent, `clickCount: 1` and then `clickCount: 2`, exactly as
    /// a hand produces them — and the first one is what makes this a bug rather
    /// than a curiosity: it has already selected the line, so with the line
    /// falling through to the empty-canvas branch the writer gets "Edit Scrap"
    /// open on a brand-new card while the other column is showing a line. That is
    /// tripwire 32's own repro arriving through a new door.
    ///
    /// A test that jumped straight to `clickCount: 2` would prove nothing here:
    /// that shortcut has produced a wrong repro five times in this area.
    func test_aDoubleClickOnALineDoesNotMintAScrapUnderIt() throws {
        let root = try twoCardProjectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let line = try drawALine(in: window, model)
        XCTAssertEqual(model.scene.count, 2, "precondition: two cards and no more")

        events.applyMouseDown(at: line.midpoint, clickCount: 1)
        events.applyMouseUp(at: line.midpoint)
        pump(0.05)
        XCTAssertEqual(model.selection, .line(line.id),
                       "precondition: click 1 selected the line — which is what makes "
                       + "click 2 minting a scrap the tripwire-32 state rather than "
                       + "merely a stray card")

        events.applyMouseDown(at: line.midpoint, clickCount: 2)
        events.applyMouseUp(at: line.midpoint)
        pump(0.3)

        XCTAssertEqual(model.scene.count, 2,
                       "the double-click minted a scrap under the writer's own line: "
                       + "the line fell through to the empty-canvas branch")
        XCTAssertNil(firstDescendant(ScrapEditorContainer.self,
                                     in: try XCTUnwrap(window.contentView)),
                     "a double-click on a line opened an editor. It opens none of any "
                     + "kind — a line's label is edited in the other column, where a "
                     + "region's already is")
        XCTAssertFalse(model.isInGesture,
                       "\"Edit Scrap\" is open with no scrap: the next thing the "
                       + "writer does from the inspector nests inside it, registers "
                       + "no step of its own, and rides into their next ⌘Z")
        XCTAssertEqual(model.selection, .line(line.id),
                       "and the line the writer double-clicked is still what they are "
                       + "holding")
        XCTAssertEqual(savedScene(after: window, root: root).count, 2,
                       "a stray scrap reached disk")
    }

    /// **The delivery path for ⌫ on a line, end to end.** A real `NSEvent`
    /// through `window.sendEvent(_:)`, routed by AppKit to whatever holds first
    /// responder, asserted on what reached DISK.
    ///
    /// Not a `deleteSelection()` called by hand: that is precisely the test that
    /// would have passed throughout 1C-a while ⌘Z was greyed out in the Edit
    /// menu, and throughout the slice in which `CanvasScene.remove` had no caller
    /// at all.
    func test_backspaceDeletesTheSelectedLineThroughTheRealResponderChain() throws {
        let root = try twoCardProjectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let line = try drawALine(in: window, model)

        XCTAssertEqual(model.selection, .line(line.id),
                       "precondition: the new line is what the writer is holding")
        XCTAssertTrue(window.makeFirstResponder(events),
                      "precondition: the key will actually arrive at the canvas")
        pumpUntilSaved()
        XCTAssertEqual(sceneOnDisk(root).lines.count, 1,
                       "precondition: the line is on disk, so its absence below is a "
                       + "delete rather than a save that never happened")

        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()

        XCTAssertTrue(sceneOnDisk(root).lines.isEmpty,
                      "⌫ with a line selected did not delete it. The likeliest cause "
                      + "is that the `.line` arm of `deleteSelection` is still "
                      + "returning false — which every model-level assertion in this "
                      + "task is blind to")
        XCTAssertNil(model.selection, "and nothing is left selected")
    }

    /// **A line delete never touches its cards, and one ⌘Z brings it back.**
    ///
    /// The step's NAME is asserted, not just the scene: an undo test whose only
    /// observable is the post-⌘Z scene cannot tell "its own step" from "folded
    /// into the neighbouring one", and this arm goes through `CanvasModel.mutate`
    /// — a different bracket from the scrap branch's hand-rolled one.
    func test_deleteRemovesTheSelectedLineAndLeavesBothCards() throws {
        let root = try twoCardProjectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let line = try drawALine(in: window, model)
        XCTAssertTrue(window.makeFirstResponder(events))

        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()

        let afterDelete = sceneOnDisk(root)
        XCTAssertTrue(afterDelete.lines.isEmpty, "precondition: the line went")
        XCTAssertEqual(afterDelete.count, 2,
                       "deleting a line took a card with it — the writer took back "
                       + "the relationship, not the things related")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText,
                       "and the words on those cards are untouched")

        let undoSelector = #selector(CanvasEventNSView.undo(_:))
        let undo = try editMenuItem(undoSelector, in: window)
        XCTAssertTrue(undo.isEnabled,
                      "deleting a line left nothing on the undo stack, so a stray ⌫ "
                      + "takes a connection away permanently")
        XCTAssertTrue(undo.item.title.contains("Delete Line"),
                      "the menu item reads \"\(undo.item.title)\" rather than naming "
                      + "what it will take back")
        _ = undo.target.perform(undoSelector, with: undo.item)
        pumpUntilSaved()

        let restored = sceneOnDisk(root)
        XCTAssertEqual(restored.lines.count, 1, "⌘Z did not bring the line back")
        XCTAssertEqual(restored.lines.first?.id, line.id,
                       "and it is the same line rather than a fresh one")
        XCTAssertEqual(restored.count, 2, "and it brought no extra card with it")
    }

    /// **⌫ with a line selected refuses while any gesture is open**, for the
    /// reason the card and region arms do: `beginGesture` takes no snapshot when
    /// it nests and `endGesture` registers nothing above depth 0, so a delete
    /// inside somebody else's bracket collapses into it under the wrong name —
    /// and if that bracket never closes it cannot be taken back at all.
    ///
    /// **The gesture is opened by hand, and that is a deliberate exception with
    /// a reason — read it before "fixing" it to a pointer sequence.**
    ///
    /// This test first drove the state the way the card arm's does: press and
    /// HOLD on the line, which used to leave the line selected while
    /// `onDrag(.began)` opened a "New Region" sweep. **The click/drag agreement
    /// fix closed that door.** A press on a line is now idle, so it opens no
    /// bracket at all — and every OTHER press moves the selection onto whatever
    /// is under it, so there is no pointer sequence left that ends with a line
    /// selected and a gesture open. That is the fix working, not a gap.
    ///
    /// So the bracket is opened directly and the KEY is still a real `NSEvent`
    /// through `window.sendEvent(_:)` — the delivery path is what the 1C-a
    /// defect was in, and it stays real. If a later gesture makes the state
    /// reachable again, the assertion is already here.
    func test_deleteWithALineSelectedMidGestureIsRefused() throws {
        let root = try twoCardProjectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let line = try drawALine(in: window, model)

        // The door this used to come through, asserted rather than assumed —
        // so if a press on a line ever opens a bracket again, this says so
        // here rather than leaving the hand-driven setup looking arbitrary.
        var probe = CanvasInteraction()
        probe.begin(at: line.midpoint, in: model.scene, connecting: false)
        XCTAssertFalse(probe.isActive,
                       "a press on a line opens a gesture again — drive this test "
                       + "through the pointer instead of by hand")

        XCTAssertTrue(window.makeFirstResponder(events))
        XCTAssertEqual(model.selection, .line(line.id),
                       "precondition: the line the ⇧-drag made is still selected, so "
                       + "there is something for ⌫ to take")
        model.beginGesture("Move Scrap")
        XCTAssertTrue(model.isInGesture, "precondition: a bracket is open")

        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()

        XCTAssertEqual(model.scene.lines.count, 1,
                       "⌫ mid-gesture deleted the line from inside somebody else's "
                       + "undo bracket: it registers no step of its own, and a "
                       + "bracket that never closes takes the line with it")
        model.endGesture()
        pumpUntilSaved()
        XCTAssertEqual(sceneOnDisk(root).lines.count, 1,
                       "the line came back only to go when the gesture ended")
    }

    /// **The click and the drag must agree about what the press was.**
    ///
    /// Where a line crosses a region's chrome bar the click selects the LINE —
    /// it is drawn on top, and that is the whole of this slice's precedence
    /// rule. `CanvasInteraction.begin` had no line branch, so the same press
    /// fell through to `regionHit` and opened "Move Region": **select one thing,
    /// drag another.**
    ///
    /// It bites rather than being theoretical, which is why the drag here is one
    /// point. A trackpad press routinely drifts that far, and `endGesture`
    /// registers whenever the state moved — so the writer gets the region and
    /// every resident shifted under a step their next ⌘Z takes, while the
    /// inspector and ⌫ are still pointed at the line.
    ///
    /// **The undo assertion is not decoration.** The frames alone can pass while
    /// a step still lands, and a stray step is the half the writer meets later,
    /// on a ⌘Z aimed at something else.
    ///
    /// The control is the same bar, the same drag, 150 pt along it and clear of
    /// the line: without it "nothing moved" is satisfied by a build where a
    /// region can no longer be dragged at all.
    func test_aPressWhereALineCrossesARegionsBarMovesNeitherAndPushesNoUndoStep() throws {
        let root = try lineCrossingARegionsBarRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        let crossing = CGPoint(x: 300, y: 112)
        XCTAssertEqual(model.scene.selectionTarget(at: crossing),
                       .line(crossingLineID),
                       "precondition: the click resolves to the line here — which is "
                       + "the whole reason the drag must not resolve to the region")
        XCTAssertEqual(CanvasInteraction.regionHit(at: crossing, in: model.scene),
                       .chrome(crossingRegionID),
                       "precondition: and the region's chrome bar is genuinely under "
                       + "the same point, so this is the disagreement and not an "
                       + "absent region")
        let frameBefore = try XCTUnwrap(model.scene.region(crossingRegionID)?.frame)
        let residentBefore = try XCTUnwrap(model.scene.node(scrapID)?.origin)

        // A press with a one-point drift — the ordinary trackpad click.
        drag(events, from: crossing, through: [CGPoint(x: crossing.x + 1, y: crossing.y + 1)])
        pumpUntilSaved()

        XCTAssertEqual(model.scene.region(crossingRegionID)?.frame, frameBefore,
                       "a press on the line moved the REGION: the click selected the "
                       + "line and the drag picked up the region under it")
        XCTAssertEqual(model.scene.node(scrapID)?.origin, residentBefore,
                       "and it carried the region's resident with it — the card the "
                       + "writer was not touching moved because of where they clicked")
        XCTAssertEqual(model.selection, .line(crossingLineID),
                       "and the line is what they are holding, which is exactly why "
                       + "the region moving is a disagreement rather than a choice")
        XCTAssertFalse(try XCTUnwrap(events.undoManager).canUndo,
                       "the press pushed an undo step for a gesture the writer never "
                       + "made: their next ⌘Z takes back a region move instead of "
                       + "whatever they were actually doing")
        XCTAssertEqual(sceneOnDisk(root).region(crossingRegionID)?.frame, frameBefore,
                       "and it reached disk")

        // The control: the same bar, the same drift, clear of the line.
        let alongTheBar = CGPoint(x: crossing.x + 150, y: crossing.y)
        XCTAssertNil(CanvasLineHit.line(at: alongTheBar, in: model.scene),
                     "precondition: this end of the bar is clear of the line")
        drag(events, from: alongTheBar,
             through: [CGPoint(x: alongTheBar.x + 40, y: alongTheBar.y + 30)])
        pumpUntilSaved()

        XCTAssertNotEqual(model.scene.region(crossingRegionID)?.frame, frameBefore,
                          "the region can no longer be dragged by its bar at all — "
                          + "\"the line wins\" must cost the bar the width of the "
                          + "line, not the whole of it")
        XCTAssertTrue(model.undo.undoMenuItemTitle.contains("Move Region"),
                      "and that drag is its own named step. Got: "
                      + model.undo.undoMenuItemTitle)
    }

    /// **A card delete takes its lines, and ONE ⌘Z brings both back** — one
    /// snapshot carries the scene, so they cannot be restored out of step.
    ///
    /// The card half is `CanvasScene.remove`'s line scrub, which is unit tested;
    /// what only this can show is that the scrub survives the delete path, the
    /// save, the reload and the codec — and that it did not become a second undo
    /// step the writer has to press ⌘Z twice for.
    func test_deletingACardTakesItsLinesAndOneUndoBringsBothBack() throws {
        let root = try twoCardProjectRoot()
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        _ = try drawALine(in: window, model)

        clickAndFocusTheCanvas(events, at: insideTheFirstCard, in: window)
        XCTAssertEqual(model.selection, .node(scrapID),
                       "precondition: the card the line leaves is selected")

        window.sendEvent(deleteKeyEvent(for: window))
        pumpUntilSaved()

        let afterDelete = sceneOnDisk(root)
        XCTAssertNil(afterDelete.node(scrapID), "precondition: the card went")
        XCTAssertTrue(afterDelete.lines.isEmpty,
                      "the line to the deleted card outlived it — it draws from a "
                      + "card that is not there to a card that is")

        let undoSelector = #selector(CanvasEventNSView.undo(_:))
        let undo = try editMenuItem(undoSelector, in: window)
        XCTAssertTrue(undo.item.title.contains("Delete Card"),
                      "the menu item reads \"\(undo.item.title)\" — the line scrub "
                      + "must ride inside the card's own step rather than becoming a "
                      + "second one")
        _ = undo.target.perform(undoSelector, with: undo.item)
        pumpUntilSaved()

        let restored = sceneOnDisk(root)
        XCTAssertNotNil(restored.node(scrapID), "⌘Z did not bring the card back")
        XCTAssertEqual(restored.lines.count, 1,
                       "the card came back without its line: one ⌫ is one gesture, so "
                       + "one ⌘Z has to restore both — a second step here means the "
                       + "writer's canvas can be left with a card whose connections "
                       + "are one keystroke behind it")
    }
}
