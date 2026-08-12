import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// The mounted canvas's SURFACE: what the double-click mounts, how the cards
/// it draws behave under a resize or a coast, and the accessibility tree it
/// publishes over the top. Harness in `CanvasViewMountingCase`.
final class CanvasViewMountingSurfaceTests: CanvasViewMountingCase {

    // MARK: - The seams

    /// Task 8 built `CanvasGroundPalette.wash(fromHex:)` and left the seam
    /// unwired; this view is what pulls it. `CanvasCompositionTests` pins that
    /// the pulled value reaches the ground — this pins that anything pulls it at
    /// all. An unpulled palette and a correctly dosed 4% wash look identical.
    func test_theProjectsPaletteIsPulledWhenTheCanvasAppears() throws {
        var asked = 0
        host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                        paletteSwatchHexes: { asked += 1; return ["#33aa88"] }))
        XCTAssertGreaterThan(asked, 0,
                             "the canvas never asked the project for its palette, so "
                             + "the ground is untinted for every project — and a wash "
                             + "that never arrives looks exactly like one dosed right")
    }

    /// The editor exists, is focused, and — crucially — ⌘Z from inside it can
    /// still reach the canvas's own undo stack. Task 9 measured that chain in the
    /// hierarchy it built by hand; this is the hierarchy SwiftUI builds.
    func test_aDoubleClickMountsAFocusedEditorReachableFromTheResponderChain() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let root = try XCTUnwrap(window.contentView)
        XCTAssertNil(firstDescendant(ScrapEditorContainer.self, in: root),
                     "precondition: nothing is mounted before anything is clicked")

        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView,
                                   "the container mounted with no text view in it")
        XCTAssertEqual(editor.string, scrapText,
                       "the editor mounted on some other scrap's layout")
        XCTAssertTrue(window.firstResponder === editor,
                      "the mounted editor is not first responder in the real "
                      + "hierarchy, so every keystroke goes somewhere else")

        // The route ⌘Z takes: NSTextView does not implement undo:, so the action
        // walks nextResponder until something does.
        var responder: NSResponder? = editor
        var handler: NSResponder?
        while let r = responder {
            if r.responds(to: #selector(ScrapEditorContainer.undo(_:))) { handler = r; break }
            responder = r.nextResponder
        }
        XCTAssertTrue(handler === container,
                      "the responder chain out of the mounted editor does not reach "
                      + "the canvas container, so ⌘Z inside a scrap drives SwiftUI's "
                      + "undo stack instead of the canvas's")
    }

    /// §7A.5's ordering, end to end and on the clock this task owns: the editor
    /// is mounted and focused immediately and is NOT the visible text until the
    /// card is level. Nothing else in the plan can see this — Task 7 owns the
    /// interpolated value, Task 9 owns what `isEditorVisible` does, and only
    /// this view's `TimelineView` connects the two.
    ///
    /// It caught the defect `CanvasView.maximumFrameStep` now fixes: a paused
    /// `TimelineView` holds its last date, so the first delta after a click is
    /// the whole idle gap and an unclamped `step(elapsed:)` finished the whole
    /// straighten on frame one. Every test that steps the straighten by hand
    /// passed throughout — the animation simply never ran on the real surface.
    func test_theMountedEditorIsInvisibleUntilTheCardHasStraightened() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        // Less than the ~120 ms straighten, so this is the middle of it.
        let container = try doubleClickTheScrap(in: window, settle: 0.04)
        XCTAssertEqual(container.alphaValue, 0,
                       "the editor is the visible text before the card is level: "
                       + "axis-aligned glyphs over a card still up to "
                       + "\(CanvasMaterial.maximumTiltDegrees)° off, so "
                       + "the words snap straight the instant the writer clicks. "
                       + "The likeliest cause is a frame delta that is really a "
                       + "resume — see CanvasView.maximumFrameStep")
        XCTAssertTrue(window.firstResponder === container.textView,
                      "invisible must not mean unfocused — that is the whole "
                      + "reason the mount is not gated on the straighten")

        pump(0.4)
        XCTAssertEqual(container.alphaValue, 1,
                       "the editor never became visible: the straighten clock this "
                       + "view owns is not running, so the writer is typing into an "
                       + "editor that stays invisible for the whole visit")
    }

    /// A pinch inside the MOUNTED editor must zoom about the canvas point under
    /// the writer's fingers.
    ///
    /// `CanvasCompositionTests.test_theFocusedEditorsPinchAnchorGoesThroughTheGeometryMapper`
    /// greps this view's source for the name `ScrapEditorGeometry.viewPoint`.
    /// That grep passes just as happily if the mapped point is computed and then
    /// dropped and the raw editor-space point is handed to the camera — which
    /// compiles, and zooms about a point the writer never touched. Nothing else
    /// in the plan drives `applyMagnify` on a mounted container at all, so the
    /// mapper could be reduced to dead code without a single test going red.
    ///
    /// The invariant is stated rather than the arithmetic reproduced: the canvas
    /// point under the fingers does not move on screen. Under the wiring this
    /// pins, the anchor is the container's origin plus the editor point scaled by
    /// the zoom, and that lands on the same view point before and after. Handing
    /// the camera the raw editor point instead anchors at (100,10) rather than
    /// (130,40) and shifts it by 15 points in each axis.
    func test_pinchingInsideAMountedEditorAnchorsOnTheCanvasPointUnderTheFingers() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let root = try XCTUnwrap(window.contentView)
        let container = try doubleClickTheScrap(in: window)
        XCTAssertEqual(container.alphaValue, 1,
                       "precondition: the straighten has finished, so this editor "
                       + "is the view a real pinch would land on")

        let before = swiftUIFrame(of: container, in: root)
        // The fixture's card is at (20,20) 240 wide, so its text box is 220 wide
        // at a text origin of (30,30). Seeing exactly that is what says the
        // camera is still at identity, and therefore that the pre-pinch zoom
        // below is 1.
        XCTAssertEqual(before.origin.x, 30, accuracy: 0.5)
        XCTAssertEqual(before.origin.y, 30, accuracy: 0.5)
        XCTAssertEqual(before.width, 220, accuracy: 0.5,
                       "precondition: nothing has moved the camera off identity")

        // Inside the editor, well away from its own origin — an anchor bug that
        // drops the text-origin translation is invisible at (0,0).
        let editorPoint = CGPoint(x: 100, y: 10)
        container.applyMagnify(magnification: 0.5, atEditorPoint: editorPoint)
        pump()

        let after = swiftUIFrame(of: container, in: root)
        let zoom = after.width / before.width
        XCTAssertEqual(zoom, 1.5, accuracy: 0.01,
                       "precondition: the pinch never reached the camera at all")

        XCTAssertEqual(after.origin.x + editorPoint.x * zoom,
                       before.origin.x + editorPoint.x, accuracy: 0.5,
                       "the pinch anchored somewhere other than the canvas point "
                       + "under the fingers — the editor hands back a point in its "
                       + "OWN space and it has to go through "
                       + "ScrapEditorGeometry.viewPoint first")
        XCTAssertEqual(after.origin.y + editorPoint.y * zoom,
                       before.origin.y + editorPoint.y, accuracy: 0.5,
                       "the pinch anchored somewhere other than the canvas point "
                       + "under the fingers, on the y axis")
    }

    // MARK: - Drags, and what a card does after one

    /// **A press in the resize corner that never moves must not delete the card
    /// from the canvas.**
    ///
    /// `CanvasScene.setWidth` clears `cachedHeight` on every `.changed`,
    /// identical width or not, and a node with no height has no `frame` — so it
    /// is invisible to `topmostNode(at:)`, to `nodes(intersecting:)` and to the
    /// renderer at once. The card is still in the scene and gone from the
    /// surface, and `rebuildLayouts()` has three call sites, none of which the
    /// writer can reach without reloading the view.
    ///
    /// It takes a `mouseDragged:` delivered at exactly the `mouseDown` point to
    /// get there, which is why the unit test that describes the state —
    /// `CanvasInteractionTests.test_aResizeSampleAtThePressPointStillClearsTheCachedHeight`
    /// — cannot see the consequence. This drives the whole path and asks the
    /// question the writer asks: click the card again, is it the same card?
    func test_aCornerPressThatNeverMovedLeavesTheCardOnTheCanvas() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // Where the corner square is depends on the card's MEASURED height, so
        // read it off the surface rather than writing the font metrics down
        // twice: the mounted editor's box is the card's text box, inset on all
        // four sides.
        let textBox = swiftUIFrame(of: try doubleClickTheScrap(in: window), in: hosted)
        let cardCorner = CGPoint(x: textBox.maxX + CanvasCardMetrics.inset,
                                 y: textBox.maxY + CanvasCardMetrics.inset)
        events.applyMouseDown(at: CGPoint(x: 600, y: 500), clickCount: 1)   // click away
        events.applyMouseUp(at: CGPoint(x: 600, y: 500))
        pump()

        // Press inside the corner square, deliver one drag sample at exactly the
        // press point, release.
        let press = CGPoint(x: cardCorner.x - 2, y: cardCorner.y - 2)
        drag(events, from: press, through: [press])
        pump()

        let editor = try XCTUnwrap(try doubleClickTheScrap(in: window).textView)
        XCTAssertEqual(editor.string, scrapText,
                       "the card vanished: a zero-distance resize left it with no "
                       + "measured height, so the hit test no longer finds it and "
                       + "double-clicking where it sits makes a NEW scrap on top of "
                       + "the writer's words")
        XCTAssertEqual(savedScene(after: window, root: root).count, 1,
                       "the canvas has two scraps where the writer made one")
    }

    /// **A drag on the corner of Claude's source page RESIZES it — and never
    /// takes the page off the canvas** *(1C-d Task 6, re-pointed)*.
    ///
    /// This test asserted the opposite until 1C-d: that the corner moved the card,
    /// because the corner was `.scrap`-only. **The guard was a fix for a missing
    /// measurement pass, not a ruling that item nodes should not resize.** The
    /// 1C-c3 whole-branch Critical was three facts meeting:
    /// `CanvasRenderer.drawCard` drew the resize triangle on every card whatever
    /// its kind, `CanvasInteraction.begin` took the corner for any node with a
    /// frame, and `CanvasScene.setWidth` cleared `cachedHeight` while **nothing
    /// on the item path ever refilled it**. A node with no height has no `frame`,
    /// so the card vanished under the cursor on the next frame, stayed gone, and
    /// `cachedHeight: nil` is what the sidecar persists.
    ///
    /// Task 5 supplied the measurement and this task added the per-frame
    /// re-derive (`CanvasView.remeasure`'s `.item` arm), so the corner and the
    /// mark went back to being unconditional. **What is asserted here is the
    /// safety property the old guard bought, not the old guard**: after a corner
    /// drag on an item node the card still has a height, is still returned by
    /// `nodes(intersecting:)`, is still found by `topmostNode(at:)`, and reaches
    /// disk that way.
    ///
    /// **It must go through `CanvasEventNSView`, not through `setWidth`**, and it
    /// must be read MID-DRAG. `rebuildLayouts` runs at `.ended` and heals a
    /// missing item height, so a test that only looked after the release passes
    /// over a gesture that had the card off the surface for its whole length —
    /// which is exactly how the writer meets it: the card disappears under the
    /// cursor on the next frame and comes back when they let go.
    func test_aCornerDragOnClaudesSourcePageResizesItAndStaysOnTheCanvas() throws {
        let reference = "res-notebook-p3"
        let itemID = CanvasNodeID.item(reference)
        var fixture = CanvasScene()
        fixture.insert(CanvasNode(id: itemID, kind: .item(.project(id: reference)),
                                  origin: CGPoint(x: 20, y: 20), width: 240,
                                  cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight,
                                  author: .claude))
        let root = try projectRoot(scene: fixture, scraps: [:])
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // The camera is at identity, so a view point IS a content point.
        let before = try XCTUnwrap(try XCTUnwrap(model.scene.node(itemID)).frame,
                                   "precondition: the page card has no frame before "
                                   + "anything was clicked, so this test would pass "
                                   + "for the wrong reason")
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let handle = CanvasRenderer.resizeHandleSize
        let press = CGPoint(x: before.maxX - handle / 2, y: before.maxY - handle / 2)
        let released = CGPoint(x: press.x + 60, y: press.y)
        // Delivered by hand rather than through `drag`, because the assertions
        // between the samples are the ones the writer's eye makes.
        events.applyMouseDown(at: press, clickCount: 1)
        events.applyMouseDragged(to: released)

        let midDrag = try XCTUnwrap(model.scene.node(itemID),
                                    "the page card left the scene mid-drag")
        XCTAssertNotNil(midDrag.frame,
                        "the page card has no frame in the MIDDLE of the drag, so it "
                        + "is neither drawn nor clickable while the writer is holding "
                        + "the mouse down — CanvasScene.setWidth cleared its height "
                        + "and nothing on the item path refilled one per frame")
        // A height is not the point; what a height BUYS is a frame, and what a
        // frame buys is being drawn, hit-tested and culled at all. Both of the
        // scene's spatial queries drop a node without one, so asserting the
        // number alone would pass for a re-measure the queries still could not
        // use — which is the state the Critical persisted to disk.
        XCTAssertTrue(model.scene.nodes(intersecting: viewport).contains { $0.id == itemID },
                      "mid-drag the page card is not returned by nodes(intersecting:), "
                      + "so it is not drawn at all while the writer is resizing it")
        XCTAssertEqual(model.scene.topmostNode(at: CGPoint(x: 40, y: 40))?.id, itemID,
                       "mid-drag the page card cannot be clicked")
        XCTAssertEqual(midDrag.width, before.width + 60,
                       "the corner drag did not widen the page card: the writer is "
                       + "dragging a mark CanvasRenderer.drawCard inks and nothing "
                       + "is following it")

        events.applyMouseUp(at: released)
        pump()

        let live = try XCTUnwrap(model.scene.node(itemID),
                                 "the page card left the scene entirely")
        XCTAssertNotNil(live.frame,
                        "the photographed page has no frame after a drag on its "
                        + "corner: it is not drawn, not clickable and not "
                        + "recoverable except by an immediate ⌘Z")
        XCTAssertEqual(live.width, before.width + 60,
                       "the widened page card snapped back at the end of the gesture")
        XCTAssertEqual(live.origin, before.origin,
                       "control: the corner MOVED the card instead of resizing it, "
                       + "so every width assertion above measured a drag that went "
                       + "somewhere else")

        let saved = try XCTUnwrap(savedScene(after: window, root: root).node(itemID),
                                  "the page card did not survive the save")
        XCTAssertNotNil(saved.frame,
                        "the page card reached disk with no height, so it is gone "
                        + "from the surface across a relaunch too")
        XCTAssertEqual(saved.width, before.width + 60,
                       "the writer's resize did not reach the sidecar")
    }

    /// **A corner drag on a pictured card SCALES the photograph rather than
    /// distorting it** *(1C-d Task 6)*.
    ///
    /// Spec §7A.3's rule arriving on the second content type: width is
    /// authoritative and the height is derived — a scrap's text reflows, an
    /// image's height follows its aspect ratio. A resize that let the two move
    /// independently would make the card lie about the shape of the page it
    /// reproduces, which is the one thing `CanvasCardMetrics.itemPictureRect`'s
    /// own doc says an image on this surface may not do (§8A.2).
    ///
    /// **The assertion is the RATIO, not two heights.** The picture's box is the
    /// card's content width over the photograph's aspect ratio, so what must hold
    /// across the drag is `contentWidth / pictureHeight`, and a test comparing two
    /// literal heights would go red on any change to the label chrome that this
    /// test has no opinion about.
    ///
    /// Read MID-DRAG for the reason the test above is: `rebuildLayouts` at
    /// `.ended` would hide a gesture that distorted the card for its whole length.
    func test_aCornerDragOnAPicturedItemCardKeepsThePhotographsAspectRatio() throws {
        let path = "canvas_assets/image-20260730-220430.png"
        let itemID = CanvasNodeID("owned-aspect")
        var fixture = CanvasScene()
        fixture.insert(CanvasNode(id: itemID, kind: .item(.owned(path: path)),
                                  origin: CGPoint(x: 40, y: 40), width: 240,
                                  cachedHeight: nil))
        let root = try projectRoot(scene: fixture, scraps: [:])
        // 400×300 — 4:3, so a squashed card is unmistakable from a scaled one.
        try writeCanvasFixtureImage(width: 400, height: 300,
                                    to: root.appendingPathComponent(path))

        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        pump()

        /// The aspect ratio of the box the picture is drawn in, read back out of
        /// the card's own height — the number the writer sees.
        func pictureAspect(of node: CanvasNode) throws -> CGFloat {
            let height = try XCTUnwrap(node.cachedHeight)
                - CanvasCardMetrics.itemLabelOnlyHeight
                - CanvasCardMetrics.itemPictureGap
            return CanvasCardMetrics.textWidth(forCardWidth: node.width) / height
        }

        let before = try XCTUnwrap(model.scene.node(itemID))
        XCTAssertEqual(try pictureAspect(of: before), 4.0 / 3.0, accuracy: 0.02,
                       "precondition: the photograph had not decoded before the drag "
                       + "began, so this test would compare two floor heights")

        let frame = try XCTUnwrap(before.frame)
        let handle = CanvasRenderer.resizeHandleSize
        let press = CGPoint(x: frame.maxX - handle / 2, y: frame.maxY - handle / 2)
        events.applyMouseDown(at: press, clickCount: 1)
        events.applyMouseDragged(to: CGPoint(x: press.x + 120, y: press.y))

        let midDrag = try XCTUnwrap(model.scene.node(itemID))
        XCTAssertEqual(midDrag.width, before.width + 120,
                       "control: the drag never widened the card, so the ratio below "
                       + "is being read off an unchanged card")
        XCTAssertGreaterThan(try XCTUnwrap(midDrag.cachedHeight),
                             try XCTUnwrap(before.cachedHeight),
                             "control: a wider card holding the same 4:3 photograph "
                             + "must be TALLER — an unchanged height would satisfy no "
                             + "ratio assertion honestly")
        XCTAssertEqual(try pictureAspect(of: midDrag), 4.0 / 3.0, accuracy: 0.02,
                       "the photograph is drawn squashed while the writer resizes its "
                       + "card: the height did not follow the width through the "
                       + "picture's own aspect ratio (§7A.3)")

        events.applyMouseUp(at: CGPoint(x: press.x + 120, y: press.y))
        pump()
        XCTAssertEqual(try pictureAspect(of: try XCTUnwrap(model.scene.node(itemID))),
                       4.0 / 3.0, accuracy: 0.02,
                       "the card settled at a shape its photograph is not")
    }

    /// **An item node that arrives with no height is healed, not silently absent.**
    ///
    /// `CanvasScrapMeasure`'s scoped-gap paragraph conceded this route on the
    /// record — a hand-edited sidecar can hand us an item node with no
    /// `cachedHeight`, and a node with no height has no `frame`, so it is neither
    /// drawn nor clickable. `rebuildLayouts` now writes
    /// `CanvasCardMetrics.itemLabelOnlyHeight` for one, which is the half of the
    /// Critical's fix that does not depend on the gesture being guarded.
    ///
    /// The fixture is written through `CanvasStore`, so it cannot drift from the
    /// format the view reads.
    func test_anItemNodeThatArrivesWithNoHeightIsHealedOnLoad() throws {
        let reference = "res-notebook-p9"
        let itemID = CanvasNodeID.item(reference)
        var fixture = CanvasScene()
        fixture.insert(CanvasNode(id: itemID, kind: .item(.project(id: reference)),
                                  origin: CGPoint(x: 40, y: 40), width: 240,
                                  cachedHeight: nil, author: .claude))
        let root = try projectRoot(scene: fixture, scraps: [:])
        XCTAssertNil(try XCTUnwrap(CanvasStore(projectRoot: root).load().scene.node(itemID)).cachedHeight,
                     "precondition: the fixture reached disk WITH a height, so the "
                     + "heal below is not being exercised")

        let model = makeModel()
        host(CanvasView(model: model, projectRoot: root, paletteSwatchHexes: { [] }))
        pump()

        XCTAssertEqual(try XCTUnwrap(model.scene.node(itemID)).cachedHeight,
                       CanvasCardMetrics.itemLabelOnlyHeight,
                       "an item node with no height stayed unmeasured after a load, "
                       + "so the writer's canvas is missing a card that is in the "
                       + "sidecar, in the accessibility tree and in list_canvas")

        // …and the height is not the point. **What a height BUYS is a frame**,
        // and what a frame buys is being drawn, hit-tested and culled at all: a
        // node with no `cachedHeight` is dropped by both of the scene's own
        // spatial queries. Asserting the number alone would pass for a heal that
        // wrote a height the queries still could not use, which is exactly the
        // state the 1C-c3 Critical persisted to disk.
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertTrue(model.scene.nodes(intersecting: viewport).contains { $0.id == itemID },
                      "the healed page card is not returned by nodes(intersecting:), "
                      + "so it is neither drawn nor culled — it is simply not on the "
                      + "canvas")
        XCTAssertEqual(model.scene.topmostNode(at: CGPoint(x: 60, y: 60))?.id, itemID,
                       "the healed page card cannot be clicked")
    }

    /// **A photograph arrives after the frame that asked for it, and the card
    /// grows to hold it.**
    ///
    /// This is the whole of Task 5's off-frame-path contract, driven through the
    /// real view rather than through the cache. `CanvasThumbnails.resolved` never
    /// decodes — it records a miss — so the first measurement of an owned item
    /// node lands on the floor. Something in the view has to notice, service the
    /// queue and RE-MEASURE, and none of those three is visible to a test that
    /// drives `CanvasThumbnails` directly: a view that never scheduled
    /// `servicePending()` would leave every photograph on the canvas a blank
    /// card, and one that serviced it but only bumped the redraw counter would
    /// leave every one of them the wrong height.
    ///
    /// The floor assertion is the control: without it a card that was measured
    /// with a picture from the start would pass the growth assertion for free.
    func test_anOwnedItemNodesCardGrowsWhenItsPhotographHasDecoded() throws {
        let path = "canvas_assets/image-20260730-220430.png"
        let itemID = CanvasNodeID("owned-1")
        var fixture = CanvasScene()
        fixture.insert(CanvasNode(id: itemID, kind: .item(.owned(path: path)),
                                  origin: CGPoint(x: 40, y: 40), width: 240,
                                  cachedHeight: nil))
        let root = try projectRoot(scene: fixture, scraps: [:])
        // 400×300 — a landscape photograph, so a card holding it is unmistakably
        // taller than one holding a line of label.
        try writeCanvasFixtureImage(width: 400, height: 300,
                                    to: root.appendingPathComponent(path))

        let model = makeModel()
        host(CanvasView(model: model, projectRoot: root, paletteSwatchHexes: { [] }))
        pump()

        let height = try XCTUnwrap(try XCTUnwrap(model.scene.node(itemID)).cachedHeight)
        XCTAssertGreaterThan(height, CanvasCardMetrics.itemLabelOnlyHeight,
                             "the card is still at the floor height after the photograph "
                             + "had time to decode: either nothing scheduled "
                             + "servicePending(), or it ran and nothing re-measured. A "
                             + "canvas of blank cards is what the writer sees either way")
        XCTAssertEqual(height,
                       CanvasCardMetrics.itemCardHeight(forCardWidth: 240,
                                                        pictureAspect: 4.0 / 3.0),
                       accuracy: 1.5,
                       "the card's height is not the one its photograph's shape asks "
                       + "for — measured \(height) against the 4:3 fixture")

        // …and the new height is a fact about the SCENE rather than about one
        // frame: a point that is inside the card only because the photograph made
        // it taller now hits it. A re-measure that reached the renderer and not
        // the scene would leave a card drawn larger than it can be clicked.
        XCTAssertEqual(
            model.scene.topmostNode(
                at: CGPoint(x: 60, y: 40 + CanvasCardMetrics.itemLabelOnlyHeight + 20))?.id,
            itemID,
            "the grown card cannot be clicked where it is drawn")

        // **Nothing is asserted about the sidecar here, deliberately.** A height
        // is DERIVED (§7A.3) and this pass runs on every load, so the sidecar's
        // copy is an optimisation and not the record: a decode landing does not
        // queue a save, and it should not — opening a canvas would then dirty its
        // own file, and the next launch re-measures from the floor to the same
        // number anyway. What must never persist is a NIL height, and the heal is
        // what closes that (`test_anItemNodeThatArrivesWithNoHeightIsHealedOnLoad`).
    }

    /// **A photograph that fails to decode must not take the NEXT one down with
    /// it** *(Task 5 review, Important 1)*.
    ///
    /// The servicing schedule is a `.task(id:)`, and for one commit the id was the
    /// pending COUNT. `rebuildLayouts` is its only writer and it runs after a
    /// service only when `servicePending()` reports that something landed — so a
    /// decode that FAILS drains the queue, reports false, and leaves the count
    /// frozen. The next miss that happened to produce the same count then moved no
    /// id, scheduled nothing, and **the second photograph never decoded for the
    /// rest of the session**, silently, at the floor height.
    ///
    /// It is the error path of the exact failure this task exists to prevent, and
    /// it is the path `CanvasThumbnails`' own `Entry` doc anticipates ("a
    /// photograph the writer deleted from the Finder"). Every other test in the
    /// slice uses one good picture and cannot see it.
    ///
    /// The second card arrives through `mutateFromInspector` — the ordinary
    /// other-column route, which is how a card gets added to a canvas the writer
    /// is looking at — so the rebuild really is the one production takes.
    ///
    /// **The control is the same test with the first photograph READABLE**
    /// (`test_aSecondPhotographDecodesAfterAReadableFirstOne` below): without it,
    /// a delivery path that never added the second node at all would satisfy every
    /// assertion here by leaving a card that was never measured.
    func test_aFailedDecodeDoesNotStallTheNextPhotograph() throws {
        try assertTheSecondPhotographDecodes(firstImageIsReadable: false)
    }

    /// The control for the test above. If this one ever fails, that one is
    /// measuring the delivery route rather than the failed decode.
    func test_aSecondPhotographDecodesAfterAReadableFirstOne() throws {
        try assertTheSecondPhotographDecodes(firstImageIsReadable: true)
    }

    /// **A canvas holding more photographs than the thumbnail budget can keep
    /// must SETTLE, not thrash** *(Task 5 re-review, N1)*.
    ///
    /// `CanvasItemPresentation.resolve` asks the cache for every item node in the
    /// scene and `CanvasThumbnails` evicts LRU over a byte budget, so above the
    /// budget a resolve misses on whatever the last service evicted. For one
    /// commit the post-service rebuild re-armed the servicing ticket, which made
    /// that a loop with no exit — resolve → miss → ticket → service → evict →
    /// resolve — re-decoding the same photographs and rebuilding the whole
    /// accessibility tree on every turn (tripwire 30's cost, permanently). At the
    /// shipped 64 MiB budget the line is roughly 85 pictured cards, which is why
    /// this test is handed a cache rather than reaching the state by volume.
    ///
    /// **The instrument is `decodeCount`, and the alternative was measured and
    /// rejected.** Watching `model.sceneRevision` fail to move looks like the
    /// obvious test and passes for the wrong reason: this harness stops
    /// delivering SwiftUI updates once the mount burst is over, so the loop runs
    /// three turns and then goes quiet on its own. Instrumented, the pre-fix code
    /// printed `task ran at ticket 1 … 2 … 3` and then stopped, with the counter
    /// still — green, over a live defect. A decode count is exact: six
    /// photographs, six decodes, however the runloop behaves.
    ///
    /// **The heights are the other half, and they are `CanvasThumbnails`' shape
    /// memo.** Only about two of these six can be resident at once, so four of
    /// them are asked about while their pixels are gone. A card must keep the
    /// height its photograph gave it through that — measuring off residency is
    /// what gave the loop its motive, and it would make every eviction move the
    /// writer's layout.
    @MainActor
    func test_aCanvasOverTheThumbnailBudgetSettlesInsteadOfLooping() throws {
        var fixture = CanvasScene()
        for index in 0..<6 {
            fixture.insert(CanvasNode(id: CanvasNodeID("owned-\(index)"),
                                      kind: .item(.owned(path: "canvas_assets/p\(index).png")),
                                      origin: CGPoint(x: 40 + index * 300, y: 40),
                                      width: 240, cachedHeight: nil))
        }
        let root = try projectRoot(scene: fixture, scraps: [:])
        for index in 0..<6 {
            try writeCanvasFixtureImage(
                width: 400, height: 300,
                to: root.appendingPathComponent("canvas_assets/p\(index).png"))
        }

        // Room for about two of the six: a 240 pt card asks for bucket 512 and a
        // 400×300 photograph decodes to ~480 KB. What matters is that the budget
        // is crossed, not the exact number it is crossed by.
        let cache = CanvasThumbnails(byteBudget: 1_200_000)
        let model = makeModel()
        host(CanvasView(model: model, projectRoot: root, paletteSwatchHexes: { [] },
                        thumbnailCache: cache))
        pump()

        let expected = CanvasCardMetrics.itemCardHeight(forCardWidth: 240,
                                                        pictureAspect: 4.0 / 3.0)
        for index in 0..<6 {
            let id = CanvasNodeID("owned-\(index)")
            let height = try XCTUnwrap(try XCTUnwrap(model.scene.node(id)).cachedHeight)
            XCTAssertEqual(height, expected, accuracy: 1.5,
                           "card \(index) is \(height) rather than its photograph's "
                           + "shape — a card whose thumbnail the budget evicted must "
                           + "keep the height its photograph gave it, or every "
                           + "eviction moves the writer's layout")
        }
        // Control for the six above: they can only be right if the service really
        // ran, and this says so in the cache's own terms.
        XCTAssertGreaterThan(cache.decodeCount, 0,
                             "nothing ever decoded, so the heights above are not "
                             + "evidence of anything")

        XCTAssertEqual(cache.decodeCount, 6,
                       "six photographs cost \(cache.decodeCount) decodes — the "
                       + "servicing schedule is feeding itself: every service evicts "
                       + "what the next resolve then asks for again, and each turn "
                       + "also re-sorts the accessibility tree and copies every "
                       + "scrap's string")

        // And it stays settled: a second pass over the runloop adds nothing.
        pump(0.4)
        XCTAssertEqual(cache.decodeCount, 6,
                       "the canvas is still decoding with no writer touching it")
    }

    /// **The card must stay on the canvas for the WHOLE of a resize, not just
    /// after the writer lets go.**
    ///
    /// Every other resize test in this file asserts after `.ended`, and the
    /// re-measure that lands there hides the middle of the gesture completely.
    /// What the writer reported from the 1C-a smoke is the middle: "the entire
    /// card disappears and suddenly reappears when released". `setWidth` clears
    /// `cachedHeight` on every `.changed`, so between the first drag sample and
    /// the release the node has no `frame` — invisible to `topmostNode(at:)`, to
    /// `nodes(intersecting:)` and to the renderer at once — and a card that
    /// vanishes while being resized tells the writer nothing about the size they
    /// are choosing.
    ///
    /// Read in PIXELS because there is nothing else to read: the cards are drawn
    /// into a `Canvas`, so a card has no view, no frame and no accessibility
    /// element that is fresh mid-gesture (the tree is keyed on `sceneRevision`,
    /// which a drag frame must not bump). `ScrapEditorHostTests` rasterises the
    /// same way.
    ///
    /// The drag NARROWS the card, so the last assertion can ask a stronger
    /// question than "is anything drawn": the fixture rewraps from 2 lines to 4
    /// at the floor, so ink below where the 2-line card used to end can only be
    /// there if the height was re-derived from a real re-layout during the drag.
    /// That is the live rewrap the handle exists to show, and the band is
    /// asserted EMPTY first so the ink found during the drag is provably new.
    ///
    /// It uses `rewrappingScrapProjectRoot()`, not the shared fixture, and that
    /// is load-bearing: `scrapText` is 94.62pt wide and fits on one line even in
    /// the 100pt text box of a card at the floor, so against it this assertion
    /// would be demanding a rewrap the fixture cannot produce. See
    /// `rewrappingScrapText` for both measurements.
    func test_aCardBeingResizedStaysOnTheCanvasForTheWholeDrag() throws {
        let root = try rewrappingScrapProjectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // The card's box, read off the surface rather than recomputed from font
        // metrics: the mounted editor's frame IS the text box, inset on all four
        // sides. Then click away so the drag below is a resize and not a text
        // selection inside a focused scrap.
        let textBox = swiftUIFrame(of: try doubleClickTheScrap(in: window), in: hosted)
        let cardBox = textBox.insetBy(dx: -CanvasCardMetrics.inset,
                                      dy: -CanvasCardMetrics.inset)
        events.applyMouseDown(at: CGPoint(x: 600, y: 500), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 600, y: 500))
        pump()

        XCTAssertGreaterThan(try ink(in: cardBox, of: hosted), 0,
                             "precondition: the card is drawn at all before anything "
                             + "is dragged")

        // Below where the 2-line card ends, and clear of BOTH the drop shadow and
        // the tilt.
        //
        // **The tilt term is derived now, and it has to be.** The clearance was a
        // hand-tuned 4pt, which worked only because this card's seed happened to
        // land near level; 1C-c3 gave every card the writer made a minimum lean
        // (`CanvasMaterial.minimumTiltDegrees`, so that *straight* can mean
        // Claude), this card's angle grew several-fold, and its lower corner came
        // down into the band — 33 ink pixels against a precondition of zero. A
        // literal here is a test that depends on one id's hash.
        //
        // `cardBox` is the UNROTATED box (it is read off the mounted editor's
        // frame, which is bounds-scaled and axis-aligned), so the corner furthest
        // from the centre drops by `halfWidth · sin θ` at the calibrated maximum.
        // The remaining 5pt is the shadow, radius 3 at offset (1, 2).
        let tiltDrop = cardBox.width / 2
            * CGFloat(sin(CanvasMaterial.maximumTiltDegrees * .pi / 180))
        let wrapBand = CGRect(x: cardBox.minX, y: cardBox.maxY + tiltDrop + 5,
                              width: 120, height: 24)
        XCTAssertEqual(try ink(in: wrapBand, of: hosted), 0,
                       "precondition: nothing is drawn below the card yet, so ink "
                       + "found there during the drag can only be the card having "
                       + "grown")

        // Press in the corner square and drag left to the narrow end — and DO NOT
        // release. This is the state the writer complained about, and the state
        // no other test in this file ever looks at.
        //
        // The press is 2pt inside the corner, so the width this lands on is 122,
        // not the 120 floor itself. Measured: the card is 88pt tall at every
        // width from 124 down to 120, so the band below reads the same either
        // way — see `rewrappingScrapText`.
        let press = CGPoint(x: cardBox.maxX - 2, y: cardBox.maxY - 2)
        events.applyMouseDown(at: press, clickCount: 1)
        events.applyMouseDragged(to: CGPoint(x: cardBox.minX + 120, y: press.y))
        pump(0.05)

        let narrowed = CGRect(x: cardBox.minX, y: cardBox.minY,
                              width: 120, height: cardBox.height)
        XCTAssertGreaterThan(try ink(in: narrowed, of: hosted), 0,
                             "the card is not on the canvas while the writer is "
                             + "resizing it: `setWidth` cleared the cached height on "
                             + "the first `.changed` and nothing refills it until "
                             + "`.ended`, so the card blinks out for the whole drag "
                             + "and reappears on release")

        XCTAssertGreaterThan(try ink(in: wrapBand, of: hosted), 0,
                             "the card is drawn at its old height while being "
                             + "narrowed, so the writer cannot see the text rewrap "
                             + "as they drag — the height has to be re-derived from "
                             + "the live re-layout, not carried over")

        events.applyMouseUp(at: CGPoint(x: cardBox.minX + 120, y: press.y))
        pump()
    }

    /// §7.3, on the real surface: a card let go while moving carries on and comes
    /// to rest, rather than stopping dead where the pointer released it.
    ///
    /// This is also the control for the two tests around it. A staleness guard on
    /// the flick velocity (`CanvasInteraction.maximumFlickAge`) has a failure mode
    /// that no "the card did not move" assertion can see: set it too tight and
    /// nothing ever flicks, which passes those tests and deletes the feature.
    ///
    /// The arithmetic is a geometric series and therefore frame-rate independent:
    /// 10 pt/frame decaying by 0.8 carries `10 * (1 - 0.8^14) / 0.2` ≈ 47.8 pt
    /// past the release point, wherever the clock happens to tick. A coast that
    /// had not finished would leave the drag's own payload queued — the card at
    /// exactly 40 — so a short pump fails this rather than fudging it.
    func test_aFlickCarriesTheCardOnPastWhereThePointerLetGo() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Grab the card at (60,40) — on it, and well clear of the resize corner —
        // and throw it 20pt right, the last frame carrying 10.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        pumpUntilSaved()

        let node = try XCTUnwrap(savedScene(after: window, root: root).node(scrapID))
        XCTAssertEqual(node.origin.x, 87.8, accuracy: 1.0,
                       "the card stopped dead at 40, where the pointer let go — "
                       + "§7.3's coast is the one thing this surface exists to get "
                       + "right, and a velocity guard that disarms it is worse than "
                       + "no guard at all")
        XCTAssertEqual(node.origin.y, 20, accuracy: 0.5,
                       "a flick along x sent the card off its own line")
    }

    /// **Any press stops a coast, including the one that enters a scrap.**
    ///
    /// The press that enters is the SECOND of a double-click, and the first can
    /// itself launch a flick: AppKit opens a drag session on every mouse-down,
    /// its double-click distance tolerance is wider than nothing, and the launch
    /// floor is half a point per frame. Miss this and the editor is mounted on a
    /// card that is still travelling — the text box slides across the canvas
    /// under the writer's cursor as `body` recomputes.
    ///
    /// That the flick this test relies on really does launch is
    /// `test_aFlickCarriesTheCardOnPastWhereThePointerLetGo`, immediately above,
    /// on the identical gesture.
    func test_thePressThatEntersAScrapStopsTheCardCoastingUnderIt() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        // No pump: enter the card before the coast has carried it anywhere, the
        // way the second press of a double-click arrives.
        events.applyMouseDown(at: CGPoint(x: 100, y: 40), clickCount: 2)
        events.applyMouseUp(at: CGPoint(x: 100, y: 40))
        pump(0.05)

        let container = try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                                      "the double-click mounted no editor")
        let mounted = swiftUIFrame(of: container, in: hosted)
        // The card was released at x = 40 and the editor sits at its text origin,
        // one inset in.
        XCTAssertEqual(mounted.origin.x, 50, accuracy: 0.5,
                       "the card was already travelling when the editor mounted on "
                       + "it — the press that entered the scrap did not stop the "
                       + "coast")

        pump(0.5)
        XCTAssertEqual(swiftUIFrame(of: container, in: hosted).origin.x,
                       mounted.origin.x, accuracy: 0.5,
                       "the editor is sliding across the canvas while the writer "
                       + "types into it: the card kept coasting underneath the "
                       + "mounted editor")
    }

    /// **A card added from OUTSIDE the canvas is measured by the hosted view**,
    /// which is the whole reason `CanvasModel.onSceneChangedExternally` exists
    /// (1C-c3 Task 4).
    ///
    /// The census in `CanvasLiveSeamTests` proves the binding line is written in
    /// `CanvasView.load()`. It cannot prove the closure ever RUNS — a binding
    /// moved into a branch `load()` does not reach, a `load()` no longer called
    /// from `.onAppear`, or a `rebuildLayouts` that stops measuring new nodes all
    /// leave a text census green. That gap is this area's most expensive recorded
    /// mistake: 1C-a shipped ⌘Z twenty-two green tests deep and greyed out in the
    /// Edit menu, because every one of those tests drove the recorder directly.
    /// So this drives the EMITTER, through a real hosted `CanvasView`.
    ///
    /// What it asserts is the failure, not the mechanism: an unmeasured node has
    /// no `cachedHeight`, so it has no `frame`, so `drawCard` gets a nil layout
    /// and `topmostNode(at:)` drops it — **an empty rectangle the writer cannot
    /// click**, until they happen to do something else that rebuilds.
    ///
    /// Falsified by disabling the binding: comment out
    /// `model.onSceneChangedExternally` in `CanvasView.load()` and the height
    /// assertion goes red with `cachedHeight` nil.
    ///
    /// **The words go IN the bracket, through `scrapTexts:`** — the ordering
    /// `mutateFromInspector`'s doc requires of any caller writing both, and the
    /// only one that is safe. Two things ride on it, and the second is why this
    /// test was rewritten in 1C-c3 Task 5's fix round:
    ///
    /// - The hook measures each card from the words it finds, so a card measured
    ///   before its text arrives is measured empty. Asserting the height equals
    ///   `CanvasScrapMeasure.height(text:cardWidth:)` is what makes that visible —
    ///   a card measured empty is a different number, not a nil.
    /// - Written with `setScrapText` BEFORE the call — which is how this test was
    ///   first written, following the doc as it then stood — the words are folded
    ///   in *before* `beginGesture` takes its snapshot, so undoing "Add Scrap"
    ///   removes the card and **leaves its text in `scraps`**: an orphan entry
    ///   `ScrapText.render` writes into `canvas.md` for good. The census in
    ///   `TripwireGrepTests` scans `Maugham/` only, so a test demonstrating the
    ///   forbidden ordering is invisible to it — which is exactly what happened.
    func test_aCardAddedFromOutsideTheCanvasIsMeasuredByTheHostedView() throws {
        let model = makeModel()
        host(CanvasView(model: model, projectRoot: try projectRoot(),
                        paletteSwatchHexes: { [] }))
        XCTAssertNotNil(model.scene.node(scrapID)?.cachedHeight,
                        "precondition: load() measured the fixture's own card")

        let added = CanvasNodeID("mcp1")
        let text = "a card from the other side of the window"
        model.mutateFromInspector("Add Scrap", scrapTexts: [added: text]) {
            $0.insert(CanvasNode(id: added, kind: .scrap,
                                 origin: CGPoint(x: 400, y: 300), width: 240))
        }
        pump()

        let node = try XCTUnwrap(model.scene.node(added), "the applier's own write")
        XCTAssertEqual(node.cachedHeight,
                       CanvasScrapMeasure.height(text: text, cardWidth: 240),
                       "the card arrived unmeasured and stayed that way: it has no "
                       + "frame, so it draws as an empty rectangle and hit testing "
                       + "cannot see it at all")
        let frame = try XCTUnwrap(node.frame)
        XCTAssertEqual(model.scene.topmostNode(at: CGPoint(x: frame.midX, y: frame.midY))?.id,
                       added,
                       "measured but not clickable — which is the same failure the "
                       + "writer meets, reached through hit testing instead of the "
                       + "draw pass")
    }

    /// **Where, not just what.** Every other assertion on this layer reads a
    /// label, a value or a role — words. The one thing an assistive client needs
    /// beyond the words is the rectangle to point at, and until this test nothing
    /// read one.
    ///
    /// The failure it exists to catch is silent: `CanvasAXChildren` places each
    /// child with `.position`, at coordinates that routinely fall far outside the
    /// container's bounds. If SwiftUI resolved those positions to nothing, every
    /// element would land on the same rect, every word-reading test above would
    /// still pass, and VoiceOver would read the canvas out perfectly while
    /// pointing its cursor at one spot for all of it. The plan declined the
    /// `.scaleEffect` alternative for being unverified on exactly this point; this
    /// is the chosen mechanism meeting the same standard.
    ///
    /// The fixture's card is at content (20, 20) 240 wide and the camera is at
    /// identity, so the view frame IS the content frame. Height is asserted only
    /// to be real: it is measured from the font at load, not written by the
    /// fixture.
    ///
    /// **The arithmetic behind this rectangle is asked separately, and cheaply.**
    /// `CanvasAccessibilityTests`' `test_aCardsContentFrameIsTheCardsOwnRectangle`
    /// and `test_theCameraMapsThatRectangleToWhereTheCardIsDrawn` cover the two
    /// hops we write ourselves — the content-space rect and the camera — with no
    /// window and no assistive client. What is left here, and only here, is the
    /// round trip through SwiftUI's publication, the accessibility runtime and
    /// screen coordinates, which no pure test can reach.
    ///
    /// **Three cards, and the third fixture parameter that changed on
    /// 2026-07-31.** This test hosted a canvas holding exactly ONE card until
    /// then, and that was the one thing separating it and the coast test below —
    /// the two that failed on CI — from `test_twoCardsInDifferentPlaces
    /// PublishDifferentFrames` and `test_aCardFarOutsideTheViewportIsStillInThe
    /// PublishedTree`, which host three and passed on the same run. Nothing in
    /// the assertion is weakened by the extra cards: the card read is still the
    /// one at (20, 20) and its expected rectangle is unchanged. The lone-card
    /// case is not dropped either — `test_aLoneCardOnTheCanvasIsAnElementOfItsOwn`
    /// below keeps it, separately, where a platform that cannot publish it says
    /// so instead of taking two unrelated assertions down with it.
    func test_aCardsPublishedFrameLandsWhereTheCardIsDrawn() throws {
        let window = host(CanvasView(model: makeModel(),
                                     projectRoot: try threeCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        let tree = try axTree(in: window)
        let frame = try viewFrame(ofPublished: try axCard(valued: scrapText, in: tree),
                                  in: window)
        let observed = "Published \(frame).\n\(describe(tree))"

        XCTAssertEqual(frame.origin.x, 20, accuracy: 0.5,
                       "the published frame is not where the card is drawn, so an "
                       + "assistive cursor points somewhere the writer's card is "
                       + "not. \(observed)")
        XCTAssertEqual(frame.origin.y, 20, accuracy: 0.5,
                       "the published frame is not where the card is drawn on the y "
                       + "axis — the likeliest cause is a flip between SwiftUI's "
                       + "y-down space and AppKit's y-up screen coordinates. "
                       + "\(observed)")
        XCTAssertEqual(frame.width, 240, accuracy: 0.5,
                       "the published frame is not the size of the card. \(observed)")
        XCTAssertGreaterThan(frame.height, 0,
                             "the card publishes a zero-height rectangle: reachable "
                             + "in the tree and impossible to point at. \(observed)")
    }

    /// **A canvas holding exactly one card, kept as its own question — and the
    /// one place a MEASURED platform limitation lives.**
    ///
    /// This is the state a writer meets on their second interaction with the Plan
    /// persona: one scrap made, nothing else. It is not a corner worth dropping,
    /// and it is the shape the 2026-07-31 CI evidence landed on.
    ///
    /// **What macOS 15.7.7 (build 24G720) does, measured on the runner.** When
    /// `.accessibilityChildren` produces exactly ONE synthetic child, that child
    /// is given its CONTAINER's rectangle. The element itself is right — role
    /// `AXStaticText`, label "Scrap", the writer's sentence in
    /// `accessibilityValue` — and the hosting view, the canvas group and the card
    /// all report the same `(0, 0, 800, 600)` for a card drawn at (20, 20) 240
    /// wide. macOS 26.5 (build 25F84) publishes `(20, 20, 240, 38)` for the same
    /// canvas, and macOS 15.7.7 publishes distinct, correct frames the moment
    /// there are three cards. So it is a fold of a LONE child, not a broken frame
    /// path, and it is Apple's publication rather than ours. See AREA.md.
    ///
    /// **The gate is the observation, deliberately, and never `#available`.** A
    /// version check asserts a belief about which systems are affected and we
    /// have measured exactly one; this predicate is the fold itself, so the test
    /// starts running again on its own if Apple fixes it, and it catches the same
    /// behaviour wherever else it appears. **It is not unfalsifiable**: the
    /// multi-card round trip above is ungated and asserts a published width of
    /// 240 against a container 800 wide, which is this predicate exercised in its
    /// false direction on every run.
    ///
    /// Nothing in production works around the fold — see AREA.md for why a
    /// synthetic second element would be a product change made to satisfy an
    /// older OS.
    func test_aLoneCardOnTheCanvasIsAnElementOfItsOwn() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let tree = try axTree(in: window)
        let container = try viewFrame(ofPublished: try axCanvas(in: tree), in: window)
        let frame = try viewFrame(ofPublished: try axCard(valued: scrapText, in: tree),
                                  in: window)
        let observed = "Published \(frame), container \(container).\n\(describe(tree))"

        guard !isSameRect(frame, container) else {
            throw XCTSkip(
                "this platform folded the lone card into its container: the card's "
                + "element is published correctly in every other respect and carries "
                + "the CANVAS's rectangle rather than its own, so an assistive cursor "
                + "over a canvas holding exactly one card gets the whole canvas. "
                + "Measured on macOS 15.7.7 (24G720); macOS 26.5 publishes the card's "
                + "own rectangle, and this same platform publishes distinct frames "
                + "for three cards. \(observed)")
        }

        XCTAssertEqual(frame.origin.x, 20, accuracy: 0.5,
                       "the lone card's published frame is not where it is drawn. "
                       + "\(observed)")
        XCTAssertEqual(frame.origin.y, 20, accuracy: 0.5,
                       "the lone card's published frame is not where it is drawn on "
                       + "the y axis. \(observed)")
        XCTAssertEqual(frame.width, 240, accuracy: 0.5,
                       "the lone card's published frame is not its size. \(observed)")
    }

    /// The same failure from the other side, and the cheaper half of it: if
    /// `.position` inside an `.accessibilityChildren` builder were ignored, every
    /// card would resolve to one rect. Two cards the fixture put in different
    /// places must not publish the same rectangle.
    func test_twoCardsInDifferentPlacesPublishDifferentFrames() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try threeCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        let tree = try axTree(in: window)
        let first = try viewFrame(ofPublished: try axCard(valued: scrapText, in: tree),
                                  in: window)
        let second = try viewFrame(ofPublished: try axCard(valued: secondScrapText, in: tree),
                                   in: window)

        XCTAssertNotEqual(first, second,
                          "two cards 380pt apart publish the SAME accessibility "
                          + "frame — VoiceOver reads the canvas out correctly and "
                          + "points its cursor at one spot for the whole of it")
        XCTAssertGreaterThan(second.minX, first.minX,
                             "the card the fixture placed to the right does not "
                             + "publish a frame to the right")
        XCTAssertGreaterThan(second.minY, first.minY,
                             "the card the fixture placed below does not publish a "
                             + "frame below")
    }

    /// A press that stops a coast leaves the card somewhere the tree has never
    /// heard of, and this is what makes it hear.
    ///
    /// `sceneRevision` is bumped for a coast in exactly two places: when the
    /// timeline's rest branch runs, and — because a press truncates the coast so
    /// that branch never runs — at `handleDrag(.began)`. Until the fix wave that
    /// added this test the second was covered by accident: `commitActiveEdit`
    /// bumped the counter on EVERY mouse-down, which is the per-click tree
    /// rebuild that guard now prevents. Take the `.began` bump out and this test
    /// reads the card at the point the writer let go, up to `maximumLaunchSpeed`
    /// away from where it is drawn.
    ///
    /// Both preconditions are load-bearing and fail loudly rather than passing
    /// vacuously: the card must have MOVED since the release (or nothing was
    /// coasting) and must be short of the ~87.8 that
    /// `test_aFlickCarriesTheCardOnPastWhereThePointerLetGo` measures for the
    /// identical throw (or the coast finished on its own and the rest branch,
    /// not this one, refreshed the tree).
    func test_aPressThatStopsACoastRefreshesTheAccessibilityFrame() throws {
        let root = try threeCardProjectRoot()
        let window = host(CanvasView(model: makeModel(), projectRoot: root, paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // The throw the flick test measures: released at x = 40, ~47.8 pt of
        // coast ahead of it over ~14 frames.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        // A few frames of it, and no more — a live coast keeps the runloop fed,
        // so this really does return after 30 ms rather than when it runs dry.
        pump(0.03)
        // Bare canvas, far from the card and clear of the fixture's second card
        // at (400, 300): the press stops the coast and starts no drag of its own.
        events.applyMouseDown(at: CGPoint(x: 600, y: 500), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 600, y: 500))
        pump(0.2)

        let tree = try axTree(in: window)
        let published = try viewFrame(ofPublished: try axCard(valued: scrapText, in: tree),
                                      in: window)
        let drawn = try XCTUnwrap(savedScene(after: window, root: root).node(scrapID))

        XCTAssertGreaterThan(drawn.origin.x, 44,
                             "precondition: the flick never carried the card past "
                             + "the point it was released at, so there was no coast "
                             + "for the press to stop and this test measures nothing")
        XCTAssertLessThan(drawn.origin.x, 82,
                          "precondition: the coast reached its own resting place "
                          + "before the press arrived, so the timeline's rest branch "
                          + "refreshed the tree and the press had nothing to do")
        XCTAssertEqual(published.origin.x, drawn.origin.x, accuracy: 1.0,
                       "the accessibility frame is where the writer LET GO of the "
                       + "card, not where the press stopped it — an assistive cursor "
                       + "points at empty ground, and stays wrong until some other "
                       + "structural change happens to rebuild the tree. "
                       + "Card drawn at x \(drawn.origin.x), published \(published).\n"
                       + describe(tree))
    }

    /// **The cheap half of the test above, and the half that runs anywhere.**
    ///
    /// The published tree is a CACHE. `CanvasView` rebuilds its element list from
    /// an `.onChange` on the model's structural counter and never inside `body`,
    /// so a scene change that bumps nothing leaves every frame in that tree at
    /// its old place — the card is drawn in one spot and pointed at in another,
    /// and stays that way until some unrelated structural change comes along. A
    /// press that stops a coast is the path where that is easiest to miss,
    /// because the coast's own rest branch is what usually does the bumping and a
    /// press truncates the coast so that branch never runs.
    ///
    /// So this asks the TRIGGER rather than the published rectangle: the counter
    /// moved, and a list rebuilt from the scene as it now stands puts the card
    /// where the press left it. Neither half needs an assistive client, a
    /// synthetic element or a screen-coordinate round trip — the three hops that
    /// behave differently on different macOS versions. Verified by experiment,
    /// not by reading: with `handleDrag`'s `.began` bump removed, this test fails
    /// on the counter assertion.
    ///
    /// The same two preconditions guard it, for the same reason: without them a
    /// throw that never launched, or one that came to rest before the press
    /// arrived, would leave this passing while measuring nothing.
    func test_aPressThatStopsACoastBumpsTheCounterTheTreeIsRebuiltOn() throws {
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        pump(0.03)
        let counterBeforeThePress = model.sceneRevision

        events.applyMouseDown(at: CGPoint(x: 600, y: 500), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 600, y: 500))
        pump(0.2)

        let drawn = try XCTUnwrap(model.scene.node(scrapID))
        XCTAssertGreaterThan(drawn.origin.x, 44,
                             "precondition: the flick never carried the card past "
                             + "the point it was released at, so there was no coast "
                             + "for the press to stop and this test measures nothing")
        XCTAssertLessThan(drawn.origin.x, 82,
                          "precondition: the coast reached its own resting place "
                          + "before the press arrived, so the timeline's rest branch "
                          + "refreshed the tree and the press had nothing to do")

        XCTAssertGreaterThan(model.sceneRevision, counterBeforeThePress,
                             "the press stopped the coast and bumped nothing, so the "
                             + "accessibility tree is never rebuilt: it keeps the "
                             + "frame the card had when the writer let go of it, up "
                             + "to a whole flick away from where it is now drawn")

        let element = try XCTUnwrap(
            CanvasAccessibility.elements(scene: model.scene, scraps: model.scraps)
                .first { $0.id == .node(scrapID) },
            "the card left the element list entirely when the press stopped it")
        XCTAssertEqual(element.contentFrame.origin.x, drawn.origin.x, accuracy: 0.01,
                       "the rebuilt list does not put the card where the press left "
                       + "it, so bumping the counter buys nothing")
    }

    /// **The deliverable, through the tree an assistive client actually walks.**
    ///
    /// `CanvasAccessibilityTests` asks `elements` directly; this asks the
    /// published tree after a real tree click, which is the only place the
    /// question "does a label go stale when the subject moves" can be asked at
    /// all. The rebuild used to trigger on `sceneRevision` alone — nothing on
    /// this path bumps it, so the labels would be the undimmed ones for the rest
    /// of the session while the board in front of the writer was plainly filtered.
    @MainActor
    func test_aTreeClickMakesTheDimAudibleWithoutTouchingTheScene() throws {
        let window = host(CanvasView(model: makeModel(),
                                     projectRoot: try boundRegionProjectRoot(),
                                     paletteSwatchHexes: { [] }))

        XCTAssertFalse(try axLabel(ofCardValued: secondScrapText, in: window)
                        .contains(CanvasAccessibility.dimmedTerm),
                       "precondition: the board mounts on the project row, where "
                       + "nothing is dimmed and nothing may say it is")

        try retarget(window, at: .piece("ch1"))

        XCTAssertTrue(try axLabel(ofCardValued: secondScrapText, in: window)
                        .contains(CanvasAccessibility.dimmedTerm),
                      "the writer selected a chapter, the board dimmed, and the card "
                      + "outside it is announced exactly as it was before — the "
                      + "labels are keyed on the scene alone and no scene changed")
        XCTAssertFalse(try axLabel(ofCardValued: scrapText, in: window)
                        .contains(CanvasAccessibility.dimmedTerm),
                       "the card living in the bound region is lit and says it is "
                       + "dimmed, so the term is being said unconditionally")

        try retarget(window, at: .wholeProject)
        XCTAssertFalse(try axLabel(ofCardValued: secondScrapText, in: window)
                        .contains(CanvasAccessibility.dimmedTerm),
                       "Escape and the project row are the way out of the dim, and "
                       + "the way out is inaudible: the label kept the term after the "
                       + "board undimmed")
    }

    /// The same staleness from the SCENE's side, and the one shape a source scan
    /// cannot settle: a binding arriving from the **other column** while the
    /// canvas sits filtered.
    ///
    /// `RegionInspector.commitBinding` is mirrored exactly — `mutateFromInspector`
    /// then `bumpSceneRevision()`. Under the two-`.onChange` shape this is the
    /// pass where the tree can be built from the previous dim, because both
    /// handlers fire on the same counter and nothing orders them; here one
    /// resolution feeds both, so the card the writer just claimed stops saying it
    /// is outside the selection in the same pass that lights it.
    @MainActor
    func test_aBindFromTheOtherColumnRelightsTheLabelsAndNotOnlyTheCanvas() throws {
        let model = makeModel()
        let window = host(CanvasView(model: model, projectRoot: try boundRegionProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        try retarget(window, at: .piece("ch2"))

        XCTAssertTrue(try axLabel(ofCardValued: scrapText, in: window)
                        .contains(CanvasAccessibility.dimmedTerm),
                      "precondition: nothing is bound to ch2, so the whole board is "
                      + "dimmed and this test has something to watch change")

        model.mutateFromInspector("Bind Region") { scene in
            RegionBinding.bind(CanvasRegionID("r1"), toPiece: "ch2", in: &scene)
        }
        model.bumpSceneRevision()
        pump()

        XCTAssertFalse(try axLabel(ofCardValued: scrapText, in: window)
                        .contains(CanvasAccessibility.dimmedTerm),
                       "the region was bound to the selected chapter and its resident "
                       + "card is drawn lit while still announcing itself as outside "
                       + "the selection — the tree was built from the dim as it stood "
                       + "before the bind")
        XCTAssertTrue(try axLabel(ofCardValued: secondScrapText, in: window)
                        .contains(CanvasAccessibility.dimmedTerm),
                       "the control: the loose card was never bound to anything and "
                       + "must still say so")
    }

    /// **A subject naming a DELETED document, driven rather than reasoned about.**
    ///
    /// The subject is built the way the window builds it — `CanvasSubject.resolve`
    /// over a structure the id is not in — because that conversion is where the
    /// defect was: an unresolvable id mapped to `.group([])`, which dims
    /// everything and lights nothing, while `CanvasBindingOffer.isOffered` guards
    /// `case .piece` and so (correctly, for a group) says nothing. Delete the
    /// chapter the canvas is filtered on and the board went dark with no lit set,
    /// no offer and no account of why.
    ///
    /// Read through the published tree because that is where "the board is
    /// dimmed" is observable at all from outside the view: `highlight` is
    /// `@State` on `CanvasView` and the drawn dim is pixels. The control below
    /// the ruling is what keeps this from being vacuous — the same fixture, the
    /// same window, an id that DOES resolve, and the dim is audible again.
    @MainActor
    func test_aSubjectNamingADeletedDocumentDimsNothing() throws {
        let structure = [
            StructureItem(id: "ch1", title: "One", type: .document, path: "One.md"),
            StructureItem(id: "ch2", title: "Two", type: .document, path: "Two.md")]
        let window = host(CanvasView(
            model: makeModel(), projectRoot: try boundRegionProjectRoot(),
            paletteSwatchHexes: { [] },
            subject: CanvasSubject.resolve(.item("ch3"), in: structure, research: [])))

        XCTAssertFalse(try axLabel(ofCardValued: secondScrapText, in: window)
                        .contains(CanvasAccessibility.dimmedTerm),
                       "the writer deleted the chapter this canvas was filtered on "
                       + "and every card went dim — nothing is lit, nothing is "
                       + "offered, and the tree no longer holds the row that would "
                       + "undo it")
        XCTAssertFalse(try axLabel(ofCardValued: scrapText, in: window)
                        .contains(CanvasAccessibility.dimmedTerm))

        try retarget(window, at: CanvasSubject.resolve(.item("ch2"), in: structure, research: []))
        XCTAssertTrue(try axLabel(ofCardValued: secondScrapText, in: window)
                        .contains(CanvasAccessibility.dimmedTerm),
                      "control: an id that RESOLVES still filters the board, so the "
                      + "reading above is about the unresolvable id and not about "
                      + "this window never dimming at all")
    }

    /// Decision 1, asked of the published tree rather than of the list.
    /// `CanvasAccessibilityTests.test_offscreenNodesAreStillInTheTree` proves
    /// `elements` returns the far card; that says nothing about whether SwiftUI
    /// keeps a synthetic child whose frame is 90 000 points outside the
    /// container's bounds. Culling is a drawing optimisation, and a node you
    /// cannot see is still a node you must be able to reach.
    func test_aCardFarOutsideTheViewportIsStillInThePublishedTree() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try threeCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        XCTAssertNoThrow(try axCard(valued: farScrapText, in: try axTree(in: window)),
                         "the card at (90 000, 90 000) is in the element list and not "
                         + "in the tree the window publishes, so a VoiceOver user can "
                         + "only reach what happens to be on screen — and cannot pan "
                         + "to the rest without being able to reach it first")
    }

    /// The state a new writer meets first, and the one state where the synthetic
    /// layer has nothing to publish. An `.accessibilityChildren` builder that
    /// produces ZERO children must still leave the canvas itself in the tree,
    /// saying what it is and how to start — otherwise the empty canvas is the
    /// blank rectangle §7A.6 is about, on the one screen where a writer most
    /// needs to be told where they are.
    ///
    /// **`accessibilityValueDescription`, and not `accessibilityValue` — and that
    /// is a fact about AppKit rather than a weakened assertion.** Measured against
    /// a hosted window on 2026-07-26: a view carrying `.accessibilityChildren`
    /// publishes role `AXGroup`, and that group *responds* to `accessibilityValue`
    /// and answers **nil**, while `accessibilityValueDescription` holds the whole
    /// of the string `.accessibilityValue(_:)` was given. Four spellings were
    /// tried to move it — `.isStaticText` before the children modifier,
    /// `.isStaticText` after it, `.accessibilityElement(children: .contain)`, and
    /// value-with-no-label — and all four publish `AXGroup` with the string in the
    /// same slot. The only thing that changes the role at all is dropping
    /// `.accessibilityChildren`, which deletes every card from the tree.
    ///
    /// It is **not** a zero-children effect, and the neighbouring test rather than
    /// this comment is what says so: a canvas holding one scrap files its own
    /// summary in the identical slot, and
    /// `test_theCanvasReadsOutItsScrapsRatherThanBeingABlankRectangle` asserts that
    /// beside a card's `accessibilityValue`. So the two are different slots for
    /// different roles, not a right one and a wrong one — `AXValue` is where an
    /// `AXStaticText` card's words go (that is what `CanvasAXChildren`'s trait is
    /// for), and `AXValueDescription` is the only value slot a group has.
    func test_anEmptyCanvasStillAnnouncesItselfInThePublishedTree() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try emptyProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        let canvas = try XCTUnwrap(
            try axTree(in: window).first {
                axString($0, "accessibilityLabel") == CanvasAccessibility.canvasLabel
            },
            "an empty canvas is not in the accessibility tree at all: a children "
            + "builder that produced no children took the canvas element with it, so "
            + "a VoiceOver user opening a new project lands on nothing")
        XCTAssertEqual(axString(canvas, "accessibilityValueDescription"),
                       CanvasAccessibility.emptyCanvasValue,
                       "the empty canvas is in the tree but says nothing — the one "
                       + "screen where a writer needs to be told how to begin")
    }

    /// **The whole of spec §7A.6 in one assertion.** Everything on this surface
    /// is drawn into a `Canvas`, and drawn content has no accessibility tree —
    /// so without the synthetic one a VoiceOver user meets a blank rectangle
    /// where the writer's entire plan is. Nothing else in the plan can see this:
    /// `CanvasAccessibilityTests` proves the element LIST is right, and the fact
    /// that a list is right says nothing about whether SwiftUI's hosting
    /// hierarchy ever publishes it.
    func test_theCanvasReadsOutItsScrapsRatherThanBeingABlankRectangle() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let all = try axTree(in: window)

        let canvas = try XCTUnwrap(
            all.first { axString($0, "accessibilityLabel") == CanvasAccessibility.canvasLabel },
            "the canvas itself is not in the accessibility tree, so there "
            + "is nothing for a VoiceOver user to land on and walk")
        // The canvas's own SUMMARY, and the only assertion anywhere that it
        // reaches the tree at all. `accessibilityValueDescription` because this
        // element carries `.accessibilityChildren` and is therefore an AXGroup,
        // whose `accessibilityValue` is nil however the value is spelled — the
        // measurement is written out on
        // `test_anEmptyCanvasStillAnnouncesItselfInThePublishedTree`. Asserting it
        // HERE, on a canvas that is not empty, is what makes that test's reading of
        // the same slot a fact about groups rather than about emptiness.
        //
        // The literal, not `CanvasAccessibility.summary(scene:)`: the words a
        // writer hears are the thing under test, and deriving them from the
        // implementation would assert nothing.
        XCTAssertEqual(axString(canvas, "accessibilityValueDescription"), "1 item",
                       "the canvas is in the tree and does not say how much is on "
                       + "it — a VoiceOver user lands on \"Planning canvas\" with no "
                       + "idea whether there is one card here or forty")
        // `accessibilityValue`, deliberately, and not "wherever the words ended
        // up". It is the slot the real NSTextView publishes its text in and the
        // slot VoiceOver reads; an element that files the writer's sentence under
        // AXValueDescription instead announces "Scrap" and stops. See the trait
        // in `CanvasAXChildren` — that failure was real, and this is what caught it.
        XCTAssertTrue(all.compactMap { axString($0, "accessibilityValue") }.contains(scrapText),
                      "the writer's scrap is drawn and nothing else — its synthetic "
                      + "element never reached the accessibility tree, so VoiceOver "
                      + "reads this canvas out as a blank rectangle (spec §7A.6)")
    }

    /// The other half of the slice's hand-smoke: *entering one lands you in a
    /// real text field*.
    ///
    /// Task 9 proved the mounted text view is among `ScrapEditorContainer`'s
    /// accessibility children, and said plainly that this is NOT evidence it is
    /// usefully reachable. Three things separate the two, and each is a way a
    /// writer using VoiceOver would be stuck on a surface whose unit tests are
    /// all green:
    ///
    ///  1. the editor is reachable from the hosted WINDOW, not merely from the
    ///     container that built it — `.accessibilityChildren` on the drawn layer
    ///     replaces children, and applying it a level too high would replace the
    ///     editor's;
    ///  2. it announces itself as EDITABLE TEXT, not as an unlabelled group;
    ///  3. it is where the keyboard focus actually is, so entering a scrap moves
    ///     an assistive client's focus into it rather than leaving it parked on
    ///     the synthetic twin of the card.
    func test_enteringAScrapLandsAssistiveFocusInARealTextField() throws {
        let window = host(CanvasView(model: makeModel(), projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)

        let reachable = try axTree(in: window).contains { $0 === editor }
        XCTAssertTrue(reachable,
                      "the mounted editor is not reachable in the accessibility "
                      + "tree the window publishes — the synthetic children have "
                      + "been installed somewhere that replaces it, so entering a "
                      + "scrap lands a VoiceOver user on nothing they can type into")

        XCTAssertEqual(editor.accessibilityRole(), .textArea,
                       "the thing entering a scrap lands on does not announce "
                       + "itself as editable text")
        XCTAssertEqual(editor.accessibilityValue() as? String, scrapText,
                       "the editor is reachable but says nothing — a text field "
                       + "that reads out empty is no better than the drawn card")

        // Read through KVC, and not for convenience. `accessibilityFocusedUIElement`
        // is an ObjC @property on the informal NSAccessibility protocol, and in
        // Swift a STATIC member of the same name shadows it on every instance:
        // `window.accessibilityFocusedUIElement()` fails with "static member
        // cannot be used on instance of type 'NSWindow'", and casting to
        // `NSAccessibilityProtocol` fails with "has no member" because the Swift
        // protocol does not surface it at all. Both spellings were tried.
        //
        // KVC reaches the real published property rather than a stand-in for it,
        // which matters here: asserting `window.firstResponder` instead would test
        // the INPUT to AX focus rather than what assistive technology is actually
        // handed. Verified against a standalone probe: with an NSTextView as first
        // responder, this returns that text view.
        //
        // Through `axAttribute` rather than a bare `value(forKey:)`, and for the
        // reason the rest of this file goes through it: on a key that ever stops
        // existing, bare KVC raises NSUnknownKeyException, which Swift cannot
        // catch — so the failure mode is this whole test process dying and taking
        // every other test in it down, instead of this one assertion failing with
        // the message below.
        let focused = axAttribute(window, "accessibilityFocusedUIElement").map { $0 as AnyObject }
        XCTAssertTrue(focused === editor,
                      "assistive focus is not in the editor after entering the "
                      + "scrap, so a VoiceOver user is left on the synthetic twin "
                      + "of a card whose real text field is elsewhere")
    }
}
