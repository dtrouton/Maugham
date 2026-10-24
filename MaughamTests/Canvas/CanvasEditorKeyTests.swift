import AppKit
import SwiftUI
import XCTest
@testable import Maugham

/// The keys inside a scrap — `CanvasKeyHandler.handleEditorCommand` — driven
/// WITHOUT a window, over boxed bindings as in `CanvasScrapFlowTests`.
///
/// Return, ⇧Return's opposite, and Escape finish the scrap; Tab makes a joined
/// one to the right and ⌘Return one below. The delivery (which selector reaches
/// the delegate, and when ⌘Return is claimed) is `ScrapEditorHostTests`'; the
/// real-event net is `CanvasViewMountingEditingTests`.
@MainActor
final class CanvasEditorKeyTests: XCTestCase {

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
        var subject: CanvasSubject = .wholeProject
        let editingNodeID = Box<CanvasNodeID?>(nil)
        let caretIndex = Box<Int?>(nil)
        let lastKeystrokeAt = Box<Date?>(nil)
        let straighten = Box(CanvasFocusStraighten())
        let layouts = Box<[CanvasNodeID: ScrapLayout]>([:])
        let itemPresentation = Box(CanvasItemPresentation.empty)
        let thumbnails = Box(CanvasThumbnails())
        let thumbnailTicket = Box(0)
        let revision = Box(0)
        let camera = Box(CanvasCamera())
        let keyboardTicket = Box(0)

        var layoutPass: CanvasLayoutPass {
            CanvasLayoutPass(model: model,
                             itemIndex: model.itemIndex,
                             projectRoot: URL(fileURLWithPath: "/nonexistent"),
                             thumbnails: thumbnails.binding,
                             layouts: layouts.binding,
                             itemPresentation: itemPresentation.binding,
                             thumbnailServiceTicket: thumbnailTicket.binding,
                             revision: revision.binding)
        }

        var editFocus: CanvasEditFocus {
            CanvasEditFocus(model: model,
                            editingNodeID: editingNodeID.binding,
                            caretIndex: caretIndex.binding,
                            straighten: straighten.binding,
                            lastKeystrokeAt: lastKeystrokeAt.binding,
                            layouts: layouts.binding,
                            revision: revision.binding)
        }

        var scrapFlow: CanvasScrapFlow {
            CanvasScrapFlow(model: model,
                            subject: subject,
                            layoutPass: layoutPass,
                            editingNodeID: editingNodeID.binding,
                            caretIndex: caretIndex.binding,
                            lastKeystrokeAt: lastKeystrokeAt.binding,
                            straighten: straighten.binding)
        }

        var handler: CanvasKeyHandler {
            CanvasKeyHandler(model: model,
                             subject: subject,
                             selectTheProjectRow: {},
                             returnKeyboardToTree: {},
                             editFocus: editFocus,
                             layoutPass: layoutPass,
                             scrapFlow: scrapFlow,
                             editingNodeID: editingNodeID.binding,
                             revision: revision.binding,
                             camera: camera.binding,
                             keyboardTicket: keyboardTicket.binding)
        }

        /// The writer is inside `id` and has typed `typed`: the shared stack
        /// holds the words and the model does not have them yet — exactly the
        /// state between a keystroke and its fold.
        func enter(_ id: CanvasNodeID, typed: String) {
            layouts.value = [:]
            layoutPass.rebuildLayouts()
            scrapFlow.enter(id, caretIndex: 0)
            layouts.value[id] = Self.layout(typed)
        }

