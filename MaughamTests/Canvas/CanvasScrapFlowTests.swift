import SwiftUI
import XCTest
@testable import Maugham

/// `CanvasScrapFlow`, the one way to make and enter a scrap, and the pure
/// `CanvasInteraction.creationBinding` it asks — driven WITHOUT a window, over
/// boxed bindings as in `CanvasSurfaceHelperTests`.
///
/// The mounted net for the double click stays
/// `CanvasViewMountingEditingTests.test_aDoubleClickOnBareCanvasStillMakesOneScrapAndNoRegion`
/// and `CanvasViewMountingRegionTests`; this suite pins the chapter binding,
/// the line and the two undo steps, which no mounted test reads.
@MainActor
final class CanvasScrapFlowTests: XCTestCase {

    /// A value the test owns, handed to the helper as a `Binding` — the stand-in
    /// for the view's `@State`. `@unchecked Sendable` because `Binding`'s
    /// closures are `@Sendable`; every test here runs on the main actor.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
        var binding: Binding<Value> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    @MainActor
    private struct Fixture {
        let model: CanvasModel
        let subject: CanvasSubject
        let editingNodeID = Box<CanvasNodeID?>(nil)
        let caretIndex = Box<Int?>(nil)
        let lastKeystrokeAt = Box<Date?>(nil)
        let straighten = Box(CanvasFocusStraighten())
        let layouts = Box<[CanvasNodeID: ScrapLayout]>([:])
        let itemPresentation = Box(CanvasItemPresentation.empty)
        let thumbnails = Box(CanvasThumbnails())
        let ticket = Box(0)
        let revision = Box(0)

        var flow: CanvasScrapFlow {
            CanvasScrapFlow(model: model,
                            subject: subject,
                            layoutPass: CanvasLayoutPass(model: model,
                                                         itemIndex: model.itemIndex,
                                                         projectRoot: URL(fileURLWithPath: "/nonexistent"),
                                                         thumbnails: thumbnails.binding,
                                                         layouts: layouts.binding,
                                                         itemPresentation: itemPresentation.binding,
                                                         thumbnailServiceTicket: ticket.binding,
                                                         revision: revision.binding),
                            editingNodeID: editingNodeID.binding,
                            caretIndex: caretIndex.binding,
                            lastKeystrokeAt: lastKeystrokeAt.binding,
                            straighten: straighten.binding)
        }
    }

    private let region = CanvasRegionID("r1ab")
    private var root: URL!

