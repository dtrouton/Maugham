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

    /// Mounted: `CanvasViewMountingEditingTests.test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain`,
    /// whose delete runs this rebuild (`bumpsStructuralCounter: false`) after the
    /// card has gone.
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

    /// Mounted: `CanvasViewMountingEditingTests.test_quittingAfterAPauseFoldsTheTextInWithoutMovingAnUndoBoundary`
    /// (the quit hook's `syncActiveEdit()` folds and moves no boundary); with no
    /// scrap open there is nothing to fold at all.
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
    }

    /// Mounted: `CanvasViewMountingEditingTests.test_aPauseInsideAScrapEndsTheStepWhereTheWriterStopped`
    /// reads the idle beat off `lastKeystrokeAt`; clearing it at the outer
    /// boundary is what keeps one visit's last keystroke from timing the next.
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
}
