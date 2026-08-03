import XCTest
@testable import Maugham

/// The region half of the gesture state machine: where a region can be grabbed,
/// what travels when it moves, what a corner drag does, what a sweep on bare
/// canvas makes, and which region a drop meant.
///
/// **This file is necessary and not sufficient**, and saying so is the point of
/// the comment. 1C-a shipped a resize that vanished the card for the whole drag
/// with every resize test in the suite green, because all of them asserted after
/// `.ended`. The other half — a real `CanvasEventNSView` driven through
/// `drag(_:from:through:)`, asserting on what reached disk — is in
/// `CanvasViewMountingTests`.
final class CanvasRegionInteractionTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")

    /// 'a' sits inside r1; 'b' sits well outside it.
    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 100, y: 100),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 900, y: 100),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        return s
    }

    // MARK: - Where a region can be grabbed

    func test_theInteriorOfARegionIsNotAGrabHandle() {
        XCTAssertNil(CanvasInteraction.regionHit(at: CGPoint(x: 400, y: 300), in: scene()))
    }

    func test_theLabelBarGrabsTheRegion() {
        XCTAssertEqual(CanvasInteraction.regionHit(at: CGPoint(x: 300, y: 8), in: scene()),
                       .chrome(r1))
    }

    func test_theBottomRightCornerResizesTheRegion() {
        XCTAssertEqual(CanvasInteraction.regionHit(at: CGPoint(x: 596, y: 396), in: scene()),
                       .resizeCorner(r1))
    }

    /// The unmarked half of the corner square is still live, for the reason
    /// `CanvasInteractionTests.test_theUnmarkedHalfOfTheCornerSquareStillResizes`
    /// gives for a card: the MARK is the triangle below the hypotenuse and the
    /// TARGET is the whole square, because a target larger than its mark forgives
    /// a near miss where the reverse swallows drags the writer aimed at the
    /// region. Shrinking the target to the ink is a tidy-up that looks right.
    func test_theUnmarkedHalfOfTheRegionsCornerSquareStillResizes() {
        // 1pt inside the top-left corner of the 14pt square — above the
        // hypotenuse, so nothing is drawn here.
        XCTAssertEqual(CanvasInteraction.regionHit(at: CGPoint(x: 587, y: 387), in: scene()),
                       .resizeCorner(r1))
    }

    /// A small region overlapping a large one must stay reachable. Sorting the
    /// candidates the other way puts the big region's chrome in front of the
    /// small one's and the small one can never be picked up again.
    func test_theSmallerRegionWinsWhenTwoChromeBarsOverlap() {
        var s = scene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("small"), label: "Inset",
                                    frame: CGRect(x: 200, y: 0, width: 120, height: 100)))
        XCTAssertEqual(CanvasInteraction.regionHit(at: CGPoint(x: 250, y: 8), in: s),
                       .chrome(CanvasRegionID("small")))
    }

    func test_aCardOverTheLabelBarStillWins() {
        var s = scene()
        s.move(a, to: CGPoint(x: 200, y: 0))
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s, connecting: false)
        XCTAssertEqual(i.activeNodeID, a)
        XCTAssertNil(i.activeRegionID)
    }

    // MARK: - Dragging a region

    /// §4.1: drag a region and its members travel. This is what makes
    /// reorganising one gesture rather than a marquee-select.
    func test_draggingARegionCarriesItsResidents() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s, connecting: false)
        i.update(to: CGPoint(x: 400, y: 58), in: &s)
        XCTAssertEqual(s.region(r1)?.frame.origin, CGPoint(x: 100, y: 50))
        XCTAssertEqual(s.node(a)?.origin, CGPoint(x: 200, y: 150))
    }

    /// The region keeps its SIZE while it travels. A move written as "set the
    /// frame from the pointer" rather than "translate the frame" resizes it to
    /// wherever the pointer happens to be.
    func test_draggingARegionDoesNotResizeIt() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s, connecting: false)
        i.update(to: CGPoint(x: 400, y: 58), in: &s)
        XCTAssertEqual(s.region(r1)?.frame.size, CGSize(width: 600, height: 400))
    }

    func test_draggingARegionLeavesVisitorsWhereTheyAre() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s, connecting: false)
        i.update(to: CGPoint(x: 400, y: 58), in: &s)
        XCTAssertEqual(s.node(b)?.origin, CGPoint(x: 900, y: 100), "a visitor is not luggage")
    }

    /// §4.2: coordinates never add or remove a member.
    ///
    /// **The destination is chosen so the second assertion is about something.**
    /// An earlier draft dragged the region to (4 000, 4 000), which put it at
    /// (3 700, 3 992)–(4 300, 4 392) — nowhere near `b` at (900, 100), so the
    /// claim in the message was false and the assertion could not fail for the
    /// reason it gave. This lands the frame at (850, 0)–(1 450, 400), which
    /// contains `b` entirely: the region really has been dragged over a node it
    /// does not own, and an implementation that absorbed what it covered fails
    /// here.
    func test_draggingARegionDoesNotChangeMembership() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s, connecting: false)
        i.update(to: CGPoint(x: 1_150, y: 8), in: &s)
        i.end()
        XCTAssertTrue(s.region(r1)!.frame.contains(s.node(b)!.frame!),
                      "precondition: the region now covers b entirely, so the "
                      + "assertion below has something to be about")
        XCTAssertTrue(s.region(r1)!.livesHere(a))
        XCTAssertFalse(s.region(r1)!.livesHere(b),
                       "the region was dragged clean over b and absorbed it — "
                       + "geometry decided membership, which is the whole of what "
                       + "§4.2 forbids")
    }

    func test_aRegionNeverFlicks() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s, connecting: false)
        i.update(to: CGPoint(x: 340, y: 8), in: &s, now: 0)
        i.update(to: CGPoint(x: 400, y: 8), in: &s, now: 0.01)
        XCTAssertNil(i.end(now: 0.011),
                     "a region full of cards skating away is not §7.3's 'objects "
                     + "coming to rest'")
    }

    // MARK: - Resizing a region

    func test_resizingARegionMovesOnlyItsFrame() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 596, y: 396), in: s, connecting: false)
        i.update(to: CGPoint(x: 300, y: 250), in: &s)
        XCTAssertEqual(s.region(r1)?.frame.width, 304)
        XCTAssertEqual(s.region(r1)?.frame.height, 254)
        XCTAssertEqual(s.node(a)?.origin, CGPoint(x: 100, y: 100),
                       "resizing must not drag the residents")
        XCTAssertTrue(s.region(r1)!.livesHere(a), "and must never eject one — tldraw #6017")
    }

    /// The bottom-right corner moves and the top-left stays put. A resize
    /// written off the frame's centre, or one that translates the origin too,
    /// walks the region across the canvas as the writer sizes it.
    func test_resizingARegionLeavesItsTopLeftWhereItWas() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 596, y: 396), in: s, connecting: false)
        i.update(to: CGPoint(x: 900, y: 700), in: &s)
        XCTAssertEqual(s.region(r1)?.frame.origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(s.region(r1)?.frame.width, 904)
        XCTAssertEqual(s.region(r1)?.frame.height, 704)
    }

    func test_resizeIsClampedToAWorkableMinimum() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 596, y: 396), in: s, connecting: false)
        i.update(to: CGPoint(x: -900, y: -900), in: &s)
        XCTAssertEqual(s.region(r1)?.frame.width, CanvasRegionMetrics.minimumSide)
        XCTAssertEqual(s.region(r1)?.frame.height, CanvasRegionMetrics.minimumSide)
    }

    // MARK: - Drawing a region

    func test_aDragOnEmptyCanvasDrawsARegion() throws {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 1_000, y: 1_000), in: s, connecting: false)
        XCTAssertEqual(i.kind, .drawingRegion)
        i.update(to: CGPoint(x: 1_300, y: 1_250), in: &s)
        let rect = try XCTUnwrap(i.pendingRegionDraw)
        XCTAssertEqual(rect, CGRect(x: 1_000, y: 1_000, width: 300, height: 250))
        XCTAssertNotNil(CanvasInteraction.createRegion(rect, in: &s))
        XCTAssertEqual(s.regionCount, 2)
    }

    func test_aDragBackwardsAndUpwardsStillDrawsARegion() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 1_300, y: 1_250), in: s, connecting: false)
        i.update(to: CGPoint(x: 1_000, y: 1_000), in: &s)
        XCTAssertEqual(i.pendingRegionDraw, CGRect(x: 1_000, y: 1_000, width: 300, height: 250))
    }

    /// Every other mode must answer `nil`, or `CanvasView`'s `.ended` reads a
    /// swept rect off a gesture that swept nothing and mints a region on the end
    /// of every card drag.
    /// A scene each, because every gesture below MOVES something: sharing one
    /// would leave the third grabbing a corner that is no longer there, and an
    /// idle interaction reports no pending rect either — passing for the wrong
    /// reason. The `kind` assertions are what make each one non-vacuous.
    func test_onlyASweepHasAPendingRect() {
        var movingScene = scene()
        var moving = CanvasInteraction()
        moving.begin(at: CGPoint(x: 110, y: 110), in: movingScene, connecting: false)
        moving.update(to: CGPoint(x: 400, y: 400), in: &movingScene)
        XCTAssertEqual(moving.kind, .movingNode, "precondition")
        XCTAssertNil(moving.pendingRegionDraw, "a card move is not a sweep")

        var regionScene = scene()
        var movingRegion = CanvasInteraction()
        movingRegion.begin(at: CGPoint(x: 300, y: 8), in: regionScene, connecting: false)
        movingRegion.update(to: CGPoint(x: 400, y: 58), in: &regionScene)
        XCTAssertEqual(movingRegion.kind, .movingRegion, "precondition")
        XCTAssertNil(movingRegion.pendingRegionDraw, "a region move is not a sweep")

        var resizeScene = scene()
        var resizing = CanvasInteraction()
        resizing.begin(at: CGPoint(x: 596, y: 396), in: resizeScene, connecting: false)
        resizing.update(to: CGPoint(x: 700, y: 500), in: &resizeScene)
        XCTAssertEqual(resizing.kind, .resizingRegion, "precondition")
        XCTAssertNil(resizing.pendingRegionDraw, "a region resize is not a sweep")
    }

    func test_aTwitchMakesNoRegion() {
        var s = scene()
        XCTAssertNil(CanvasInteraction.createRegion(
            CGRect(x: 1_000, y: 1_000,
                   width: CanvasRegionMetrics.minimumSide - 1,
                   height: 300),
            in: &s))
        XCTAssertEqual(s.regionCount, 1)
    }

    /// The control for the test above: the same rect one point wider is a real
    /// region. Without it a `createRegion` that refused EVERYTHING — the whole
    /// draw gesture deleted — would satisfy the twitch assertion in silence.
    func test_aSweepAtExactlyTheMinimumMakesARegion() {
        var s = scene()
        XCTAssertNotNil(CanvasInteraction.createRegion(
            CGRect(x: 1_000, y: 1_000,
                   width: CanvasRegionMetrics.minimumSide,
                   height: CanvasRegionMetrics.minimumSide),
            in: &s))
        XCTAssertEqual(s.regionCount, 2)
    }

    /// Nested regions are out of scope (§9), and silently making one is worse
    /// than refusing.
    func test_aDragInsideAnExistingRegionDrawsNothing() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 400, y: 300), in: s, connecting: false)
        XCTAssertFalse(i.isActive)
        i.update(to: CGPoint(x: 500, y: 380), in: &s)
        XCTAssertNil(i.pendingRegionDraw)
        XCTAssertEqual(s.regionCount, 1)
    }

    func test_aNewRegionIsUnlabelledAndOwnsWhateverItWasSweptAround() {
        var s = scene()
        let id = CanvasInteraction.createRegion(
            CGRect(x: 1_000, y: 1_000, width: 300, height: 250), in: &s)!
        XCTAssertEqual(s.region(id)?.label, "")
        XCTAssertEqual(s.region(id)?.displayLabel, CanvasRegion.untitledLabel)
        XCTAssertTrue(s.region(id)!.homeMembers.isEmpty,
                      "this rect was swept over bare canvas, nowhere near either "
                      + "card, so it takes in nothing — the absorbing case is the "
                      + "fixture below")
    }

    /// **Creation absorbs** (Denver, 2026-07-28). This test asserted the exact
    /// opposite until that ruling, and it is inverted rather than deleted so the
    /// reversal is legible in the history.
    ///
    /// The rule §4.2 still holds is about TRANSITIONS — move and resize — which
    /// is where all three of the tools it cites were actually bitten.
    func test_drawingARegionAroundExistingCardsTakesThemIn() {
        var s = scene()
        // 'a' is at (100,100)–(340,180), centre (220,140) — inside. 'b' is at
        // (900,100) and nowhere near, which is what makes the second assertion
        // a real one rather than "everything joined".
        let id = CanvasInteraction.createRegion(
            CGRect(x: 50, y: 50, width: 400, height: 300), in: &s)!
        XCTAssertTrue(s.region(id)!.livesHere(a),
                      "'a' is squarely inside this rect and did not join it")
        XCTAssertFalse(s.region(id)!.livesHere(b),
                       "'b' is 500pt away and was absorbed anyway")
    }

    // MARK: - What a sweep takes in
    //
    // `absorbedNodes` is the DECISION, extracted so it can be asked directly
    // over every input that changes its answer rather than only through the
    // gesture that calls it. Three times this slice something shipped built,
    // tested and reachable on one path only because the tests drove the
    // mechanism instead of the route; a rule with four meaningfully different
    // inputs gets all four asked of it here, and the route asked separately in
    // `CanvasViewMountingTests`.

    /// The centre decides — the same rule a drop uses, so the writer learns it
    /// once. Both directions, because "absorbs everything it touches" and
    /// "absorbs nothing" both pass a one-sided assertion.
    func test_aSweepTakesInTheCardsWhoseCentreItCovers() {
        let s = scene()
        // 'a' is (100,100)–(340,180), centre (220,140).
        XCTAssertEqual(CanvasInteraction.absorbedNodes(
            by: CGRect(x: 0, y: 0, width: 400, height: 300), in: s), [a])
        XCTAssertEqual(CanvasInteraction.absorbedNodes(
            by: CGRect(x: 0, y: 0, width: 4_000, height: 3_000), in: s), [a, b])
        XCTAssertEqual(CanvasInteraction.absorbedNodes(
            by: CGRect(x: 2_000, y: 2_000, width: 400, height: 300), in: s), [])
    }

    /// A card the sweep only clips keeps its distance: the same answer
    /// `joinTarget` gives a drop, and the same answer to the one-pixel
    /// absurdity §4.2 cites.
    func test_aSweepThatOnlyClipsACardDoesNotTakeItIn() {
        let s = scene()
        // Covers (100,100)–(200,180) of 'a' — 100pt of a 240pt card — and stops
        // well short of its centre at x = 220.
        XCTAssertEqual(CanvasInteraction.absorbedNodes(
            by: CGRect(x: 0, y: 0, width: 200, height: 300), in: s), [],
                       "a sweep that merely overlaps a card claimed it")
    }

    /// **Sub-question, decided: a card that already lives somewhere else IS
    /// taken in.** Drawing a box around a card is a claim on it. The alternative
    /// — skipping the ones already spoken for — gives a region holding some of
    /// what the writer swept and not the rest, with nothing on screen to say
    /// which. `CanvasMembership.join` moves the home, so §4.3's one-home rule
    /// holds throughout.
    func test_aSweepTakesInACardThatAlreadyLivesInAnotherRegion() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        let id = CanvasInteraction.createRegion(
            CGRect(x: 50, y: 50, width: 400, height: 300), in: &s)!

        XCTAssertTrue(s.region(id)!.livesHere(a))
        XCTAssertFalse(s.region(r1)!.livesHere(a),
                       "the card now lives in two regions at once — §4.3's one "
                       + "home is what stops it drawing as a card and as a "
                       + "reference chip simultaneously")
        XCTAssertEqual(CanvasMembership.homeRegion(of: a, in: s), id)
    }

    /// **Sub-question, decided: a HIDDEN card is not taken in.** It is a
    /// resident of a collapsed region and is not drawn at all, so absorbing it
    /// would move something the writer cannot see out of a region they cannot
    /// see into — the one case where "the writer swept around it" is false. Same
    /// reasoning that keeps a collapsed region off `joinTarget`'s target list,
    /// arriving from the other end.
    func test_aSweepDoesNotTakeInACardHiddenInsideACollapsedRegion() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        let swept = CGRect(x: 50, y: 50, width: 400, height: 300)
        XCTAssertEqual(CanvasInteraction.absorbedNodes(by: swept, in: s), [a],
                       "control: while r1 is open, 'a' is absorbed — so the "
                       + "assertion below is about collapsing and nothing else")

        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertEqual(CanvasInteraction.absorbedNodes(by: swept, in: s), [],
                       "a card hidden inside a collapsed region was moved out of "
                       + "it by a sweep the writer could not see it under")
    }

    /// An unmeasured card has no frame and therefore no centre, and nothing the
    /// writer could have swept around either — it is not on screen yet.
    func test_aSweepDoesNotTakeInAnUnmeasuredCard() {
        var s = scene()
        s.insert(CanvasNode(id: CanvasNodeID("new"), kind: .scrap,
                            origin: CGPoint(x: 100, y: 100), width: 240,
                            cachedHeight: nil))
        XCTAssertEqual(CanvasInteraction.absorbedNodes(
            by: CGRect(x: 0, y: 0, width: 400, height: 300), in: s), [a],
                       "the unmeasured card joined on the strength of an origin "
                       + "that says nothing about where it will be drawn")
    }

    // MARK: - What a sweep CATCHES, and what it decides to do about it
    //
    // §4.1's amendment of 2026-08-03, after Denver's smoke: a sweep across a
    // board that already had regions on it minted a third rectangle over the
    // top and absorbed their cards out of them. *"It literally makes zero sense
    // as a user experience."* The ruling is one formula used twice — the sweep
    // asks the centre question of everything it passes over, regions included —
    // and `sweepOutcome` is the routing, asked here over every input that
    // changes its answer.

    /// The centre decides for a region exactly as it does for a card, and both
    /// directions are asserted for the reason the card version gives: "catches
    /// everything it touches" and "catches nothing" both pass a one-sided one.
    func test_aSweepCatchesTheRegionsWhoseCentreItCovers() {
        let s = scene()
        // r1 is (0,0)–(600,400), centre (300,200).
        XCTAssertEqual(CanvasInteraction.caughtRegions(
            by: CGRect(x: 100, y: 100, width: 400, height: 300), in: s), [r1])
        XCTAssertEqual(CanvasInteraction.caughtRegions(
            by: CGRect(x: 2_000, y: 2_000, width: 400, height: 300), in: s), [])
    }

    /// A region the sweep only clips keeps its binding — the same answer the
    /// card version gives, and the same answer to §4.2's one-pixel absurdity.
    func test_aSweepThatOnlyClipsARegionDoesNotCatchIt() {
        let s = scene()
        // Covers r1's left third and stops well short of its centre at x = 300.
        XCTAssertEqual(CanvasInteraction.caughtRegions(
            by: CGRect(x: 0, y: 0, width: 200, height: 500), in: s), [],
                       "a sweep that merely overlaps a region claimed it")
    }

    /// **The anti-drift assertion, and it is what "one formula" means in code.**
    ///
    /// A card and a region are given the IDENTICAL rectangle, so any difference
    /// in the two answers is a difference in the formula and can be nothing
    /// else. Both callers go through `CanvasInteraction.isCaught`; re-spell
    /// either one and a row here parts company.
    ///
    /// The two controls are what stop it being unfalsifiable: a predicate that
    /// always said no, or always yes, would satisfy every equality below.
    func test_theSweepAsksTheSameCentreQuestionOfACardAndOfARegion() {
        // (100,100)–(340,180), centre (220,140).
        let shape = CGRect(x: 100, y: 100, width: 240, height: 80)
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: shape.origin,
                            width: shape.width, cachedHeight: shape.height))
        s.insertRegion(CanvasRegion(id: r1, label: "", frame: shape))

        let wellInside = CGRect(x: 0, y: 0, width: 400, height: 300)
        let nowhereNear = CGRect(x: 2_000, y: 2_000, width: 400, height: 300)
        XCTAssertEqual(CanvasInteraction.caughtRegions(by: wellInside, in: s), [r1],
                       "control: this rect must catch, or every equality below is "
                       + "satisfied by a predicate that always says no")
        XCTAssertEqual(CanvasInteraction.caughtRegions(by: nowhereNear, in: s), [],
                       "control: this rect must NOT catch, or every equality below "
                       + "is satisfied by a predicate that always says yes")

        let rects: [CGRect] = [
            wellInside,
            nowhereNear,
            shape,                                             // exactly the frame
            CGRect(x: 0, y: 0, width: 200, height: 300),       // clips it, centre out
            CGRect(x: 219, y: 139, width: 2, height: 2),       // just the centre
            CGRect(x: 221, y: 141, width: 400, height: 400),   // starts one past it
        ]
        for rect in rects {
            XCTAssertEqual(CanvasInteraction.absorbedNodes(by: rect, in: s).contains(a),
                           CanvasInteraction.caughtRegions(by: rect, in: s).contains(r1),
                           "the card and the region occupy the same rectangle, and "
                           + "\(rect) caught one but not the other — §4.1 is ONE "
                           + "formula used twice and the two spellings have drifted")
        }
    }

    /// **No exclusions, unlike `absorbedNodes`** — and a collapsed region is the
    /// case that tests it. It is still drawn (a counted label bar the writer
    /// swept over), and binding it moves nothing and hides nothing, so there is
    /// nothing for an exclusion to protect. The card version skips a HIDDEN card
    /// because absorbing it would move something invisible out of somewhere
    /// invisible; no such cost exists here.
    func test_aSweepCatchesACollapsedRegion() {
        var s = scene()
        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertEqual(CanvasInteraction.caughtRegions(
            by: CGRect(x: 100, y: 100, width: 400, height: 300), in: s), [r1],
                       "a collapsed region was skipped: its bar is on screen and "
                       + "the writer swept over it, and binding it neither moves "
                       + "nor hides anything")
    }

    /// **The finding itself, at the level that decides it.** The sweep caught a
    /// region, so that region binds and nothing is created.
    func test_aSweepThatCatchesARegionAssignsRatherThanCreates() {
        XCTAssertEqual(CanvasInteraction.sweepOutcome(
            for: CGRect(x: 100, y: 100, width: 400, height: 300),
            subject: .piece("ch1"), in: scene()),
                       .bind(regions: [r1], toPiece: "ch1"),
                       "the sweep passed over a region and still asked for a new "
                       + "one — a third rectangle laid over what was already there")
    }

    /// **Every region it passed over, not just the first.** One act, and the
    /// projection already unions across regions, so all of them are one piece's
    /// context.
    func test_aSweepCatchesEveryRegionItPassesOver() {
        var s = scene()
        let r2 = CanvasRegionID("r2")
        // Centre (900,200) — inside the rect below, well clear of r1.
        s.insertRegion(CanvasRegion(id: r2, label: "Act III",
                                    frame: CGRect(x: 800, y: 100, width: 200, height: 200)))
        XCTAssertEqual(CanvasInteraction.sweepOutcome(
            for: CGRect(x: 0, y: 0, width: 1_200, height: 600),
            subject: .piece("ch1"), in: s),
                       .bind(regions: [r1, r2], toPiece: "ch1"))
    }

    /// §4's row three, unchanged: nothing was caught, so a region is minted and
    /// bound.
    func test_aSweepThatCatchesNoRegionCreatesAndBinds() {
        XCTAssertEqual(CanvasInteraction.sweepOutcome(
            for: CGRect(x: 2_000, y: 2_000, width: 400, height: 300),
            subject: .piece("ch1"), in: scene()),
                       .create(bindingTo: "ch1"))
    }

    /// **The undimmed board is untouched** (§4.1). With nothing selected there
    /// is nothing to bind to, so a sweep is a plain region draw — *even when it
    /// passes straight over a region*, which is the case the assign path could
    /// leak into.
    func test_aSweepOnAnUndimmedBoardCreatesEvenWhenItCatchesARegion() {
        XCTAssertEqual(CanvasInteraction.sweepOutcome(
            for: CGRect(x: 100, y: 100, width: 400, height: 300),
            subject: .wholeProject, in: scene()),
                       .create(bindingTo: nil),
                       "the project row bound something, or refused to draw: on an "
                       + "undimmed board a sweep is just a sweep")
    }

    /// **A group makes a plain region** — §4.1's one deliberate exception, and it
    /// holds over a region as well as over bare canvas. A `boundPieceID` holds a
    /// document id, so there is nothing a group's sweep could bind to.
    func test_aSweepWithAGroupSelectedCreatesEvenWhenItCatchesARegion() {
        XCTAssertEqual(CanvasInteraction.sweepOutcome(
            for: CGRect(x: 100, y: 100, width: 400, height: 300),
            subject: .group(["ch1", "ch2"]), in: scene()),
                       .create(bindingTo: nil),
                       "a sweep under a GROUP bound a region to one of the group's "
                       + "chapters, or to the group — the canvas picked a piece the "
                       + "writer never named")
    }

    /// **Sub-question, decided: a region already bound to ANOTHER document is
    /// re-bound, not skipped.**
    ///
    /// The same ruling `absorbedNodes` made on the card version of this question
    /// on 2026-07-28, for the same reason: skipping the ones already spoken for
    /// gives a sweep that claimed some of what it passed over and not the rest,
    /// with nothing on screen to say which — and the undim, which is *the only
    /// confirmation the gesture gives*, would then be lit for the ones that took
    /// and dim for the ones that did not, with no way to tell that from a miss.
    /// You swept it, you meant it; and one ⌘Z puts it back.
    func test_aSweepReclaimsARegionBoundToAnotherDocument() {
        var s = scene()
        RegionBinding.bind(r1, toPiece: "ch2", in: &s)
        XCTAssertEqual(CanvasInteraction.sweepOutcome(
            for: CGRect(x: 100, y: 100, width: 400, height: 300),
            subject: .piece("ch1"), in: s),
                       .bind(regions: [r1], toPiece: "ch1"),
                       "the sweep passed over a region bound elsewhere and left it "
                       + "alone — a silent no-op with the dim unchanged, which reads "
                       + "on screen exactly like a sweep that missed")
    }

    /// A new region takes the rect it was swept, not a default one — otherwise
    /// the writer sweeps out an area and gets a box somewhere else.
    func test_aNewRegionTakesTheSweptRect() {
        var s = scene()
        let rect = CGRect(x: 1_000, y: 1_000, width: 300, height: 250)
        let id = CanvasInteraction.createRegion(rect, in: &s)!
        XCTAssertEqual(s.region(id)?.frame, rect)
    }

    // MARK: - Drop to join

    func test_droppingACardIntoARegionJoinsIt() {
        var s = scene()
        s.move(b, to: CGPoint(x: 200, y: 200))
        XCTAssertEqual(CanvasInteraction.joinTarget(for: b, in: s), r1)
    }

    func test_aCardWhoseMiddleIsOutsideDoesNotJoin() {
        var s = scene()
        // Overlapping by 20pt of a 240pt card: its centre is well outside.
        s.move(b, to: CGPoint(x: 580, y: 200))
        XCTAssertNil(CanvasInteraction.joinTarget(for: b, in: s),
                     "corner-based targeting is the one-pixel absurdity §4.2 cites")
    }

    /// **The ids are chosen so an id-order tiebreak gives the WRONG answer.**
    /// `wide` covers the whole card and `narrow` clips it, and `narrow` sorts
    /// last — so an implementation that broke the tie on id alone, or that took
    /// the last region it found, would return `narrow` and fail here. Written
    /// against a bespoke scene rather than the shared fixture because r1
    /// contains this card entirely too, which would make the overlaps equal and
    /// the assertion vacuous.
    func test_overlappingRegionsBreakTheTieOnGreatestOverlap() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 200, y: 200),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("a-wide"), label: "Wide",
                                    frame: CGRect(x: 150, y: 150, width: 400, height: 300)))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("z-narrow"), label: "Narrow",
                                    frame: CGRect(x: 300, y: 150, width: 200, height: 300)))
        // Centre is (320, 240): inside both. Overlap with the card is the whole
        // 240×80 for 'a-wide' and 140×80 for 'z-narrow'.
        XCTAssertEqual(CanvasInteraction.joinTarget(for: b, in: s), CanvasRegionID("a-wide"))
    }

    /// **Two regions that both CONTAIN the card overlap it identically**, so
    /// overlap cannot decide and the tiebreak is the whole answer. The smaller
    /// region wins, because that is the one `regionHit` would grab — and a card
    /// that joins a region a click at the same spot would not pick up is two
    /// rules disagreeing about which region the writer is pointing at.
    ///
    /// Asked twice with the ids MIRRORED, which is what makes it an assertion
    /// about size rather than about ids: a tiebreak on the largest id passes the
    /// first fixture and fails the second, one on the smallest id does the
    /// reverse, and only "the smaller region" passes both.
    func test_aCardInsideTwoRegionsJoinsTheSmallerOne() {
        func target(smallID: String, bigID: String) -> CanvasRegionID? {
            var s = CanvasScene()
            s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 200, y: 200),
                                width: 240, cachedHeight: 80))
            // Both contain the card (200,200)–(440,280) entirely.
            s.insertRegion(CanvasRegion(id: CanvasRegionID(smallID), label: "Small",
                                        frame: CGRect(x: 150, y: 150, width: 400, height: 400)))
            s.insertRegion(CanvasRegion(id: CanvasRegionID(bigID), label: "Big",
                                        frame: CGRect(x: 0, y: 0, width: 900, height: 900)))
            return CanvasInteraction.joinTarget(for: b, in: s)
        }
        XCTAssertEqual(target(smallID: "z-small", bigID: "a-big"), CanvasRegionID("z-small"))
        XCTAssertEqual(target(smallID: "a-small", bigID: "z-big"), CanvasRegionID("a-small"))
    }

    /// The same rule the grab uses, asked of both functions at once. They are
    /// two answers to "which region is the writer pointing at" and they must not
    /// differ — `regionHit` is the visible one, so `joinTarget` follows it.
    func test_theDropAndTheGrabAgreeAboutWhichRegionIsMeant() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 200, y: 200),
                            width: 240, cachedHeight: 80))
        let small = CanvasRegionID("z-small"), big = CanvasRegionID("a-big")
        s.insertRegion(CanvasRegion(id: small, label: "Small",
                                    frame: CGRect(x: 150, y: 150, width: 400, height: 400)))
        s.insertRegion(CanvasRegion(id: big, label: "Big",
                                    frame: CGRect(x: 0, y: 0, width: 900, height: 900)))
        // A point on BOTH chrome bars is impossible — they are at different y —
        // so this asks the question the writer's pointer asks: at the small
        // region's own bar, both rules must name the small region.
        XCTAssertEqual(CanvasInteraction.regionHit(at: CGPoint(x: 300, y: 158), in: s),
                       .chrome(small))
        XCTAssertEqual(CanvasInteraction.joinTarget(for: b, in: s), small,
                       "the drop and the grab disagree: a click at the small "
                       + "region's bar picks it up, and dropping a card in the same "
                       + "place puts the card in the big one")
    }

    /// **A collapsed region is not a drop target.** Its residents are not drawn,
    /// so the writer cannot see what they would be joining — and joining would
    /// put the card straight into `hiddenNodes`, i.e. the card vanishes in the
    /// same gesture that dropped it. Unreachable until Task 7 ships the toggle,
    /// and cheaper to refuse now than to explain later.
    func test_aCollapsedRegionIsNotADropTarget() {
        var s = scene()
        s.move(b, to: CGPoint(x: 200, y: 200))
        XCTAssertEqual(CanvasInteraction.joinTarget(for: b, in: s), r1,
                       "control: it IS a target while the region is open, so the "
                       + "assertion below is about collapsing and nothing else")

        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertNil(CanvasInteraction.joinTarget(for: b, in: s),
                     "a card dropped into a collapsed region joins it and "
                     + "disappears into the hidden set in the same gesture — the "
                     + "writer is left with no account of where their card went")
    }

    func test_droppingACardOutsideEveryRegionDoesNotRemoveItFromItsHome() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.move(a, to: CGPoint(x: 5_000, y: 5_000))
        XCTAssertNil(CanvasInteraction.joinTarget(for: a, in: s))
        XCTAssertTrue(s.region(r1)!.livesHere(a),
                      "removal is always its own act (§4.2) — the tether is what "
                      + "makes this state legible")
    }

    /// An unmeasured card has no frame, so it has no centre to test. Answering
    /// anything but `nil` here means reading `CGRect.null`'s infinities, and
    /// `CGRect.contains` says a null rect's centre is nowhere.
    func test_anUnmeasuredCardJoinsNothing() {
        var s = scene()
        s.insert(CanvasNode(id: CanvasNodeID("new"), kind: .scrap,
                            origin: CGPoint(x: 200, y: 200), width: 240,
                            cachedHeight: nil))
        XCTAssertNil(CanvasInteraction.joinTarget(for: CanvasNodeID("new"), in: s))
    }
}