    override func setUpWithError() throws {
        root = TestTemp.root.appendingPathComponent("scrap-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Attached, because a bare model has no snapshot to register a step from.
    private func attachedModel() -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        addTeardownBlock { @MainActor in model.detach() }
        return model
    }

    private func scene(regionBoundTo piece: String?) -> CanvasScene {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: region, label: "R",
                                    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                    boundPieceID: piece))
        return s
    }

    // MARK: - creationBinding (pure)

    func test_aChapterSubjectBindsANewLooseScrap() {
        XCTAssertEqual(CanvasInteraction.creationBinding(subject: .piece("p1"), home: nil,
                                                         in: CanvasScene()), "p1",
                       "a loose scrap made while a chapter is selected must belong to it")
    }

    func test_theBookLeavesItUnbound() {
        for subject: CanvasSubject in [.wholeProject, .group(["p1", "p2"]), .research("i1")] {
            XCTAssertNil(CanvasInteraction.creationBinding(subject: subject, home: nil,
                                                           in: CanvasScene()),
                         "\(subject) names no one piece, so the scrap stays unbound")
            XCTAssertNil(CanvasInteraction.creationBinding(subject: subject, home: region,
                                                           in: scene(regionBoundTo: nil)),
                         "\(subject) in an unbound region still names no piece")
        }
    }

    func test_anUnboundRegionStillGetsTheScrapItsOwnBinding() {
        XCTAssertEqual(CanvasInteraction.creationBinding(subject: .piece("p1"), home: region,
                                                         in: scene(regionBoundTo: nil)), "p1")
    }

    func test_aRegionBoundToTheSameChapterIsFollowed() {
        XCTAssertNil(CanvasInteraction.creationBinding(subject: .piece("p1"), home: region,
                                                       in: scene(regionBoundTo: "p1")),
                     "the region already carries the chapter; a scrap of its own would "
                     + "outlive a later rebinding of the region")
    }

    /// The ruled precedence: the region wins, and the scrap follows it.
    func test_aRegionBoundElsewhereLeavesTheScrapUnbound() {
        XCTAssertNil(CanvasInteraction.creationBinding(subject: .piece("p1"), home: region,
                                                       in: scene(regionBoundTo: "p2")))
    }

    // MARK: - makeScrapAndEnter / enter

    func test_makeScrapAndEnterIsOneNewScrapStepThenAnEditScrapStep() throws {
        let model = attachedModel()
        let fixture = Fixture(model: model, subject: .piece("p1"))

        let id = fixture.flow.makeScrapAndEnter(at: CGPoint(x: 2000, y: 2000))

        XCTAssertEqual(fixture.editingNodeID.value, id, "the new scrap was not entered")
        XCTAssertEqual(fixture.caretIndex.value, 0)
        XCTAssertNil(fixture.lastKeystrokeAt.value)
        XCTAssertEqual(fixture.straighten.value.focusedNodeID, id)
        XCTAssertTrue(model.isInGesture, "\"Edit Scrap\" is not open")
        XCTAssertEqual(try XCTUnwrap(model.scene.node(id)).boundPieceID, "p1")
        XCTAssertTrue(CanvasHighlight.resolve(subject: .piece("p1"), in: model.scene)
                        .nodes.contains(id),
                      "the new scrap is dimmed under the chapter it was made for")

        model.setScrapText("Hello.", for: id)
        model.breakGesture()
        model.endGesture()

        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo Edit Scrap")
        model.undo.undo()
        XCTAssertEqual(model.scraps[id], "", "the first undo did not take back the words")
        XCTAssertNotNil(model.scene.node(id), "the first undo took the card as well")
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo New Scrap")
        model.undo.undo()
        XCTAssertNil(model.scene.node(id), "the second undo did not take back the card")
        XCTAssertFalse(model.undo.canUndo, "making a scrap took more than two steps")
    }

    func test_aJoinedScrapsLineIsInTheNewScrapStep() throws {
        let model = attachedModel()
        let a = CanvasNodeID("s1ab")
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: a, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240, cachedHeight: 80))
        }
        model.setScrapText("from here", for: a)
        let baseline = model.scene.lineCount
        let fixture = Fixture(model: model, subject: .wholeProject)

        let id = fixture.flow.makeScrapAndEnter(at: CGPoint(x: 400, y: 40), joinedTo: a)

        let line = try XCTUnwrap(model.scene.lines.first, "no line joins the new scrap")
        XCTAssertEqual(Set([line.from, line.to]), Set([a, id]))
        XCTAssertEqual(model.scene.lineCount, baseline + 1)
        XCTAssertNil(try XCTUnwrap(model.scene.node(id)).boundPieceID,
                     "the whole project binds nothing")

        model.endGesture()   // the empty "Edit Scrap" registers nothing
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo New Scrap")
        model.undo.undo()
        XCTAssertNil(model.scene.node(id), "one undo did not take the card")
        XCTAssertEqual(model.scene.lineCount, baseline, "one undo left the line behind")
        XCTAssertNotNil(model.scene.node(a), "the undo took the scrap it was joined to")
    }

    /// A join to a card that is no longer there (deleted between the key and
    /// the make) makes the scrap with no line, rather than a line to nothing.
    func test_aJoinToAMissingCardMakesNoLine() throws {
        let model = attachedModel()
        let gone = CanvasNodeID("g1ab")
        let fixture = Fixture(model: model, subject: .wholeProject)

        let id = fixture.flow.makeScrapAndEnter(at: CGPoint(x: 400, y: 40), joinedTo: gone)

        XCTAssertNotNil(model.scene.node(id), "the scrap was not made")
        XCTAssertEqual(model.scene.lineCount, 0, "a line was drawn to a card that is not there")
        model.endGesture()
    }

    /// The click arm's ordering, kept: "New Scrap" closes AFTER the measure, so
    /// undoing the typing restores a card WITH a height. Close it before and the
    /// restored card has no frame — invisible to hit testing and the renderer.
    func test_anEnteredScrapIsMeasuredBeforeTheEditStepOpens() throws {
        let model = attachedModel()
        let fixture = Fixture(model: model, subject: .wholeProject)

        let id = fixture.flow.makeScrapAndEnter(at: CGPoint(x: 100, y: 100))
        XCTAssertNotNil(try XCTUnwrap(model.scene.node(id)).cachedHeight)

        model.setScrapText("Typed.", for: id)
        model.endGesture()
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo Edit Scrap")
        model.undo.undo()

        XCTAssertNotNil(try XCTUnwrap(model.scene.node(id),
                                      "undoing the typing took the card").cachedHeight,
                        "\"Edit Scrap\" opened on a card with no height")
    }

    func test_aNewScrapInsideARegionJoinsItByCentre() throws {
        let model = attachedModel()
        model.withScene(persist: false) {
            $0.insertRegion(CanvasRegion(id: region, label: "R",
                                         frame: CGRect(x: 0, y: 0, width: 800, height: 600)))
        }
        let fixture = Fixture(model: model, subject: .piece("p1"))
        let sceneRevision = model.sceneRevision

        let id = fixture.flow.makeScrapAndEnter(at: CGPoint(x: 100, y: 100))

        XCTAssertEqual(CanvasMembership.homeRegion(of: id, in: model.scene), region,
                       "a scrap made inside a region did not join it")
        XCTAssertEqual(try XCTUnwrap(model.scene.node(id)).boundPieceID, "p1",
                       "an unbound home region still gives the scrap its own binding")
        XCTAssertGreaterThan(model.sceneRevision, sceneRevision + 1,
                             "the join and bind after the measure did not bump the structural counter")

        model.endGesture()
        model.undo.undo()
        XCTAssertNil(model.scene.node(id))
        XCTAssertEqual(try XCTUnwrap(model.scene.region(region)).homeMembers, [],
                       "one undo did not take back the membership with the card")
    }

    /// `enter` alone: an existing measured scrap, at the caret the caller worked
    /// out, opens "Edit Scrap" and nothing else.
    func test_enterOpensTheEditStepAtTheGivenCaret() throws {
        let model = attachedModel()
        let a = CanvasNodeID("s1ab")
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: a, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240, cachedHeight: 80))
        }
        model.setScrapText("already here", for: a)
        let fixture = Fixture(model: model, subject: .piece("p1"))
        fixture.lastKeystrokeAt.value = Date()

        fixture.flow.enter(a, caretIndex: 7)

        XCTAssertEqual(fixture.editingNodeID.value, a)
        XCTAssertEqual(fixture.caretIndex.value, 7)
        XCTAssertNil(fixture.lastKeystrokeAt.value)
        XCTAssertEqual(fixture.straighten.value.focusedNodeID, a)
        XCTAssertTrue(model.isInGesture)
        XCTAssertNil(try XCTUnwrap(model.scene.node(a)).boundPieceID,
                     "entering a scrap binds nothing")
    }
}
