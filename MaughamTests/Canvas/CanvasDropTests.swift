import XCTest
@testable import Maugham

/// **The writer's own route onto the canvas** (spec §8A.1): a research item
/// dragged out of the binder and dropped on the canvas becomes an item node.
///
/// Everything here is asked of `CanvasDrop` rather than of the view, and that is
/// forced rather than chosen. SwiftUI's drop delivery has no seam to post a drag
/// session into — `CanvasEventNSView.applyMouseDown` gives the mouse one and
/// there is no equivalent for a drop — so the *decision* and the *apply* are a
/// pure function and a model verb, tested here, and the fact that
/// `CanvasView.body` actually mounts the modifier is pinned by
/// `PromotionCommandTests.test_theCanvasWiringCensusNamesEveryProductionSite`.
/// A router with no modifier on it would be this area's fifth
/// built-and-unreachable half.
///
/// Three failures shape the file:
///
/// - **A second drop of the same item overwriting the first.**
///   `CanvasNodeID.item(_:)` derives the id from the reference and
///   `CanvasScene.insert` is keyed by id, so a re-insert silently discards the
///   node's membership, mark, width, z and author — and looks exactly like
///   nothing happening.
/// - **A card that lands unmeasured.** A node with no `cachedHeight` has no
///   `frame`, and `nodes(intersecting:)` and `topmostNode(at:)` both drop one —
///   neither drawn nor clickable, persisted that way. That is 1C-c3's
///   whole-branch Critical, and a new creation route is the door it arrives
///   through next.
/// - **A drop that registers no undo step of its own.** A drag that starts in
///   the binder never reaches `CanvasView.handleClick`, so it cannot close an
///   "Edit Scrap" gesture the writer is holding open — tripwire 32, from a fifth
///   direction.
@MainActor
final class CanvasDropTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Fixtures

    private let noteID = "res-note"
    private let secondNoteID = "res-second"
    private let groupID = "res-group"

    /// Three entries: an ordinary note, a second one for the control that proves
    /// dropping still works, and a research GROUP — which this router accepts on
    /// purpose (see `CanvasDrop.decide`).
    private func index() -> CanvasItemIndex {
        CanvasItemIndex(entriesByID: [
            noteID: .init(title: "The falls at night", kind: .researchNote),
            secondNoteID: .init(title: "The lit bridge", kind: .researchNote),
            groupID: .init(title: "Act II", kind: .group),
        ])
    }

    /// An attached model on an empty project directory.
    ///
    /// `attach` is what wires `CanvasUndo`'s two closures (`CanvasModel.attach`),
    /// so a model that was never attached records no snapshots and every undo
    /// assertion below would pass for the wrong reason.
    private func attachedModel() -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.undoManager.groupsByEvent = false
        return model
    }

    /// A region at (100, 100)–(500, 400). A card dropped with its ORIGIN at
    /// (381, 150) has its centre at (501, 167) — one point past the right edge,
    /// with the origin itself still comfortably inside. That is the corner-test
    /// discriminator §4.2 cites against Obsidian, in one fixture.
    private let regionID = CanvasRegionID("r1")
    private let regionFrame = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func withRegion(_ model: CanvasModel) {
        model.withScene(persist: false) {
            $0.insertRegion(CanvasRegion(id: regionID, label: "Act II fog",
                                         frame: regionFrame))
        }
    }

    /// The centre of the card a drop at `origin` makes, given the label-only
    /// floor every item node is born at. Written once so the two membership tests
    /// cannot disagree about where the centre is.
    private func centre(ofCardDroppedAt origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + CanvasInteraction.defaultScrapWidth / 2,
                y: origin.y + CanvasCardMetrics.itemLabelOnlyHeight / 2)
    }

    // MARK: - The decision, over the whole product

    /// **The router, asked over every combination it decides on.**
    ///
    /// Three inputs: whether the payload is in the index, whether a node for it is
    /// already in the scene, and whether the drop point is inside a region. The
    /// third is in the table for a reason that is easy to mistake for padding:
    /// the decision must be **independent** of it. Deciding *which* region a drop
    /// meant is the gesture's job and recording it is `CanvasMembership`'s — no
    /// function in that file takes a point, a rect or an overlap — so a router
    /// that started reading region geometry would be the first crack in §4.2's
    /// separation, and this table is where that shows up.
    func test_theRouterDecidesTheWholeProduct() {
        struct Case {
            let name: String
            let payload: String
            let alreadyOnCanvas: Bool
            let insideARegion: Bool
            let expected: CanvasDrop.Decision
        }

        let known = noteID
        let unknown = "piece-3f2a"          // a manuscript piece id — see `decide`
        let existingID = CanvasNodeID.item(known)
        let inside = CGPoint(x: 200, y: 150)
        let outside = CGPoint(x: 900, y: 900)

        let cases: [Case] = [
            .init(name: "known id, empty canvas, over bare ground",
                  payload: known, alreadyOnCanvas: false, insideARegion: false,
                  expected: .create(CanvasNode(id: existingID,
                                               kind: .item(.project(id: known)),
                                               origin: outside,
                                               width: CanvasInteraction.defaultScrapWidth,
                                               cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight,
                                               z: 1))),
            .init(name: "known id, empty canvas, over a region",
                  payload: known, alreadyOnCanvas: false, insideARegion: true,
                  expected: .create(CanvasNode(id: existingID,
                                               kind: .item(.project(id: known)),
                                               origin: inside,
                                               width: CanvasInteraction.defaultScrapWidth,
                                               cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight,
                                               z: 1))),
            .init(name: "known id already on the canvas, over bare ground",
                  payload: known, alreadyOnCanvas: true, insideARegion: false,
                  expected: .reveal(existingID)),
            .init(name: "known id already on the canvas, over a region",
                  payload: known, alreadyOnCanvas: true, insideARegion: true,
                  expected: .reveal(existingID)),
            .init(name: "unknown id, empty canvas, over bare ground",
                  payload: unknown, alreadyOnCanvas: false, insideARegion: false,
                  expected: .ignored),
            .init(name: "unknown id, empty canvas, over a region",
                  payload: unknown, alreadyOnCanvas: false, insideARegion: true,
                  expected: .ignored),
            .init(name: "unknown id, a node already present, over bare ground",
                  payload: unknown, alreadyOnCanvas: true, insideARegion: false,
                  expected: .ignored),
            .init(name: "unknown id, a node already present, over a region",
                  payload: unknown, alreadyOnCanvas: true, insideARegion: true,
                  expected: .ignored),
        ]

        for c in cases {
            var scene = CanvasScene()
            if c.insideARegion {
                scene.insertRegion(CanvasRegion(id: regionID, label: "Act II fog",
                                                frame: regionFrame))
            }
            if c.alreadyOnCanvas {
                scene.insert(CanvasNode(id: existingID, kind: .item(.project(id: known)),
                                        origin: CGPoint(x: 10, y: 10), width: 240,
                                        cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight,
                                        z: 1))
            }
            let point = c.insideARegion ? inside : outside
            XCTAssertEqual(
                CanvasDrop.decide(payload: c.payload, at: point,
                                  in: scene, index: index()),
                c.expected,
                "\(c.name)")
        }
    }

    /// The group ruling, out loud, because two neighbouring rulings read as if
    /// they disagree with it. `AddCanvasScrapsTool` REFUSES a group id — a folder
    /// is not a page a batch of scraps was read off — and this accepts one,
    /// because the writer is pointing at a folder sitting in their own binder and
    /// `CanvasItemKind.group` was built (Task 4) for exactly that card.
    ///
    /// **The control is the entry, not the id**: the same payload with no entry in
    /// the index is refused, so this cannot pass by everything being accepted.
    func test_aResearchGroupIsAcceptedWhereClaudesOwnToolRefusesOne() {
        let accepted = CanvasDrop.decide(payload: groupID, at: .zero,
                                         in: CanvasScene(), index: index())
        XCTAssertEqual(accepted, .create(CanvasNode(
            id: .item(groupID), kind: .item(.project(id: groupID)), origin: .zero,
            width: CanvasInteraction.defaultScrapWidth,
            cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight, z: 1)),
            "a research group the writer can see in their binder makes a card — "
            + "Task 4's ruling was that 'no longer in the project' said over a "
            + "visible folder is a lie")
        XCTAssertEqual(
            CanvasDrop.decide(payload: groupID, at: .zero, in: CanvasScene(),
                              index: CanvasItemIndex(entriesByID: [:])),
            .ignored,
            "control: the acceptance is the INDEX ENTRY's doing, not a router "
            + "that says yes to everything")
    }

    /// An id in no manifest creates nothing.
    ///
    /// The binder drags manuscript pieces and tasks with the same raw-id payload,
    /// and a node made for one of those would draw `CanvasItemFacts.missingTitle`
    /// — "No longer in the project." — from birth: a card the writer can neither
    /// fix nor explain.
    ///
    /// **Control:** the same payload, with an entry added to the index, does
    /// create one. Without it the assertion passes just as well under a router
    /// that creates nothing at all.
    func test_anIdInNoIndexCreatesNothingAndTheSameIdWithAnEntryDoes() {
        let stranger = "piece-3f2a"
        XCTAssertEqual(
            CanvasDrop.decide(payload: stranger, at: CGPoint(x: 5, y: 5),
                              in: CanvasScene(), index: index()),
            .ignored,
            "a payload in no manifest must not become a card that reads 'No "
            + "longer in the project.' from birth")

        let widened = CanvasItemIndex(entriesByID: [
            stranger: .init(title: "Chapter One", kind: .researchNote),
        ])
        guard case .create(let node) = CanvasDrop.decide(
            payload: stranger, at: CGPoint(x: 5, y: 5), in: CanvasScene(),
            index: widened) else {
            return XCTFail("control: the SAME id with an index entry must create a "
                           + "node, or the refusal above proves nothing")
        }
        XCTAssertEqual(node.id, .item(stranger))
    }

    // MARK: - What lands on the canvas

    /// **A dropped card is drawn and clickable, which means it is MEASURED.**
    ///
    /// A node with no `cachedHeight` has no `frame`, and both projections drop
    /// one: it is on the canvas, invisible to the renderer's cull and invisible
    /// to hit testing, and it saves that way. Both are asserted because the
    /// 1C-c3 Critical was dropped by both.
    func test_aDroppedCardIsMeasuredSoItIsDrawnAndClickable() throws {
        let model = attachedModel()
        guard case .create(let node) = CanvasDrop.decide(
            payload: noteID, at: CGPoint(x: 200, y: 150),
            in: model.scene, index: index()) else {
            return XCTFail("precondition: a known id over an empty canvas creates")
        }
        CanvasDrop.apply(node, in: model)

        let landed = try XCTUnwrap(model.scene.node(node.id), "the card is on the canvas")
        XCTAssertNotNil(landed.cachedHeight,
                        "an unmeasured node has no frame, so it is neither drawn "
                        + "nor clickable — and it persists that way")
        XCTAssertEqual(landed.cachedHeight, CanvasCardMetrics.itemLabelOnlyHeight,
                       "the floor is the honest height until the thumbnail decodes")
        let frame = try XCTUnwrap(landed.frame)
        XCTAssertTrue(model.scene.nodes(intersecting: frame.insetBy(dx: -1, dy: -1))
                        .contains(where: { $0.id == node.id }),
                      "the renderer culls on this projection: a card missing from "
                      + "it is a card that is never drawn")
        XCTAssertEqual(model.scene.topmostNode(at: CGPoint(x: frame.midX, y: frame.midY))?.id,
                       node.id,
                       "hit testing reads the other projection: a card missing from "
                       + "it cannot be clicked, selected or deleted")
    }

    /// Dropped so its CENTRE is inside a region, the card lives there.
    ///
    /// A drop is one of exactly two legitimate geometric readings on this surface
    /// (the other is a sweep at creation), and it reads the centre through
    /// `CanvasInteraction.joinTarget` — the existing spelling — rather than a
    /// second `region.frame.contains(…)` written here.
    func test_aCardDroppedWithItsCentreInsideARegionLivesThere() throws {
        let model = attachedModel()
        withRegion(model)
        let origin = CGPoint(x: 200, y: 150)
        XCTAssertTrue(regionFrame.contains(centre(ofCardDroppedAt: origin)),
                      "precondition: this fixture's card centre really is inside")

        guard case .create(let node) = CanvasDrop.decide(
            payload: noteID, at: origin, in: model.scene, index: index()) else {
            return XCTFail("precondition: a known id creates")
        }
        CanvasDrop.apply(node, in: model)

        XCTAssertEqual(CanvasMembership.homeRegion(of: node.id, in: model.scene), regionID,
                       "a card dropped inside a region belongs to it — creation "
                       + "absorbs (§4.2's amendment)")
    }

    /// The corner test, refused. The card's ORIGIN is inside the region and its
    /// CENTRE is one point past the right edge, so a `contains(node.origin)`
    /// would join and the shipped rule does not. That difference is the one §4.2
    /// cites against Obsidian, and it is the whole reason the fixture is built
    /// this way rather than by dropping somewhere obviously outside.
    func test_aCardWhoseCentreLandsOnePointOutsideTheRegionIsHomeless() throws {
        let model = attachedModel()
        withRegion(model)
        let origin = CGPoint(x: 381, y: 150)
        XCTAssertTrue(regionFrame.contains(origin),
                      "precondition: the card's ORIGIN is inside the region, so a "
                      + "corner test would join it")
        XCTAssertFalse(regionFrame.contains(centre(ofCardDroppedAt: origin)),
                       "precondition: its CENTRE is outside, by one point")

        guard case .create(let node) = CanvasDrop.decide(
            payload: noteID, at: origin, in: model.scene, index: index()) else {
            return XCTFail("precondition: a known id creates")
        }
        CanvasDrop.apply(node, in: model)

        XCTAssertNil(CanvasMembership.homeRegion(of: node.id, in: model.scene),
                     "the centre decides, not the corner — a card poking one pixel "
                     + "into a region does not join it")
        // TWO controls, because the negative above has two ways to be true for the
        // wrong reason, and the second was found by running this file's own
        // measurement disable experiment: with the card born UNMEASURED it has no
        // frame, `joinTarget` returns nil for every drop everywhere, and this test
        // went on passing while the sibling test and the Critical's own test both
        // went red. A homelessness assertion that cannot tell "the centre was
        // outside" from "there was no centre" is not asserting the centre rule.
        let landed = try XCTUnwrap(model.scene.node(node.id),
                                   "control: the card was made — the assertion "
                                   + "above must not pass by nothing landing")
        XCTAssertNotNil(landed.frame,
                        "control: and it was MEASURED, so it HAD a centre to test. "
                        + "Unmeasured, `joinTarget` returns nil for every node on "
                        + "every canvas and the assertion above is vacuous")
    }

    // MARK: - The failure this file exists for

    /// **A second drop of an item already on the canvas changes that card in no
    /// way at all.**
    ///
    /// `CanvasScene.insert` is keyed by id and `CanvasNodeID.item(_:)` is derived
    /// from the reference, so the naive route overwrites — and every one of the
    /// five fields below is silently lost. Moving the card to the new drop point
    /// is not the alternative either: that is a geometry-driven change to
    /// something the writer placed.
    ///
    /// **Control:** a drop of a DIFFERENT id in the same test does create a second
    /// node, so the five equalities cannot be satisfied by drops being broken.
    func test_aSecondDropOfTheSameItemLeavesThatCardExactlyAsItWas() throws {
        let model = attachedModel()
        withRegion(model)
        let id = CanvasNodeID.item(noteID)
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: id, kind: .item(.project(id: noteID)),
                                 origin: CGPoint(x: 200, y: 150), width: 300,
                                 cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight,
                                 z: 7, promotedItemID: "art-1", author: .claude))
            CanvasMembership.join(id, home: regionID, in: &$0)
        }
        let before = try XCTUnwrap(model.scene.node(id))
        let homeBefore = CanvasMembership.homeRegion(of: id, in: model.scene)

        let decision = CanvasDrop.decide(payload: noteID, at: CGPoint(x: 900, y: 900),
                                         in: model.scene, index: index())
        XCTAssertEqual(decision, .reveal(id),
                       "a second drop reveals the card that is already there")
        if case .create(let node) = decision { CanvasDrop.apply(node, in: model) }

        let after = try XCTUnwrap(model.scene.node(id))
        XCTAssertEqual(after.origin, before.origin, "its position is the writer's")
        XCTAssertEqual(after.width, before.width, "its width is the writer's")
        XCTAssertEqual(after.z, before.z, "its z is the writer's")
        XCTAssertEqual(after.promotedItemID, before.promotedItemID,
                       "its promotion mark survives — an overwrite loses it, and "
                       + "the mark is what `Promotion.existingArtifact` reads")
        XCTAssertEqual(after.author, before.author,
                       "whose hand made it survives (there is no verb for clearing "
                       + "an author, so an overwrite is the only way to lose one)")
        // Kept, and honestly annotated: this one is NOT falsified by the overwrite
        // itself. `CanvasScene.insert` writes only `byID`, so a re-insert leaves
        // the region's home set holding the id and membership survives by
        // accident — measured by removing the `.reveal` branch, where the five
        // assertions above went red and this one did not. It stays because it is
        // the correct expectation and because an overwrite that DID reach
        // `refreshHiddenNodes` or a region set would be caught here.
        XCTAssertEqual(CanvasMembership.homeRegion(of: id, in: model.scene), homeBefore,
                       "its membership survives")

        // The control, in the same test: dropping something ELSE still works, so
        // the six equalities above are not "drops do nothing".
        guard case .create(let other) = CanvasDrop.decide(
            payload: secondNoteID, at: CGPoint(x: 900, y: 900),
            in: model.scene, index: index()) else {
            return XCTFail("control: a DIFFERENT id must still create a node")
        }
        CanvasDrop.apply(other, in: model)
        XCTAssertNotNil(model.scene.node(other.id),
                        "control: a different research item does land a second card")
        XCTAssertEqual(model.scene.unorderedNodes.count, 2)
    }

    // MARK: - Undo

    /// **One drop is one ⌘Z, and the discriminator is the step's NAME.**
    ///
    /// A test whose only observable is the post-⌘Z scene cannot tell "its own
    /// step" from "folded into the neighbouring one" — demonstrated twice in one
    /// slice in this area, both times on a nesting bug. `undoMenuItemTitle` is the
    /// AppKit-computed title of the top registered group, which is also what the
    /// writer reads in the Edit menu.
    func test_oneDropIsOneNamedUndoStep() throws {
        let model = attachedModel()
        let before = model.scene
        guard case .create(let node) = CanvasDrop.decide(
            payload: noteID, at: CGPoint(x: 200, y: 150),
            in: model.scene, index: index()) else {
            return XCTFail("precondition: a known id creates")
        }
        CanvasDrop.apply(node, in: model)

        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains(CanvasDrop.undoStepName),
                      "the drop must be its own NAMED step — a bare \"Undo\" is a "
                      + "drop that registered nothing of its own. found: "
                      + model.undoManager.undoMenuItemTitle)
        model.undo.undo()
        XCTAssertEqual(model.scene, before, "one ⌘Z takes the card back")
        XCTAssertFalse(model.undoManager.canUndo,
                       "…and there was exactly one step to take back")
    }

    /// **The tripwire-32 repro this route adds, and the reason the drop uses the
    /// outside verb.**
    ///
    /// A drag that starts in the binder never reaches `CanvasView.handleClick`,
    /// which is the only thing that runs `commitActiveEdit` — so the writer can be
    /// inside a scrap with "Edit Scrap" held open when the drop lands, and
    /// **nothing on either side closes their bracket**. Through the inside verbs
    /// the drop nests: `beginGesture` takes no snapshot at depth 2 and
    /// `endGesture` registers nothing above depth 0, so the card reaches no undo
    /// step of its own and rides into the writer's next sentence — a ⌘Z aimed at
    /// that sentence takes the card with it.
    ///
    /// The name assertion is what sees the nesting; the two-step assertion after
    /// it is what the writer actually experiences.
    func test_aDropWhileTheWriterIsInsideAScrapIsItsOwnStep() throws {
        let model = attachedModel()
        let scrapID = CanvasNodeID("s1")
        model.mutate("New Scrap") {
            $0.insert(CanvasNode(id: scrapID, kind: .scrap, origin: .zero,
                                 width: 240, cachedHeight: 38))
        }
        // The writer is in the scrap and typing. This is the bracket nothing on
        // the binder's side of the drag can close.
        model.beginGesture("Edit Scrap")
        model.setScrapText("the falls at night", for: scrapID)

        guard case .create(let node) = CanvasDrop.decide(
            payload: noteID, at: CGPoint(x: 400, y: 400),
            in: model.scene, index: index()) else {
            return XCTFail("precondition: a known id creates")
        }
        CanvasDrop.apply(node, in: model)

        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains(CanvasDrop.undoStepName),
                      "the drop registered no step of its own — it nested inside "
                      + "\"Edit Scrap\" and will ride into the writer's next "
                      + "sentence (tripwire 32). found: "
                      + model.undoManager.undoMenuItemTitle)

        // The writer clicks away, closing the visit they resumed.
        model.endGesture()
        model.undo.undo()
        XCTAssertNil(model.scene.node(node.id),
                     "the first ⌘Z takes back the card")
        XCTAssertEqual(model.scraps[scrapID], "the falls at night",
                       "…and leaves the sentence alone. Nested, one ⌘Z takes both, "
                       + "which is the failure the outside verb exists to prevent")
        model.undo.undo()
        XCTAssertNil(model.scraps[scrapID],
                     "the writer's own typing is the step underneath, still there "
                     + "to be taken back separately")
    }
}