        static func layout(_ text: String) -> ScrapLayout {
            ScrapLayout(text: text, width: 220,
                        font: NSFont(name: "Iowan Old Style", size: 13) ?? .systemFont(ofSize: 13))
        }
    }

    private let a = CanvasNodeID("a1bc")
    private let viewSize = CGSize(width: 800, height: 600)
    private var root: URL!

    override func setUpWithError() throws {
        root = TestTemp.root.appendingPathComponent("editor-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Attached, because a bare model has no snapshot to register a step from.
    /// Card A sits at (40, 40), 240 wide, with words already on disk.
    private func modelWithACard() -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        addTeardownBlock { @MainActor in model.detach() }
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: a, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240, cachedHeight: 60))
        }
        model.setScrapText("", for: a)
        return model
    }

    private func frame(_ id: CanvasNodeID, in model: CanvasModel) throws -> CGRect {
        try XCTUnwrap(model.scene.node(id)?.frame, "\(id) has no frame")
    }

    // MARK: - Finish

    func test_finishFoldsTheTextLeavesTheScrapSelectedAndAsksForTheKeyboard() throws {
        let model = modelWithACard()
        let fixture = Fixture(model: model)
        fixture.enter(a, typed: "the falls at night")

        XCTAssertTrue(fixture.handler.handleEditorCommand(.finish, viewSize: viewSize))

        XCTAssertEqual(model.scraps[a], "the falls at night", "the typed words were not folded in")
        XCTAssertNil(fixture.editingNodeID.value, "the scrap is still open")
        XCTAssertEqual(model.selection, .node(a), "the finished scrap is not selected")
        XCTAssertEqual(fixture.keyboardTicket.value, 1,
                       "the canvas was not asked to take the keyboard, so Return, Tab "
                       + "and the arrows go nowhere after the finish")
        XCTAssertFalse(model.isInGesture, "\"Edit Scrap\" was left open")
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo Edit Scrap")
    }

    /// Escape is a FINISH, never a cancel: what the writer typed stays, and
    /// the visit is its own undo step.
    func test_escapeFinishesAndNeverDiscards() throws {
        let model = modelWithACard()
        let fixture = Fixture(model: model)
        fixture.enter(a, typed: "keep every word")
        let command = try XCTUnwrap(CanvasKeyboard.editorCommand(
            selector: #selector(NSResponder.cancelOperation(_:)), modifiers: [], hasMarkedText: false))
        XCTAssertEqual(command, .finish)

        XCTAssertTrue(fixture.handler.handleEditorCommand(command, viewSize: viewSize))

        XCTAssertEqual(model.scraps[a], "keep every word", "Escape threw the typing away")
        XCTAssertNil(fixture.editingNodeID.value)
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo Edit Scrap",
                       "the visit is not its own step, so ⌘Z cannot take it back alone")
    }

    // MARK: - Making the next scrap

    func test_makeJoinedFinishesThenMakesAJoinedScrapToTheRightAndEntersIt() throws {
        let model = modelWithACard()
        // A card where the joined one would first land, so the placement steps down.
        let blocker = CanvasNodeID("b1oc")
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: blocker, kind: .scrap,
                                 origin: CGPoint(x: 300, y: 40), width: 240, cachedHeight: 60))
        }
        model.setScrapText("in the way", for: blocker)
        let fixture = Fixture(model: model)
        fixture.enter(a, typed: "first thought")
        let before = Set(model.scene.unorderedNodes.map(\.id))

        XCTAssertTrue(fixture.handler.handleEditorCommand(.makeJoined, viewSize: viewSize))

        XCTAssertEqual(model.scraps[a], "first thought", "A's words were not folded before the make")
        let made = Set(model.scene.unorderedNodes.map(\.id)).subtracting(before)
        XCTAssertEqual(made.count, 1, "Tab did not make exactly one scrap")
        let b = try XCTUnwrap(made.first)
        let aFrame = try frame(a, in: model), bFrame = try frame(b, in: model)
        XCTAssertGreaterThan(bFrame.minX, aFrame.maxX, "the joined scrap is not to the right of A")
        for other in before {
            XCTAssertFalse(bFrame.intersects(try frame(other, in: model)),
                           "the new scrap lands on top of \(other)")
        }
        let line = try XCTUnwrap(model.scene.lines.first, "no line joins A and the new scrap")
        XCTAssertEqual(Set([line.from, line.to]), Set([a, b]))
        XCTAssertEqual(fixture.editingNodeID.value, b, "the new scrap was not entered")
        XCTAssertTrue(model.isInGesture, "\"Edit Scrap\" is not open on the new scrap")
        XCTAssertEqual(fixture.keyboardTicket.value, 0,
                       "the canvas was asked for the keyboard while the new editor is "
                       + "taking it — the two would race for first responder")
        model.endGesture()
    }

    func test_makeBelowPlacesUnderWithNoLine() throws {
        let model = modelWithACard()
        let fixture = Fixture(model: model)
        fixture.enter(a, typed: "above")
        let before = Set(model.scene.unorderedNodes.map(\.id))

        XCTAssertTrue(fixture.handler.handleEditorCommand(.makeBelow, viewSize: viewSize))

        let b = try XCTUnwrap(Set(model.scene.unorderedNodes.map(\.id)).subtracting(before).first,
                              "⌘Return made no scrap")
        let aFrame = try frame(a, in: model), bFrame = try frame(b, in: model)
        XCTAssertEqual(bFrame.minX, aFrame.minX, "the scrap below is not aligned under A")
        XCTAssertGreaterThan(bFrame.minY, aFrame.maxY, "the new scrap is not below A")
        XCTAssertEqual(model.scene.lineCount, 0, "⌘Return drew a line")
        XCTAssertEqual(fixture.editingNodeID.value, b)
        model.endGesture()
    }

    /// The new card is brought into view: a card made off the right edge of the
    /// view moves the camera, and the camera's own reveal decides how far.
    func test_aScrapMadeOffScreenIsRevealed() throws {
        let model = modelWithACard()
        let fixture = Fixture(model: model)
        fixture.enter(a, typed: "near the edge")

        XCTAssertTrue(fixture.handler.handleEditorCommand(.makeJoined,
                                                          viewSize: CGSize(width: 400, height: 300)))

        let b = try XCTUnwrap(fixture.editingNodeID.value)
        let bFrame = try frame(b, in: model)
        let camera = fixture.camera.value
        let right = camera.viewPoint(fromContent: CGPoint(x: bFrame.maxX, y: bFrame.maxY))
        XCTAssertLessThanOrEqual(right.x, 400, "the new scrap is off the right of the view")
        XCTAssertNotEqual(camera, CanvasCamera(), "control: the camera moved at all")
        model.endGesture()
    }

    func test_tabThenTypeUndoesTextThenScrapAndLine() throws {
        let model = modelWithACard()
        let fixture = Fixture(model: model)
        fixture.enter(a, typed: "A's words")

        XCTAssertTrue(fixture.handler.handleEditorCommand(.makeJoined, viewSize: viewSize))
        let b = try XCTUnwrap(fixture.editingNodeID.value)
        fixture.layouts.value[b] = Fixture.layout("B's words")
        XCTAssertTrue(fixture.handler.handleEditorCommand(.finish, viewSize: viewSize))
        XCTAssertEqual(model.scraps[b], "B's words", "precondition: B's typing was folded")

        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo Edit Scrap")
        model.undo.undo()
        XCTAssertEqual(model.scraps[b], "", "the first ⌘Z did not take back B's words")
        XCTAssertNotNil(model.scene.node(b), "the first ⌘Z took the card as well")
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo New Scrap")
        model.undo.undo()
        XCTAssertNil(model.scene.node(b), "the second ⌘Z did not take back the scrap")
        XCTAssertEqual(model.scene.lineCount, 0, "the second ⌘Z left the line behind")
        XCTAssertEqual(model.scraps[a], "A's words", "A's words did not survive both undos")
    }

    // MARK: - Refusals after the fold

    /// A gesture still open after the fold (a drag over the editor's own
    /// bracket) makes nothing — but the finish has already happened, so the
    /// words are in and the scrap is left. The key is still USED: handing it
    /// back would let the text view insert a tab into the scrap just left,
    /// words the model would never see.
    func test_aCommandMidDragIsRefusedAfterTheFold() throws {
        let model = modelWithACard()
        let fixture = Fixture(model: model)
        fixture.enter(a, typed: "held")
        // Relies on undo gestures NESTING ("Edit Scrap" inside "Move Card"); a
        // change to flat brackets must revisit this test.
        model.beginGesture("Move Card")
        let count = model.scene.count

        XCTAssertTrue(fixture.handler.handleEditorCommand(.makeJoined, viewSize: viewSize),
                      "the finish ran, so the key was used")

        XCTAssertEqual(model.scene.count, count, "a scrap was made inside an open gesture")
        XCTAssertEqual(model.scraps[a], "held", "the words were lost with the refusal")
        XCTAssertNil(fixture.editingNodeID.value, "the scrap is still open")
        XCTAssertEqual(fixture.keyboardTicket.value, 1,
                       "nothing was made, so the canvas must take the keyboard")
        model.endGesture()
        XCTAssertFalse(model.isInGesture)
    }

    func test_aMakeOnAReadOnlyCanvasFinishesAndMakesNothing() throws {
        let sidecar = root.appendingPathComponent(CanvasStore.sidecarRelativePath)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "not json at all".write(to: sidecar, atomically: true, encoding: .utf8)
        let model = CanvasModel()
        model.attach(projectRoot: root)
        defer { model.detach() }
        XCTAssertTrue(model.isReadOnly, "precondition: the damaged layout file was refused")
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: a, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240, cachedHeight: 60))
        }
        let fixture = Fixture(model: model)
        fixture.editingNodeID.value = a
        let count = model.scene.count

        XCTAssertTrue(fixture.handler.handleEditorCommand(.makeBelow, viewSize: viewSize))

        XCTAssertEqual(model.scene.count, count, "a read-only canvas made a scrap")
        XCTAssertNil(fixture.editingNodeID.value)
        XCTAssertFalse(model.isInGesture)
    }

    // MARK: - A chapter

    func test_aNewChapterScrapFromTabIsBoundAndLit() throws {
        let model = modelWithACard()
        let fixture = Fixture(model: model, subject: .piece("p1"))
        fixture.enter(a, typed: "for chapter one")

        XCTAssertTrue(fixture.handler.handleEditorCommand(.makeJoined, viewSize: viewSize))

        let b = try XCTUnwrap(fixture.editingNodeID.value)
        XCTAssertEqual(try XCTUnwrap(model.scene.node(b)).boundPieceID, "p1",
                       "a scrap made by Tab while a chapter is selected does not belong to it")
        XCTAssertTrue(CanvasHighlight.resolve(subject: .piece("p1"), in: model.scene).nodes.contains(b),
                      "the new scrap is dimmed under the chapter it was made for")
        model.endGesture()
    }
}
