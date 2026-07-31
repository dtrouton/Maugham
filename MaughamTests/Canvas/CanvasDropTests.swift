import AppKit
import UniformTypeIdentifiers
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

    // MARK: - The external route (1C-d Task 11, spec §8A.1)

    /// A recording stand-in for `ProjectStore.ingestCanvasAsset(fileURL:)` /
    /// `(image:)`.
    ///
    /// **The seam exists so the ROUTING is testable, not so the ingestion is
    /// faked** — the ingestion itself has its own tests over the real store
    /// (`CanvasAssetIngestionTests`), and two of the tests below drive the real
    /// pair. What no other test can see is *which twin a given drag reaches*,
    /// which is the whole of what this task added around `DropClassification`.
    @MainActor
    private final class RecordingIngest {
        private(set) var files: [URL] = []
        private(set) var images: [NSImage] = []
        var failEverything = false

        var seam: CanvasAssetIngest {
            CanvasAssetIngest(
                file: { url in
                    self.files.append(url)
                    if self.failEverything { throw Failure() }
                    return "canvas_assets/file-\(self.files.count).png"
                },
                image: { image in
                    self.images.append(image)
                    if self.failEverything { throw Failure() }
                    return "canvas_assets/bitmap-\(self.images.count).png"
                })
        }

        struct Failure: Error {}
    }

    /// A Finder drag: a provider carrying a **file URL**.
    private func fileProvider(_ url: URL) -> NSItemProvider {
        NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
    }

    /// A browser drag: a provider carrying a **rendered bitmap and no file URL**.
    /// This is the drag `.dropDestination(for: URL.self)` silently rejects, which
    /// is the named failure this route exists to avoid.
    private func bitmapProvider() -> NSItemProvider {
        NSItemProvider(object: makeImage())
    }

    /// A drag carrying neither — a remote-URL-only link drag, near enough.
    private func strangerProvider() -> NSItemProvider {
        NSItemProvider(object: "https://example.com/a-page" as NSString)
    }

    private func makeImage(size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemTeal.drawSwatch(in: NSRect(x: 0, y: 0, width: size, height: size))
        image.unlockFocus()
        return image
    }

    /// A real PNG on disk, outside the project — the writer's own file, which the
    /// canvas must **copy** rather than move.
    private func writePNG(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let image = makeImage(size: 16)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RecordingIngest.Failure()
        }
        try png.write(to: url)
        return url
    }

    private func writeText(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try "not a photograph".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func attachedModel(at projectRoot: URL) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: projectRoot)
        model.undoManager.groupsByEvent = false
        return model
    }

    /// **The canvas's USE of the shared classifier, which is the only part of it
    /// this task wrote.** `DropClassification.action` is tested in
    /// `PaletteCardEditorTests` and is not re-tested here; what is asked is that
    /// each answer reaches the right half of the ingestion pair.
    ///
    /// The middle row is the one the whole route exists for: a browser drag has no
    /// file URL, so `.dropDestination(for: URL.self)` rejects it with
    /// CoreTransferable error 0 — nothing logged, nothing red, nothing on screen.
    func test_eachDraggedProviderReachesTheHalfOfTheIngestionPairItNeeds() async throws {
        let png = try writePNG(named: "harbour.png")
        let recorder = RecordingIngest()

        let outcome = await CanvasExternalDrop.ingest(
            providers: [fileProvider(png), bitmapProvider(), strangerProvider()],
            using: recorder.seam)

        XCTAssertEqual(recorder.files, [png],
                       "a Finder drag carries a file URL and must reach the file "
                       + "twin, which preserves the name and the extension")
        XCTAssertEqual(recorder.images.count, 1,
                       "a browser drag carries a rendered bitmap and no file URL — "
                       + "it must reach the image twin. Zero here is the failure "
                       + "this whole route exists to prevent: a drag that appears "
                       + "to do nothing, with nothing logged and nothing red")
        XCTAssertEqual(outcome.paths.count, 2,
                       "two providers were ingestable, and the third — carrying "
                       + "neither a file URL nor an image — must make nothing")
        XCTAssertNil(outcome.message,
                     "a link drag the canvas simply cannot hold is declined by the "
                     + "drop itself; it is not an error to report")
    }

    /// **A provider carrying BOTH (the real Finder shape) takes the file route.**
    /// The on-disk file preserves the original name and extension; re-rendering it
    /// through the bitmap twin would throw both away and re-encode the picture.
    ///
    /// **Control:** the same assertion with the bitmap-only provider, which must
    /// reach the other twin — without it this passes under a router that always
    /// calls the file half.
    func test_aDragCarryingBothAFileUrlAndABitmapTakesTheFile() async throws {
        let png = try writePNG(named: "both.png")
        let provider = NSItemProvider(item: png as NSURL,
                                      typeIdentifier: UTType.fileURL.identifier)
        provider.registerObject(makeImage(), visibility: .all)
        XCTAssertTrue(provider.canLoadObject(ofClass: NSImage.self),
                      "precondition: this fixture really does carry both")

        let recorder = RecordingIngest()
        _ = await CanvasExternalDrop.ingest(providers: [provider], using: recorder.seam)
        XCTAssertEqual(recorder.files, [png])
        XCTAssertTrue(recorder.images.isEmpty)

        let control = RecordingIngest()
        _ = await CanvasExternalDrop.ingest(providers: [bitmapProvider()],
                                            using: control.seam)
        XCTAssertTrue(control.files.isEmpty,
                      "control: a bitmap-only drag must NOT reach the file twin")
        XCTAssertEqual(control.images.count, 1)
    }

    /// **What lands is an OWNED node whose path is project-relative**, driven
    /// through the real `ProjectStore` pair rather than the recording seam.
    ///
    /// All three failure spellings are asserted rather than "it is non-empty":
    /// `CanvasItemReference.owned(path:)` names a leading `./`, a `file://` URL
    /// and a Markdown `![](…)` ref as the three ways to get this wrong, and each
    /// renders nothing while keying the thumbnail cache on a string that differs
    /// between Macs.
    func test_anIngestedPhotographIsAnOwnedNodeWithAProjectRelativePath() async throws {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "CanvasExternalDrop", in: root)
        let store = try await ProjectStore.load(from: projectURL)
        let model = attachedModel(at: projectURL)
        let source = try writePNG(named: "the-falls.png")

        let outcome = await CanvasExternalDrop.ingest(
            providers: [fileProvider(source)],
            using: CanvasAssetIngest(
                file: { try await store.ingestCanvasAsset(fileURL: $0) },
                image: { try await store.ingestCanvasAsset(image: $0) }))
        let made = CanvasExternalDrop.apply(paths: outcome.paths,
                                            at: CGPoint(x: 200, y: 150), in: model)

        let id = try XCTUnwrap(made.first, "the drop made a card")
        let landed = try XCTUnwrap(model.scene.node(id))
        guard case .item(.owned(let path)) = landed.kind else {
            return XCTFail("an ingested photograph exists nowhere else in the "
                           + "project, so it is OWNED — a `.project` reference "
                           + "would point at a manifest entry that does not exist")
        }
        XCTAssertFalse(path.hasPrefix("./"), "leading ./: \(path)")
        XCTAssertFalse(path.hasPrefix("file://"), "a file URL: \(path)")
        XCTAssertFalse(path.contains("!["), "a Markdown image ref: \(path)")
        XCTAssertFalse((path as NSString).isAbsolutePath, "absolute: \(path)")
        XCTAssertTrue(path.hasPrefix("canvas_assets/"), "outside the well: \(path)")

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent(path).path),
            "the path must resolve against the project root — it is the key the "
            + "thumbnail cache and the renderer both read")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "ingesting COPIES: the source is the writer's own file and "
                      + "the canvas must not take it away")

        XCTAssertNotEqual(id, CanvasNodeID.item(path),
                          "an owned node's id is MINTED — a filesystem path in an "
                          + "identity puts tripwire 22's rename hazard in the one "
                          + "field nothing may rewrite (`CanvasNodeID`)")
    }

    /// **A `.txt` dropped on the canvas creates nothing and copies nothing.**
    ///
    /// This is a real hole rather than a hypothetical:
    /// `ImagePasteHandler.saveAndReferenceFile` takes the source extension as
    /// given and validates nothing, so an unchecked drop would copy the file into
    /// `canvas_assets/`, mint an owned node, draw the photograph glyph and queue a
    /// decode that can only fail — and `CanvasThumbnails` **memoises failures**,
    /// so it is one permanent dead cache entry per mistake.
    ///
    /// **Control:** the same drop with a `.png` makes a card and copies a file.
    /// Without it this passes under a route that ingests nothing at all.
    func test_aTextFileMakesNoCardAndCopiesNoFileWhileAPngDoesBoth() async throws {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "CanvasDropRefusal", in: root)
        let store = try await ProjectStore.load(from: projectURL)
        let model = attachedModel(at: projectURL)
        let seam = CanvasAssetIngest(
            file: { try await store.ingestCanvasAsset(fileURL: $0) },
            image: { try await store.ingestCanvasAsset(image: $0) })
        let well = projectURL.appendingPathComponent("canvas_assets")

        let refused = await CanvasExternalDrop.ingest(
            providers: [fileProvider(try writeText(named: "notes.txt"))], using: seam)
        _ = CanvasExternalDrop.apply(paths: refused.paths,
                                     at: CGPoint(x: 10, y: 10), in: model)

        XCTAssertTrue(refused.paths.isEmpty, "a text file is not a photograph")
        XCTAssertTrue(model.scene.unorderedNodes.isEmpty,
                      "a card drawing the photograph glyph over a decode that can "
                      + "only fail is worse than a refusal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: well.path),
                       "nothing was ingested, so the well was never even made")
        XCTAssertNotNil(refused.message,
                        "and the writer is told — a drop that silently does "
                        + "nothing is indistinguishable from a broken surface")

        // Control, in the same test.
        let accepted = await CanvasExternalDrop.ingest(
            providers: [fileProvider(try writePNG(named: "control.png"))], using: seam)
        _ = CanvasExternalDrop.apply(paths: accepted.paths,
                                     at: CGPoint(x: 10, y: 10), in: model)
        XCTAssertEqual(model.scene.unorderedNodes.count, 1,
                       "control: a PNG through the same route DOES make a card")
        XCTAssertNil(accepted.message, "control: and says nothing to the writer")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: well.path).count, 1,
            "control: exactly the one accepted file is in the well")
    }

    /// **Every file in a multi-file drop lands, and no card is exactly on
    /// another.** Cards stacked at one point read as a single card, so a writer
    /// who dragged four photographs in sees one and assumes three were lost.
    func test_everyFileInAMultiFileDropLandsAndNoneIsExactlyOnAnother() async throws {
        let model = attachedModel()
        let recorder = RecordingIngest()
        let providers = try (1...3).map { fileProvider(try writePNG(named: "p\($0).png")) }

        let outcome = await CanvasExternalDrop.ingest(providers: providers,
                                                      using: recorder.seam)
        let made = CanvasExternalDrop.apply(paths: outcome.paths,
                                            at: CGPoint(x: 100, y: 100), in: model)

        XCTAssertEqual(made.count, 3, "three files, three cards")
        XCTAssertEqual(Set(made).count, 3, "three DISTINCT minted ids")
        let origins = made.compactMap { model.scene.node($0)?.origin }
        XCTAssertEqual(origins.count, 3)
        XCTAssertEqual(Set(origins.map { "\($0.x),\($0.y)" }).count, 3,
                       "two cards at one point read as one card, and the writer "
                       + "concludes the others were lost")
    }

    /// **An externally dropped card is born measured and joins by its CENTRE.**
    ///
    /// Both halves are the same two failures Task 10's own tests name, arriving
    /// through a second creation route: an unmeasured node has no `frame`, so it
    /// is neither drawn nor clickable *and* `joinTarget` returns nil for it — a
    /// join that silently joins nothing, on every drop, for ever.
    ///
    /// **Control:** the card really was measured, so the homelessness assertion
    /// below cannot pass by there being no centre to test.
    func test_anExternallyDroppedCardIsMeasuredAndJoinsByItsCentre() async throws {
        let model = attachedModel()
        withRegion(model)
        let recorder = RecordingIngest()
        let inside = CGPoint(x: 200, y: 150)
        XCTAssertTrue(regionFrame.contains(centre(ofCardDroppedAt: inside)),
                      "precondition: this fixture's card centre really is inside")

        let outcome = await CanvasExternalDrop.ingest(
            providers: [fileProvider(try writePNG(named: "inside.png"))],
            using: recorder.seam)
        let id = try XCTUnwrap(
            CanvasExternalDrop.apply(paths: outcome.paths, at: inside, in: model).first)

        let landed = try XCTUnwrap(model.scene.node(id))
        XCTAssertEqual(landed.cachedHeight, CanvasCardMetrics.itemLabelOnlyHeight,
                       "the label-only floor is the honest height until the "
                       + "photograph decodes — and an unmeasured card is neither "
                       + "drawn nor clickable, persisted that way")
        let frame = try XCTUnwrap(landed.frame,
                                  "an unmeasured node has no frame at all")
        XCTAssertEqual(model.scene.topmostNode(at: CGPoint(x: frame.midX,
                                                           y: frame.midY))?.id,
                       id, "hit testing drops a node with no frame")
        XCTAssertEqual(CanvasMembership.homeRegion(of: id, in: model.scene), regionID,
                       "creation absorbs: a card dropped inside a region lives there")

        // The corner test, refused — the origin is inside and the centre is one
        // point past the right edge (§4.2's discriminator against Obsidian).
        let corner = CGPoint(x: 381, y: 150)
        XCTAssertTrue(regionFrame.contains(corner))
        XCTAssertFalse(regionFrame.contains(centre(ofCardDroppedAt: corner)))
        let second = await CanvasExternalDrop.ingest(
            providers: [fileProvider(try writePNG(named: "corner.png"))],
            using: recorder.seam)
        let cornerID = try XCTUnwrap(
            CanvasExternalDrop.apply(paths: second.paths, at: corner, in: model).first)
        XCTAssertNil(CanvasMembership.homeRegion(of: cornerID, in: model.scene),
                     "the centre decides, not the corner")
        XCTAssertNotNil(model.scene.node(cornerID)?.frame,
                        "control: it was MEASURED, so it HAD a centre to test — "
                        + "unmeasured, `joinTarget` is nil for every node on every "
                        + "canvas and the assertion above is vacuous")
    }

    /// **An external drop is one named ⌘Z, including while the writer is inside a
    /// scrap** — the tripwire-32 repro from a sixth direction, and the sharpest
    /// one yet: the drag begins in the Finder, so nothing on either side of it
    /// closes the writer's open "Edit Scrap" bracket.
    func test_anExternalDropIsItsOwnNamedStepEvenInsideAnOpenScrap() async throws {
        let model = attachedModel()
        let scrapID = CanvasNodeID("s1")
        model.mutate("New Scrap") {
            $0.insert(CanvasNode(id: scrapID, kind: .scrap, origin: .zero,
                                 width: 240, cachedHeight: 38))
        }
        model.beginGesture("Edit Scrap")
        model.setScrapText("the falls at night", for: scrapID)

        let recorder = RecordingIngest()
        let outcome = await CanvasExternalDrop.ingest(
            providers: [fileProvider(try writePNG(named: "mid-sentence.png"))],
            using: recorder.seam)
        let id = try XCTUnwrap(
            CanvasExternalDrop.apply(paths: outcome.paths,
                                     at: CGPoint(x: 400, y: 400), in: model).first)

        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains(CanvasDrop.undoStepName),
                      "the drop registered no step of its own — it nested inside "
                      + "\"Edit Scrap\" and rides into the writer's next sentence "
                      + "(tripwire 32). found: " + model.undoManager.undoMenuItemTitle)

        model.endGesture()
        model.undo.undo()
        XCTAssertNil(model.scene.node(id), "the first ⌘Z takes back the card")
        XCTAssertEqual(model.scraps[scrapID], "the falls at night",
                       "…and leaves the sentence alone")
    }

    /// **A failed ingest leaves nothing on the canvas and is not silent.**
    ///
    /// **Control:** the same drop with a working seam lands a card and says
    /// nothing — so the message above is the failure's doing rather than a route
    /// that always complains.
    func test_aFailedIngestLeavesNothingOnTheCanvasAndSaysSo() async throws {
        let model = attachedModel()
        let recorder = RecordingIngest()
        recorder.failEverything = true

        let failed = await CanvasExternalDrop.ingest(
            providers: [fileProvider(try writePNG(named: "unwritable.png"))],
            using: recorder.seam)
        let made = CanvasExternalDrop.apply(paths: failed.paths,
                                            at: CGPoint(x: 10, y: 10), in: model)

        XCTAssertTrue(made.isEmpty, "nothing landed")
        XCTAssertTrue(model.scene.unorderedNodes.isEmpty,
                      "a card pointing at a file that was never written draws a "
                      + "broken picture the writer cannot explain")
        let message = try XCTUnwrap(failed.message,
                                    "a failed ingest that says nothing is a drag "
                                    + "that appears to do nothing")
        XCTAssertTrue(message.contains("unwritable.png"),
                      "the message names the file the writer dropped, so they know "
                      + "WHICH of four photographs did not land. found: \(message)")
        XCTAssertFalse(model.undoManager.canUndo,
                       "and it left no empty undo step behind")

        let working = RecordingIngest()
        let ok = await CanvasExternalDrop.ingest(
            providers: [fileProvider(try writePNG(named: "fine.png"))],
            using: working.seam)
        XCTAssertNil(ok.message, "control: a working ingest says nothing")
        XCTAssertEqual(
            CanvasExternalDrop.apply(paths: ok.paths, at: .zero, in: model).count, 1,
            "control: …and lands a card")
    }
}
