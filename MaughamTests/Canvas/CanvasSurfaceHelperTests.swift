import SwiftUI
import XCTest
@testable import Maugham

/// The helpers `CanvasView` builds per call (`CanvasSourceCensus.surfaceFiles`),
/// driven WITHOUT a window: each is built over a bare `CanvasModel()` with boxed
/// bindings, which is the one thing the move to per-call structs bought.
///
/// **These pin only what a mounted test already pins**, and each names that test.
/// The mounted family (`CanvasViewMounting*`) stays the behavioural net; this
/// suite is the fast, windowless second reading of the same rules.
@MainActor
final class CanvasSurfaceHelperTests: XCTestCase {

    /// A value the test owns, handed to a helper as a `Binding` — the stand-in
    /// for the view's `@State`. Tests may build `Binding(get:set:)`; production
    /// passes `$x` only (tripwire 3).
    private final class SurfaceHelperBox<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
        var binding: Binding<Value> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    private let scrapID = CanvasNodeID("s1ab")

    // MARK: - CanvasLayoutPass

    @MainActor
    private struct LayoutPassFixture {
        let model: CanvasModel
        let layouts = SurfaceHelperBox<[CanvasNodeID: ScrapLayout]>([:])
        let itemPresentation = SurfaceHelperBox(CanvasItemPresentation.empty)
        let thumbnails = SurfaceHelperBox(CanvasThumbnails())
        let ticket = SurfaceHelperBox(0)
        let revision = SurfaceHelperBox(0)

        var pass: CanvasLayoutPass {
            CanvasLayoutPass(model: model,
                             itemIndex: model.itemIndex,
                             projectRoot: URL(fileURLWithPath: "/nonexistent"),
                             thumbnails: thumbnails.binding,
                             layouts: layouts.binding,
                             itemPresentation: itemPresentation.binding,
                             thumbnailServiceTicket: ticket.binding,
                             revision: revision.binding)
        }
    }

    /// Mounted: `CanvasViewMountingSurfaceTests.test_aCardAddedFromOutsideTheCanvasIsMeasuredByTheHostedView`
    /// (and `test_anItemNodeThatArrivesWithNoHeightIsHealedOnLoad` for the item arm).
    func test_rebuildLayoutsHealsANodeWithNoCachedHeight() throws {
        let model = CanvasModel()
        let text = "a card that arrived with no height"
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: scrapID, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240))
        }
        model.setScrapText(text, for: scrapID)
        XCTAssertNil(try XCTUnwrap(model.scene.node(scrapID)).cachedHeight,
                     "precondition: the card arrives unmeasured")
        let fixture = LayoutPassFixture(model: model)
        let sceneRevision = model.sceneRevision

        fixture.pass.rebuildLayouts()

        XCTAssertEqual(try XCTUnwrap(model.scene.node(scrapID)).cachedHeight,
                       CanvasScrapMeasure.height(text: text, cardWidth: 240),
                       "the rebuild left a card with no height, so it has no frame "
                       + "and cannot be drawn or clicked")
        XCTAssertNotNil(fixture.layouts.value[scrapID],
                        "the scrap's layout was not cached through the binding")
        XCTAssertEqual(fixture.revision.value, 1, "the redraw counter did not tick")
        XCTAssertEqual(model.sceneRevision, sceneRevision + 1,
                       "the default call bumps the structural counter")
    }

    /// The first DIRECT pin of the layout drop. The mounted
    /// `CanvasViewMountingEditingTests.test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain`
    /// runs this rebuild (`bumpsStructuralCounter: false`) after the card has
    /// gone, but pins only the visible half: the card leaves the accessibility
    /// tree. No mounted test reads `layouts`.
    func test_rebuildLayoutsDropsALayoutWhoseNodeIsGone() {
        let model = CanvasModel()
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: scrapID, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240))
        }
        model.setScrapText("going", for: scrapID)
        let fixture = LayoutPassFixture(model: model)
        fixture.pass.rebuildLayouts()
        XCTAssertNotNil(fixture.layouts.value[scrapID], "precondition: a layout was built")

        model.withScene(persist: false) { $0.remove(scrapID) }
        let sceneRevision = model.sceneRevision
        fixture.pass.rebuildLayouts(bumpsStructuralCounter: false)

        XCTAssertNil(fixture.layouts.value[scrapID],
                     "a layout outlived its node and keeps the deleted text alive")
        XCTAssertEqual(model.sceneRevision, sceneRevision,
                       "`bumpsStructuralCounter: false` bumped the structural counter")
    }

    // MARK: - CanvasEditFocus

    @MainActor
    private struct EditFocusFixture {
        let model: CanvasModel
        let editingNodeID = SurfaceHelperBox<CanvasNodeID?>(nil)
        let caretIndex = SurfaceHelperBox<Int?>(nil)
        let straighten = SurfaceHelperBox(CanvasFocusStraighten())
        let lastKeystrokeAt = SurfaceHelperBox<Date?>(nil)
        let layouts = SurfaceHelperBox<[CanvasNodeID: ScrapLayout]>([:])
        let revision = SurfaceHelperBox(0)

        var focus: CanvasEditFocus {
            CanvasEditFocus(model: model,
                            editingNodeID: editingNodeID.binding,
                            caretIndex: caretIndex.binding,
                            straighten: straighten.binding,
                            lastKeystrokeAt: lastKeystrokeAt.binding,
                            layouts: layouts.binding,
                            revision: revision.binding)
        }
    }

    /// Both early returns. The first (nothing open) is the branch every
    /// mouse-down with nothing focused runs — `handleClick` → `commitActiveEdit`
    /// → `syncActiveEdit` — as in the bare-canvas click of
    /// `CanvasViewMountingEditingTests.test_aDoubleClickOnBareCanvasStillMakesOneScrapAndNoRegion`.
    /// The second is an open id whose layout has not been built.
    func test_syncActiveEditWithNoOpenScrapChangesNothing() throws {
        let model = CanvasModel()
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: scrapID, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240))
        }
        model.setScrapText("untouched", for: scrapID)
        let fixture = EditFocusFixture(model: model)
        let sceneRevision = model.sceneRevision

        fixture.focus.syncActiveEdit()
        fixture.focus.syncActiveEdit(fromKeystroke: true)

        XCTAssertEqual(model.scraps[scrapID], "untouched")
        XCTAssertNil(try XCTUnwrap(model.scene.node(scrapID)).cachedHeight, "a height was written")
        XCTAssertEqual(fixture.revision.value, 0, "the redraw counter ticked")
        XCTAssertNil(fixture.lastKeystrokeAt.value, "a keystroke time was recorded")
        XCTAssertEqual(model.sceneRevision, sceneRevision)

        // The second guard: an open scrap with no layout has nothing to fold.
        fixture.editingNodeID.value = scrapID
        fixture.focus.syncActiveEdit(fromKeystroke: true)
        XCTAssertEqual(model.scraps[scrapID], "untouched")
        XCTAssertNil(try XCTUnwrap(model.scene.node(scrapID)).cachedHeight, "a height was written")
        XCTAssertEqual(fixture.revision.value, 0, "the redraw counter ticked")
        XCTAssertNil(fixture.lastKeystrokeAt.value, "a keystroke time was recorded")
    }

    /// The first DIRECT pin of the clear. The mounted
    /// `CanvasViewMountingEditingTests.test_aPauseInsideAScrapEndsTheStepWhereTheWriterStopped`
    /// reads the idle beat off `lastKeystrokeAt` but never the clear; clearing it
    /// at the outer boundary is what keeps one visit's last keystroke from timing
    /// the next. This is the no-visit half of the bump guard too.
    func test_commitActiveEditClearsTheLastKeystroke() {
        let fixture = EditFocusFixture(model: CanvasModel())
        fixture.lastKeystrokeAt.value = Date()
        let sceneRevision = fixture.model.sceneRevision

        fixture.focus.commitActiveEdit()

        XCTAssertNil(fixture.lastKeystrokeAt.value,
                     "the outer boundary left the last keystroke standing")
        XCTAssertEqual(fixture.model.sceneRevision, sceneRevision,
                       "with no visit there is no accessibility element to refresh")
    }

    /// The other half of `commitActiveEdit`'s bump guard, which its doc calls
    /// "the point of it": WITH a visit, the scrap's accessibility element has
    /// been stale for the whole visit, so the structural counter moves exactly
    /// once. A first direct pin; the mounted family reaches it on every click
    /// out of an open scrap without counting the bump.
    func test_commitActiveEditWithAVisitBumpsTheStructuralCounterOnce() {
        let fixture = EditFocusFixture(model: CanvasModel())
        fixture.editingNodeID.value = scrapID
        fixture.lastKeystrokeAt.value = Date()
        let sceneRevision = fixture.model.sceneRevision

        fixture.focus.commitActiveEdit()

        XCTAssertEqual(fixture.model.sceneRevision, sceneRevision + 1,
                       "leaving a visited scrap must refresh the accessibility tree once")
        XCTAssertNil(fixture.lastKeystrokeAt.value)
        XCTAssertEqual(fixture.editingNodeID.value, scrapID,
                       "the commit closes the gesture; leaving the scrap is `leaveTheOpenScrap`'s")
    }

    // MARK: - CanvasDragHandler

    @MainActor
    private struct DragHandlerFixture {
        let model: CanvasModel
        let interaction = SurfaceHelperBox(CanvasInteraction())
        let momentum = SurfaceHelperBox(CanvasMomentum())
        let revision = SurfaceHelperBox(0)
        let editingNodeID = SurfaceHelperBox<CanvasNodeID?>(nil)
        let selectionWhenPressed = SurfaceHelperBox<CanvasSelection?>(nil)
        let layouts = SurfaceHelperBox<[CanvasNodeID: ScrapLayout]>([:])
        let itemPresentation = SurfaceHelperBox(CanvasItemPresentation.empty)
        let thumbnails = SurfaceHelperBox(CanvasThumbnails())
        let ticket = SurfaceHelperBox(0)

        var handler: CanvasDragHandler {
            CanvasDragHandler(model: model,
                              subject: .wholeProject,
                              layoutPass: CanvasLayoutPass(model: model,
                                                           itemIndex: model.itemIndex,
                                                           projectRoot: URL(fileURLWithPath: "/nonexistent"),
                                                           thumbnails: thumbnails.binding,
                                                           layouts: layouts.binding,
                                                           itemPresentation: itemPresentation.binding,
                                                           thumbnailServiceTicket: ticket.binding,
                                                           revision: revision.binding),
                              interaction: interaction.binding,
                              momentum: momentum.binding,
                              revision: revision.binding,
                              editingNodeID: editingNodeID.binding,
                              selectionWhenPressed: selectionWhenPressed.binding)
        }

        func press(at point: CGPoint) {
            handler.handleDrag(at: point, phase: .began, shiftHeld: false, timestamp: 0)
        }
    }

    /// **A press inside an open scrap belongs to the editor**, so `handleDrag`'s
    /// focus guard returns before `interaction.begin` and opens no undo bracket.
    /// The first direct pin of that guard: the mounted
    /// `CanvasViewMountingSurfaceTests.test_thePressThatEntersAScrapStopsTheCardCoastingUnderIt`
    /// runs the press that enters a scrap, but pins only the coast stopping above
    /// the guard. The control is the same press with nothing open.
    func test_aPressWhileAScrapIsOpenBeginsNoGesture() {
        let model = CanvasModel()
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: scrapID, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240, cachedHeight: 80))
        }
        let onTheCard = CGPoint(x: 100, y: 60)

        let control = DragHandlerFixture(model: model)
        control.press(at: onTheCard)
        XCTAssertTrue(control.interaction.value.isActive,
                      "control: with nothing open, a press on the card begins a move")
        XCTAssertTrue(model.isInGesture, "control: the move opened its undo bracket")
        model.endGesture()

        let fixture = DragHandlerFixture(model: model)
        fixture.editingNodeID.value = scrapID
        fixture.press(at: onTheCard)

        XCTAssertFalse(fixture.interaction.value.isActive,
                       "a press inside the open scrap began a canvas gesture under the editor")
        XCTAssertFalse(model.isInGesture,
                       "a press inside the open scrap opened an undo bracket nothing closes")
    }

    /// **A read-only canvas begins no drag** (`CanvasEditGate.dragBegins`), and
    /// the gate is asked before `interaction.begin`, so no bracket opens. The
    /// ORDER is pinned in source by
    /// `CanvasEditGateTests.test_theCanvasAsksTheGateBeforeEachAct`; no mounted
    /// test drags a refused canvas, so this is the first behavioural pin. The
    /// control is the same press on a writable model.
    func test_aPressOnAReadOnlyCanvasBeginsNoGesture() throws {
        let bareCanvas = CGPoint(x: 900, y: 900)

        let writable = DragHandlerFixture(model: CanvasModel())
        writable.press(at: bareCanvas)
        XCTAssertTrue(writable.interaction.value.isActive,
                      "control: a press on bare writable canvas begins a region sweep")

        let root = TestTemp.root.appendingPathComponent("drag-read-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sidecar = root.appendingPathComponent(CanvasStore.sidecarRelativePath)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "not json at all".write(to: sidecar, atomically: true, encoding: .utf8)
        let model = CanvasModel()
        model.attach(projectRoot: root)
        defer { model.detach() }
        XCTAssertTrue(model.isReadOnly, "precondition: the damaged layout file was refused")

        let fixture = DragHandlerFixture(model: model)
        fixture.press(at: bareCanvas)

        XCTAssertFalse(fixture.interaction.value.isActive,
                       "a read-only canvas began a drag")
        XCTAssertFalse(model.isInGesture, "a read-only canvas opened an undo bracket")
    }

    // MARK: - CanvasClickHandler

    @MainActor
    private struct ClickHandlerFixture {
        let model: CanvasModel
        let selectionWhenPressed = SurfaceHelperBox<CanvasSelection?>(nil)
        let editingNodeID = SurfaceHelperBox<CanvasNodeID?>(nil)
        let caretIndex = SurfaceHelperBox<Int?>(nil)
        let lastKeystrokeAt = SurfaceHelperBox<Date?>(nil)
        let straighten = SurfaceHelperBox(CanvasFocusStraighten())
        let layouts = SurfaceHelperBox<[CanvasNodeID: ScrapLayout]>([:])
        let revision = SurfaceHelperBox(0)
        let itemPresentation = SurfaceHelperBox(CanvasItemPresentation.empty)
        let thumbnails = SurfaceHelperBox(CanvasThumbnails())
        let ticket = SurfaceHelperBox(0)

        var handler: CanvasClickHandler {
            CanvasClickHandler(model: model,
                               editFocus: CanvasEditFocus(model: model,
                                                          editingNodeID: editingNodeID.binding,
                                                          caretIndex: caretIndex.binding,
                                                          straighten: straighten.binding,
                                                          lastKeystrokeAt: lastKeystrokeAt.binding,
                                                          layouts: layouts.binding,
                                                          revision: revision.binding),
                               layoutPass: CanvasLayoutPass(model: model,
                                                            itemIndex: model.itemIndex,
                                                            projectRoot: URL(fileURLWithPath: "/nonexistent"),
                                                            thumbnails: thumbnails.binding,
                                                            layouts: layouts.binding,
                                                            itemPresentation: itemPresentation.binding,
                                                            thumbnailServiceTicket: ticket.binding,
                                                            revision: revision.binding),
                               selectionWhenPressed: selectionWhenPressed.binding,
                               editingNodeID: editingNodeID.binding,
                               caretIndex: caretIndex.binding,
                               lastKeystrokeAt: lastKeystrokeAt.binding,
                               straighten: straighten.binding,
                               layouts: layouts.binding,
                               revision: revision.binding)
        }

        func click(at point: CGPoint, clickCount: Int) {
            handler.handleClick(at: point, clickCount: clickCount)
        }
    }

    /// A model holding one measured scrap, selected — so a click that clears
    /// the selection or mints a second card is visible.
    private func modelWithASelectedScrap() -> CanvasModel {
        let model = CanvasModel()
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: scrapID, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240, cachedHeight: 80))
        }
        model.setScrapText("already here", for: scrapID)
        model.selection = .node(scrapID)
        return model
    }

    /// **A single click on bare canvas selects nothing and leaves the open scrap.**
    /// Mounted: `CanvasViewMountingEditingTests.test_aSingleClickSelectsTheThingUnderIt`
    /// (its last press clears the selection on bare canvas), with no scrap open.
    /// This one starts inside a visit, so the leave, the closed bracket and
    /// `selectionWhenPressed` — captured BEFORE the click cleared the selection —
    /// are pinned too.
    func test_aSingleClickOnBareCanvasSelectsNothingAndLeavesNoScrapOpen() {
        let model = modelWithASelectedScrap()
        let fixture = ClickHandlerFixture(model: model)
        fixture.editingNodeID.value = scrapID
        fixture.caretIndex.value = 3
        fixture.straighten.value.focus(scrapID)
        model.beginGesture("Edit Scrap")

        fixture.click(at: CGPoint(x: 900, y: 900), clickCount: 1)

        XCTAssertNil(model.selection, "a click on bare canvas left something selected")
        XCTAssertNil(fixture.editingNodeID.value, "a click on bare canvas left the scrap open")
        XCTAssertNil(fixture.caretIndex.value)
        XCTAssertNil(fixture.straighten.value.focusedNodeID,
                     "the card the writer clicked away from is still straightening")
        XCTAssertFalse(model.isInGesture, "the visit's undo bracket was left open")
        XCTAssertEqual(model.scene.nodes.count, 1, "a single click made a scrap")
        XCTAssertEqual(fixture.selectionWhenPressed.value, .node(scrapID),
                       "`selectionWhenPressed` was not captured before the click "
                       + "moved the selection — the connect-mark drag reads it")
    }

    /// **A double click on bare canvas mints one scrap and opens it at the start.**
    /// Mounted: `CanvasViewMountingEditingTests.test_aDoubleClickOnBareCanvasStillMakesOneScrapAndNoRegion`
    /// types into the new scrap and reads the disk; no mounted test reads
    /// `caretIndex` or `selectionWhenPressed` on this path.
    func test_aDoubleClickOnBareCanvasMintsOneScrapAndOpensItAtTheStart() throws {
        let model = modelWithASelectedScrap()
        let fixture = ClickHandlerFixture(model: model)

        fixture.click(at: CGPoint(x: 900, y: 900), clickCount: 2)

        let minted = model.scene.nodes.map(\.id).filter { $0 != scrapID }
        XCTAssertEqual(minted.count, 1, "a double click on bare canvas must make exactly one scrap")
        let id = try XCTUnwrap(minted.first)
        XCTAssertEqual(fixture.editingNodeID.value, id, "the new scrap was not opened")
        XCTAssertEqual(fixture.caretIndex.value, 0, "the new scrap's caret is not at its start")
        XCTAssertEqual(fixture.straighten.value.focusedNodeID, id)
        XCTAssertNotNil(try XCTUnwrap(model.scene.node(id)).cachedHeight,
                        "the new scrap was not measured, so it has no frame")
        XCTAssertEqual(fixture.selectionWhenPressed.value, .node(scrapID),
                       "`selectionWhenPressed` is not the selection from before the click")
        XCTAssertTrue(model.isInGesture, "the typing's \"Edit Scrap\" bracket did not open")
        model.endGesture()
    }
}
