import AppKit
import SwiftUI
import XCTest
@testable import Maugham

/// The keys on the canvas itself — `CanvasKeyHandler.handleCanvasKey` — driven
/// WITHOUT a window, over boxed bindings as in `CanvasEditorKeyTests`. One test
/// per cell of the spec's §1 table (selection × key), then the refusals.
///
/// The delivery (which keys `CanvasEventNSView` hands to `onKey`, and when ⌘↩
/// is claimed) is `CanvasEventViewTests`'; the real-event net is
/// `CanvasViewMountingEditingTests`.
///
/// The scene, in content space:
///
///     A (scrap)  40,40 240×60      I (item)  400,40 180×120
///     C (scrap)  40,300 240×60     R (region) 700,600 300×200
///     L, a line from A to I (midpoint 325,85)
@MainActor
final class CanvasCanvasKeyTests: XCTestCase {

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
        let regionTitleEditingID = Box<CanvasRegionID?>(nil)
        let regionTitleDraft = Box<CanvasRegionTitleDraft?>(nil)
        let treeAsks = Box(0)
        /// Whether a visible binder answers ⇧Tab; the window hands nil if not.
        var treeAnswers = true

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

        var titles: CanvasRegionTitleEditing {
            CanvasRegionTitleEditing(model: model,
                                     editFocus: editFocus,
                                     regionTitleEditingID: regionTitleEditingID.binding,
                                     regionTitleDraft: regionTitleDraft.binding,
                                     editingNodeID: editingNodeID.binding,
                                     keyboardTicket: keyboardTicket.binding,
                                     revision: revision.binding)
        }

        var scrapFlow: CanvasScrapFlow {
            CanvasScrapFlow(model: model,
                            subject: subject,
                            layoutPass: layoutPass,
                            regionTitleEditing: titles,
                            editingNodeID: editingNodeID.binding,
                            caretIndex: caretIndex.binding,
                            lastKeystrokeAt: lastKeystrokeAt.binding,
                            straighten: straighten.binding)
        }

        var handler: CanvasKeyHandler {
            CanvasKeyHandler(model: model,
                             subject: subject,
                             highlight: CanvasHighlight.resolve(subject: subject, in: model.scene),
                             selectTheProjectRow: {},
                             returnKeyboardToTree: treeAnswers ? { treeAsks.value += 1 } : nil,
                             editFocus: editFocus,
                             layoutPass: layoutPass,
                             scrapFlow: scrapFlow,
                             regionTitleEditing: titles,
                             editingNodeID: editingNodeID.binding,
                             revision: revision.binding,
                             camera: camera.binding,
                             keyboardTicket: keyboardTicket.binding)
        }

        func key(_ key: CanvasKey, viewSize: CGSize = CGSize(width: 1200, height: 900)) -> Bool {
            handler.handleCanvasKey(key, viewSize: viewSize)
        }
    }

    private let a = CanvasNodeID("a1bc")
    private let c = CanvasNodeID("c1de")
    private let item = CanvasNodeID.item("r-9")
    private let r = CanvasRegionID("r1")
    private let l = CanvasLineID("l1")
    private let aWords = "the falls at night"
    private var root: URL!

    override func setUpWithError() throws {
        root = TestTemp.root.appendingPathComponent("canvas-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Attached, because a bare model has no snapshot to register a step from.
    private func emptyModel(at projectRoot: URL? = nil) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: projectRoot ?? root)
        addTeardownBlock { @MainActor in model.detach() }
        return model
    }

    private func populate(_ model: CanvasModel) {
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: a, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240, cachedHeight: 60))
            $0.insert(CanvasNode(id: c, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 300), width: 240, cachedHeight: 60))
            $0.insert(CanvasNode(id: item, kind: .item(.project(id: "r-9")),
                                 origin: CGPoint(x: 400, y: 40), width: 180, cachedHeight: 120))
            $0.insertRegion(CanvasRegion(id: r, label: "Fog",
                                         frame: CGRect(x: 700, y: 600, width: 300, height: 200)))
            $0.insertLine(CanvasLine(id: l, from: a, to: item))
        }
        model.setScrapText(aWords, for: a)
        model.setScrapText("below", for: c)
    }

    private func populatedModel() -> CanvasModel {
        let model = emptyModel()
        populate(model)
        return model
    }

    /// A canvas whose layout file this build refused (issue #44), in a project
    /// of its own so a test can make several.
    private func readOnlyModel() throws -> CanvasModel {
        let project = root.appendingPathComponent(UUID().uuidString)
        let sidecar = project.appendingPathComponent(CanvasStore.sidecarRelativePath)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "not json at all".write(to: sidecar, atomically: true, encoding: .utf8)
        let model = emptyModel(at: project)
        XCTAssertTrue(model.isReadOnly, "precondition: the damaged layout file was refused")
        populate(model)
        return model
    }

    private func ids(_ model: CanvasModel) -> Set<CanvasNodeID> {
        Set(model.scene.unorderedNodes.map(\.id))
    }

    private func frame(_ id: CanvasNodeID, in model: CanvasModel) throws -> CGRect {
        try XCTUnwrap(model.scene.node(id)?.frame, "\(id) has no frame")
    }

    private func fixture(_ model: CanvasModel, selecting selection: CanvasSelection?) -> Fixture {
        model.selection = selection
        return Fixture(model: model)
    }

    /// Nothing happened: no card made, nothing entered, the selection where it was.
    private func assertUntouched(_ fixture: Fixture, before: Set<CanvasNodeID>,
                                 selection: CanvasSelection?,
                                 _ message: String, line: UInt = #line) {
        XCTAssertEqual(ids(fixture.model), before, "a card was made: \(message)", line: line)
        XCTAssertNil(fixture.editingNodeID.value, "a scrap was entered: \(message)", line: line)
        XCTAssertEqual(fixture.model.selection, selection, "the selection moved: \(message)", line: line)
        XCTAssertFalse(fixture.model.isInGesture, "a gesture was left open: \(message)", line: line)
    }

    // MARK: - Nothing selected

    func test_none_return() throws {
        let model = emptyModel()
        let f = fixture(model, selecting: nil)
        let viewSize = CGSize(width: 1000, height: 700)

        XCTAssertTrue(f.key(.returnKey, viewSize: viewSize))

        let made = try XCTUnwrap(f.editingNodeID.value, "Return on an empty canvas entered no scrap")
        XCTAssertEqual(ids(model), [made])
        let size = CanvasKeyboard.newCardSize()
        let centre = CanvasCamera().contentPoint(fromView: CGPoint(x: 500, y: 350))
        XCTAssertEqual(try XCTUnwrap(model.scene.node(made)).origin,
                       CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2),
                       "the new scrap is not centred in the view")
        XCTAssertTrue(model.isInGesture, "\"Edit Scrap\" is not open on the new scrap")
        model.endGesture()
    }

    /// Under a camera that is panned AND zoomed, so the view's centre is a
    /// different content point from the identity camera's.
    func test_returnOnAnEmptyCanvasMakesAScrapAtTheViewCentreClearOfCards() throws {
        let model = populatedModel()
        var camera = CanvasCamera()
        camera.panBy(CGSize(width: 300, height: -150))
        camera.zoom(to: 1.5, anchoringViewPoint: CGPoint(x: 100, y: 80))
        XCTAssertNotEqual(camera.zoom, 1, "premise: the camera is zoomed")
        XCTAssertNotEqual(camera.pan, .zero, "premise: the camera is panned")
        let viewSize = CGSize(width: 1200, height: 700)
        let centre = camera.contentPoint(fromView: CGPoint(x: 600, y: 350))
        XCTAssertNotEqual(centre, CanvasCamera().contentPoint(fromView: CGPoint(x: 600, y: 350)),
                          "premise: this camera's centre differs from the identity camera's")
        // A card squarely at the view's centre, so the placement has to step.
        let blocker = CanvasNodeID("b1oc")
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: blocker, kind: .scrap,
                                 origin: CGPoint(x: centre.x - 120, y: centre.y - 30),
                                 width: 240, cachedHeight: 60))
        }
        let f = fixture(model, selecting: nil)
        f.camera.value = camera
        let before = ids(model)

        XCTAssertTrue(f.key(.returnKey, viewSize: viewSize))

        let made = try XCTUnwrap(ids(model).subtracting(before).first, "Return made no scrap")
        let madeFrame = try frame(made, in: model)
        XCTAssertEqual(madeFrame.minX, centre.x - CanvasKeyboard.newCardSize().width / 2,
                       accuracy: 0.001,
                       "the scrap left the view's centre column instead of stepping down")
        XCTAssertGreaterThan(madeFrame.minY, try frame(blocker, in: model).maxY,
                             "the placement did not step down past the card in the way")
        for other in before {
            XCTAssertFalse(madeFrame.intersects(try frame(other, in: model)),
                           "the new scrap lands on top of \(other)")
        }
        XCTAssertEqual(f.editingNodeID.value, made)
        model.endGesture()
    }

    /// A selected card that is gone, or hidden by a collapsed region, is no
    /// selection: Return makes a scrap at the view's centre, and an arrow
    /// travels on.
    func test_aStaleOrHiddenSelectionIsNoSelection() throws {
        let gone = CanvasNodeID("g1ne")
        let hidden = CanvasNodeID("h1dn")
        for (selected, hide) in [(gone, false), (hidden, true)] {
            let model = emptyModel(at: root.appendingPathComponent(UUID().uuidString))
            if hide {
                model.withScene(persist: false) {
                    $0.insert(CanvasNode(id: hidden, kind: .scrap,
                                         origin: CGPoint(x: 2000, y: 2000), width: 240, cachedHeight: 60))
                    $0.insertRegion(CanvasRegion(id: r, label: "Folded",
                                                 frame: CGRect(x: 1900, y: 1900, width: 500, height: 300),
                                                 homeMembers: [hidden], isCollapsed: true))
                }
                XCTAssertTrue(model.scene.isHidden(hidden), "premise: the collapse hides the card")
            }
            let f = fixture(model, selecting: .node(selected))
            let before = ids(model)

            XCTAssertFalse(f.key(.arrow(.right)), "an arrow from \(selected) did not travel on")
            XCTAssertEqual(model.selection, .node(selected), "the arrow moved the selection")

            XCTAssertTrue(f.key(.returnKey, viewSize: CGSize(width: 1000, height: 700)))
            let made = try XCTUnwrap(ids(model).subtracting(before).first,
                                     "Return with \(selected) selected made no scrap")
            let centre = CanvasCamera().contentPoint(fromView: CGPoint(x: 500, y: 350))
            let size = CanvasKeyboard.newCardSize()
            XCTAssertEqual(try XCTUnwrap(model.scene.node(made)).origin,
                           CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2),
                           "the scrap is not at the view's centre")
            XCTAssertEqual(f.editingNodeID.value, made)
            XCTAssertNotEqual(f.editingNodeID.value, selected, "the hidden card was entered")
            model.endGesture()
        }
    }

    func test_none_tab() {
        let model = populatedModel()
        let f = fixture(model, selecting: nil)
        let before = ids(model)
        XCTAssertFalse(f.key(.tab), "Tab with nothing selected must travel on (the key-view loop)")
        assertUntouched(f, before: before, selection: nil, "Tab with nothing selected")
    }

    func test_none_commandReturn() {
        let model = populatedModel()
        let f = fixture(model, selecting: nil)
        let before = ids(model)
        XCTAssertFalse(f.key(.commandReturn))
        assertUntouched(f, before: before, selection: nil, "⌘Return with nothing selected")
    }

    func test_none_arrows() {
        let model = populatedModel()
        let f = fixture(model, selecting: nil)
        let before = ids(model)
        for arrow in [CanvasArrow.up, .down, .left, .right] {
            XCTAssertFalse(f.key(.arrow(arrow)), "\(arrow) with nothing selected must travel on")
        }
        assertUntouched(f, before: before, selection: nil, "an arrow with nothing selected")
    }

    // MARK: - A scrap

    func test_scrap_return() {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(a))
        let before = ids(model)

        XCTAssertTrue(f.key(.returnKey))

        XCTAssertEqual(f.editingNodeID.value, a, "Return on a selected scrap did not enter it")
        XCTAssertEqual(f.caretIndex.value, (aWords as NSString).length,
                       "the caret is not at the end of the scrap's words")
        XCTAssertEqual(ids(model), before, "Return on a selected scrap made a card")
        XCTAssertTrue(model.isInGesture, "\"Edit Scrap\" is not open")
        model.endGesture()
    }

    func test_scrap_tab() throws {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(a))
        let before = ids(model)

        XCTAssertTrue(f.key(.tab))

        let made = try XCTUnwrap(ids(model).subtracting(before).first, "Tab made no scrap")
        let aFrame = try frame(a, in: model), madeFrame = try frame(made, in: model)
        XCTAssertGreaterThan(madeFrame.minX, aFrame.maxX, "the joined scrap is not to the right of A")
        for other in before {
            XCTAssertFalse(madeFrame.intersects(try frame(other, in: model)),
                           "the new scrap lands on top of \(other)")
        }
        XCTAssertTrue(model.scene.lines.contains { Set([$0.from, $0.to]) == Set([a, made]) },
                      "no line joins A and the new scrap")
        XCTAssertEqual(f.editingNodeID.value, made, "the new scrap was not entered")
        model.endGesture()
    }

    func test_scrap_commandReturn() throws {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(a))
        let before = ids(model)
        let lines = model.scene.lineCount

        XCTAssertTrue(f.key(.commandReturn))

        let made = try XCTUnwrap(ids(model).subtracting(before).first, "⌘Return made no scrap")
        let aFrame = try frame(a, in: model), madeFrame = try frame(made, in: model)
        XCTAssertEqual(madeFrame.minX, aFrame.minX, "the scrap below is not aligned under A")
        XCTAssertGreaterThan(madeFrame.minY, aFrame.maxY)
        for other in before {
            XCTAssertFalse(madeFrame.intersects(try frame(other, in: model)),
                           "the new scrap lands on top of \(other)")
        }
        XCTAssertEqual(model.scene.lineCount, lines, "⌘Return drew a line")
        XCTAssertEqual(f.editingNodeID.value, made)
        model.endGesture()
    }

    func test_scrap_arrows() {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(a))

        XCTAssertTrue(f.key(.arrow(.right)))
        XCTAssertEqual(model.selection, .node(item), "→ from A did not reach the item card")
        XCTAssertTrue(f.key(.arrow(.left)))
        XCTAssertEqual(model.selection, .node(a), "← from the item card did not come back to A")
        let revision = f.revision.value
        XCTAssertTrue(f.key(.arrow(.down)))
        XCTAssertEqual(model.selection, .node(c), "↓ from A did not reach C")
        XCTAssertGreaterThan(f.revision.value, revision, "the selection moved and nothing redraws")
        XCTAssertNil(f.editingNodeID.value, "an arrow entered a scrap")
        XCTAssertFalse(model.isInGesture)
    }

    /// The arrow brings its target into view, as a make does.
    func test_anArrowRevealsACardOffScreen() throws {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(a))
        let viewSize = CGSize(width: 300, height: 200)

        XCTAssertTrue(f.key(.arrow(.right), viewSize: viewSize))

        let target = try frame(item, in: model)
        let corner = f.camera.value.viewPoint(fromContent: CGPoint(x: target.maxX, y: target.maxY))
        XCTAssertLessThanOrEqual(corner.x, viewSize.width, "the selected card is off the right of the view")
        XCTAssertNotEqual(f.camera.value, CanvasCamera(), "control: the camera moved at all")
    }

    func test_anArrowWithNoCardThatWayIsSwallowedAndChangesNothing() {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(a))
        let before = ids(model)
        let revision = f.revision.value

        XCTAssertTrue(f.key(.arrow(.up)), "an arrow with a selection must not beep")
        XCTAssertTrue(f.key(.arrow(.left)))

        assertUntouched(f, before: before, selection: .node(a), "an arrow into nothing")
        XCTAssertEqual(f.camera.value, CanvasCamera(), "an arrow into nothing moved the camera")
        XCTAssertEqual(f.revision.value, revision)
    }

    // MARK: - An item card

    func test_itemCard_return() {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(item))
        let before = ids(model)
        XCTAssertTrue(f.key(.returnKey), "Return on an item card is used, so it does not beep")
        assertUntouched(f, before: before, selection: .node(item), "Return on an item card")
    }

    func test_itemCard_tab() throws {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(item))
        let before = ids(model)

        XCTAssertTrue(f.key(.tab))

        let made = try XCTUnwrap(ids(model).subtracting(before).first, "Tab made no scrap")
        XCTAssertGreaterThan(try frame(made, in: model).minX, try frame(item, in: model).maxX)
        XCTAssertTrue(model.scene.lines.contains { Set([$0.from, $0.to]) == Set([item, made]) },
                      "no line joins the item card and the new scrap")
        XCTAssertEqual(f.editingNodeID.value, made)
        model.endGesture()
    }

    func test_itemCard_commandReturn() throws {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(item))
        let before = ids(model)
        let lines = model.scene.lineCount

        XCTAssertTrue(f.key(.commandReturn))

        let made = try XCTUnwrap(ids(model).subtracting(before).first, "⌘Return made no scrap")
        XCTAssertEqual(try frame(made, in: model).minX, try frame(item, in: model).minX)
        XCTAssertGreaterThan(try frame(made, in: model).minY, try frame(item, in: model).maxY)
        XCTAssertEqual(model.scene.lineCount, lines, "⌘Return drew a line")
        XCTAssertEqual(f.editingNodeID.value, made)
        model.endGesture()
    }

    func test_itemCard_arrows() {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(item))
        XCTAssertTrue(f.key(.arrow(.left)))
        XCTAssertEqual(model.selection, .node(a), "← from the item card did not reach A")
    }

    // MARK: - A region

    /// Return opens the region's title for typing (spec §3); it makes and
    /// enters nothing. `RegionTitleEditingTests` has what typing does.
    func test_region_return() {
        let model = populatedModel()
        let f = fixture(model, selecting: .region(r))
        let before = ids(model)
        XCTAssertTrue(f.key(.returnKey))
        XCTAssertEqual(f.regionTitleEditingID.value, r, "Return on a region did not open its title")
        assertUntouched(f, before: before, selection: .region(r), "Return on a region")
    }

    func test_region_tab() {
        let model = populatedModel()
        let f = fixture(model, selecting: .region(r))
        let before = ids(model)
        XCTAssertTrue(f.key(.tab), "used, so it neither beeps nor travels to an inspector field")
        assertUntouched(f, before: before, selection: .region(r), "Tab on a region")
    }

    func test_region_commandReturn() {
        let model = populatedModel()
        let f = fixture(model, selecting: .region(r))
        let before = ids(model)
        XCTAssertTrue(f.key(.commandReturn), "used, so it neither beeps nor travels to an inspector field")
        assertUntouched(f, before: before, selection: .region(r), "⌘Return on a region")
    }

    /// Measured from the region's centre (850, 700): up reaches the item card,
    /// left reaches C.
    func test_region_arrows() {
        let model = populatedModel()
        let f = fixture(model, selecting: .region(r))
        XCTAssertTrue(f.key(.arrow(.up)))
        XCTAssertEqual(model.selection, .node(item), "↑ from the region did not reach the item card")
        model.selection = .region(r)
        XCTAssertTrue(f.key(.arrow(.left)))
        XCTAssertEqual(model.selection, .node(c), "← from the region did not reach C")
        model.selection = .region(r)
        XCTAssertTrue(f.key(.arrow(.right)), "an arrow into nothing is swallowed")
        XCTAssertEqual(model.selection, .region(r))
    }

    // MARK: - A line

    func test_line_return() {
        let model = populatedModel()
        let f = fixture(model, selecting: .line(l))
        let before = ids(model)
        XCTAssertTrue(f.key(.returnKey), "Return on a line is used, so it does not beep")
        assertUntouched(f, before: before, selection: .line(l), "Return on a line")
    }

    func test_line_tab() {
        let model = populatedModel()
        let f = fixture(model, selecting: .line(l))
        let before = ids(model)
        XCTAssertTrue(f.key(.tab), "used, so it neither beeps nor travels to an inspector field")
        assertUntouched(f, before: before, selection: .line(l), "Tab on a line")
    }

    func test_line_commandReturn() {
        let model = populatedModel()
        let f = fixture(model, selecting: .line(l))
        let before = ids(model)
        XCTAssertTrue(f.key(.commandReturn), "used, so it neither beeps nor travels to an inspector field")
        assertUntouched(f, before: before, selection: .line(l), "⌘Return on a line")
    }

    /// Measured from the line's midpoint (325, 85): ← reaches A, → the item
    /// card, ↓ reaches C.
    func test_line_arrows() {
        let model = populatedModel()
        let f = fixture(model, selecting: .line(l))
        XCTAssertTrue(f.key(.arrow(.left)))
        XCTAssertEqual(model.selection, .node(a))
        model.selection = .line(l)
        XCTAssertTrue(f.key(.arrow(.right)))
        XCTAssertEqual(model.selection, .node(item))
        model.selection = .line(l)
        XCTAssertTrue(f.key(.arrow(.down)))
        XCTAssertEqual(model.selection, .node(c))
    }

    // MARK: - Refusals

    /// A key pressed mid-drag is refused like ⌫ (tripwire 32), and it must
    /// leave the writer's gesture OPEN: the fold (`commitActiveEdit`) ends
    /// whatever gesture is open, so asked first it would close "Move Card"
    /// under the writer's hand.
    func test_everyCanvasKeyIsRefusedMidGesture() {
        let keys: [CanvasKey] = [.returnKey, .tab, .backtab, .commandReturn,
                                 .arrow(.up), .arrow(.down), .arrow(.left), .arrow(.right)]
        let selections: [CanvasSelection?] = [nil, .node(a), .node(item), .region(r), .line(l)]
        for selection in selections {
            let model = populatedModel()
            let f = fixture(model, selecting: selection)
            model.beginGesture("Move Card")
            let before = ids(model)
            let lines = model.scene.lineCount
            for key in keys {
                XCTAssertFalse(f.key(key), "\(key) on \(String(describing: selection)) mid-gesture")
                XCTAssertTrue(model.isInGesture,
                              "\(key) closed the open gesture under the writer's hand")
            }
            XCTAssertEqual(ids(model), before, "a key made a card mid-gesture")
            XCTAssertEqual(model.scene.lineCount, lines)
            XCTAssertEqual(model.selection, selection, "a key moved the selection mid-gesture")
            XCTAssertNil(f.editingNodeID.value)
            XCTAssertEqual(f.camera.value, CanvasCamera())
            XCTAssertEqual(f.treeAsks.value, 0, "⇧Tab asked for the binder mid-gesture")
            model.endGesture()
            XCTAssertFalse(model.isInGesture, "the gesture was nested into, not left alone")
        }
    }

    /// While a scrap is open the canvas has no keys — they are the editor's.
    func test_everyCanvasKeyIsRefusedWithAScrapOpen() {
        let model = populatedModel()
        let f = fixture(model, selecting: .node(a))
        f.editingNodeID.value = a
        let before = ids(model)
        for key in [CanvasKey.returnKey, .tab, .backtab, .commandReturn, .arrow(.down)] {
            XCTAssertFalse(f.key(key), "\(key) with a scrap open")
        }
        XCTAssertEqual(ids(model), before)
        XCTAssertEqual(model.selection, .node(a))
        XCTAssertEqual(f.treeAsks.value, 0, "⇧Tab asked for the binder with a scrap open")
    }

    // MARK: - ⇧Tab, back to the binder

    /// With no visible binder to answer (nil), ⇧Tab is not used and travels on.
    func test_backtabWithNoBinderToAnswerTravelsOn() {
        let model = populatedModel()
        var f = fixture(model, selecting: .node(a))
        f.treeAnswers = false
        let before = ids(model)
        XCTAssertFalse(f.key(.backtab), "⇧Tab was claimed with no binder to answer it")
        assertUntouched(f, before: before, selection: .node(a), "⇧Tab with no binder")
    }

    /// ⇧Tab asks the window for the binder once, whatever is selected, and
    /// changes nothing on the board. It creates nothing, so read-only does
    /// not refuse it.
    func test_backtabAsksForTheBinderAndTouchesNothing() throws {
        let selections: [CanvasSelection?] = [nil, .node(a), .node(item), .region(r), .line(l)]
        for readOnly in [false, true] {
            for selection in selections {
                let model = readOnly ? try readOnlyModel() : populatedModel()
                let f = fixture(model, selecting: selection)
                let before = ids(model)
                let label = "⇧Tab on \(String(describing: selection))\(readOnly ? " read-only" : "")"
                XCTAssertTrue(f.key(.backtab), label)
                XCTAssertEqual(f.treeAsks.value, 1, label)
                assertUntouched(f, before: before, selection: selection, label)
            }
        }
    }

    func test_everyCreatingKeyIsRefusedReadOnly() throws {
        let cases: [(CanvasSelection?, CanvasKey)] = [
            (nil, .returnKey),
            (.node(a), .returnKey),
            (.node(a), .tab), (.node(a), .commandReturn),
            (.node(item), .tab), (.node(item), .commandReturn),
        ]
        for (selection, key) in cases {
            let model = try readOnlyModel()
            let f = fixture(model, selecting: selection)
            let before = ids(model)
            XCTAssertFalse(f.key(key), "\(key) on \(String(describing: selection)) read-only")
            assertUntouched(f, before: before, selection: selection,
                            "\(key) on \(String(describing: selection)) read-only")
        }
    }

    func test_arrowsStillSelectReadOnly() throws {
        let model = try readOnlyModel()
        let f = fixture(model, selecting: .node(a))
        XCTAssertTrue(f.key(.arrow(.right)))
        XCTAssertEqual(model.selection, .node(item), "read-only is not frozen: arrows still select")
    }

    // MARK: - A dimmed leftover selection (whole-branch review)

    private let s2 = CanvasNodeID("x2yz")

    /// A board with the writer's chapter p1 selected and a leftover selection
    /// on X, a scrap bound to p2 — dimmed under p1.
    private func dimmedLeftover(boundTo piece: String = "p2") -> Fixture {
        let model = populatedModel()
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: s2, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 500), width: 240, cachedHeight: 60))
            $0.setBoundPiece(piece, for: s2)
        }
        model.setScrapText("chapter two's", for: s2)
        var f = fixture(model, selecting: .node(s2))
        f.subject = .piece("p1")
        return f
    }

    /// Return with a DIMMED card selected is Return with nothing selected: a
    /// new scrap at the view's centre, the chapter's, and X untouched.
    func test_returnOnADimmedSelectionMakesANewScrapForTheChapter() throws {
        let f = dimmedLeftover()
        let model = f.model
        XCTAssertTrue(f.handler.highlight.isDimmed(node: s2), "premise: X is dimmed under p1")
        let before = ids(model)

        XCTAssertTrue(f.key(.returnKey, viewSize: CGSize(width: 1000, height: 700)))

        let made = try XCTUnwrap(ids(model).subtracting(before).first,
                                 "Return on a dimmed card made no new scrap")
        XCTAssertEqual(f.editingNodeID.value, made, "Return entered the dimmed card")
        XCTAssertEqual(try XCTUnwrap(model.scene.node(made)).boundPieceID, "p1")
        XCTAssertEqual(model.scraps[s2], "chapter two's", "X's words changed")
        model.endGesture()
    }

    /// Control: a LIT scrap under the same chapter is entered by Return.
    func test_returnOnALitScrapStillEntersIt() {
        let f = dimmedLeftover(boundTo: "p1")
        XCTAssertFalse(f.handler.highlight.isDimmed(node: s2), "premise: X is lit under p1")
        let before = ids(f.model)

        XCTAssertTrue(f.key(.returnKey))

        XCTAssertEqual(f.editingNodeID.value, s2, "Return on a lit scrap did not enter it")
        XCTAssertEqual(ids(f.model), before)
        f.model.endGesture()
    }

    /// Tab and ⌘Return from a dimmed card act as with nothing selected: no
    /// scrap, and the key travels on. The arrows still move from it.
    func test_tabAndCommandReturnIgnoreADimmedSelectionButTheArrowsMoveFromIt() {
        let f = dimmedLeftover()
        let before = ids(f.model)
        XCTAssertFalse(f.key(.tab), "Tab from a dimmed card did not act as no selection")
        XCTAssertFalse(f.key(.commandReturn))
        assertUntouched(f, before: before, selection: .node(s2), "Tab/⌘Return from a dimmed card")

        XCTAssertTrue(f.key(.arrow(.up)))
        XCTAssertEqual(f.model.selection, .node(c), "↑ from the dimmed card did not reach C")
    }

    // MARK: - A region bound elsewhere (whole-branch review)

    /// A chapter-p1 board with a region bound to p2 at `frame`.
    private func boardWithForeignRegion(_ frame: CGRect, boundTo piece: String? = "p2")
        -> (Fixture, CanvasRegionID) {
        let model = emptyModel()
        let region = CanvasRegionID("f1")
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: a, kind: .scrap,
                                 origin: CGPoint(x: 40, y: 40), width: 240, cachedHeight: 60))
            $0.setBoundPiece("p1", for: a)
            $0.insertRegion(CanvasRegion(id: region, label: "Elsewhere", frame: frame,
                                         boundPieceID: piece))
        }
        model.setScrapText(aWords, for: a)
        var f = fixture(model, selecting: nil)
        f.subject = .piece("p1")
        return (f, region)
    }

    func test_tabBesideARegionBoundElsewhereKeepsOutOfIt() throws {
        let (f, foreign) = boardWithForeignRegion(CGRect(x: 290, y: 0, width: 400, height: 300))
        f.model.selection = .node(a)
        let before = ids(f.model)

        XCTAssertTrue(f.key(.tab))

        let made = try XCTUnwrap(ids(f.model).subtracting(before).first, "Tab made no scrap")
        let region = try XCTUnwrap(f.model.scene.region(foreign))
        XCTAssertFalse(region.mentions(made), "the new scrap joined the other chapter's region")
        XCTAssertFalse(try frame(made, in: f.model).intersects(region.frame))
        XCTAssertEqual(try XCTUnwrap(f.model.scene.node(made)).boundPieceID, "p1",
                       "the new scrap is not the selected chapter's")
        f.model.endGesture()
    }

    func test_centreReturnKeepsOutOfARegionBoundElsewhere() throws {
        let viewSize = CGSize(width: 1000, height: 700)
        let centre = CanvasCamera().contentPoint(fromView: CGPoint(x: 500, y: 350))
        let (f, foreign) = boardWithForeignRegion(
            CGRect(x: centre.x - 300, y: centre.y - 200, width: 600, height: 400))
        let before = ids(f.model)

        XCTAssertTrue(f.key(.returnKey, viewSize: viewSize))

        let made = try XCTUnwrap(ids(f.model).subtracting(before).first, "Return made no scrap")
        let region = try XCTUnwrap(f.model.scene.region(foreign))
        XCTAssertFalse(region.mentions(made), "the new scrap joined the other chapter's region")
        XCTAssertFalse(try frame(made, in: f.model).intersects(region.frame))
        XCTAssertEqual(try XCTUnwrap(f.model.scene.node(made)).boundPieceID, "p1")
        f.model.endGesture()
    }

    /// An unbound region and the chapter's own are no obstacle: Return makes
    /// the scrap right at the centre, inside them. Unbound, the scrap carries
    /// the chapter itself; in the chapter's region it follows the region.
    func test_unboundAndSameChapterRegionsStillTakeANewScrap() throws {
        let viewSize = CGSize(width: 1000, height: 700)
        let centre = CanvasCamera().contentPoint(fromView: CGPoint(x: 500, y: 350))
        let size = CanvasKeyboard.newCardSize()
        for (piece, binding) in [(nil, "p1"), ("p1", nil)] as [(String?, String?)] {
            let (f, home) = boardWithForeignRegion(
                CGRect(x: centre.x - 300, y: centre.y - 200, width: 600, height: 400), boundTo: piece)
            let before = ids(f.model)

            XCTAssertTrue(f.key(.returnKey, viewSize: viewSize))

            let made = try XCTUnwrap(ids(f.model).subtracting(before).first)
            XCTAssertEqual(try XCTUnwrap(f.model.scene.node(made)).origin,
                           CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2),
                           "a region bound to \(String(describing: piece)) pushed the scrap away")
            XCTAssertTrue(try XCTUnwrap(f.model.scene.region(home)).livesHere(made),
                          "the new scrap is not the region's")
            XCTAssertEqual(try XCTUnwrap(f.model.scene.node(made)).boundPieceID, binding)
            f.model.endGesture()
        }
    }

    // MARK: - A wrap region's edge (whole-branch review)

    /// Tab and ⌘Return from a card inside a region padded wider than the card
    /// gap: the new scrap is wholly inside or wholly outside, never across
    /// the edge — and inside where it fits.
    func test_tabAndCommandReturnNeverStraddleTheSourcesHomeRegion() throws {
        let pad = CanvasClaudePlacement.padding
        let tight = CGRect(x: 40, y: 40, width: 240, height: 60).insetBy(dx: -pad, dy: -pad)
        let roomy = CGRect(x: 24, y: 24, width: 800, height: 600)
        for (regionFrame, key) in [(tight, CanvasKey.tab), (tight, .commandReturn),
                                   (roomy, .tab), (roomy, .commandReturn)] {
            let model = emptyModel(at: root.appendingPathComponent(UUID().uuidString))
            let home = CanvasRegionID("w1")
            model.withScene(persist: false) {
                $0.insert(CanvasNode(id: a, kind: .scrap,
                                     origin: CGPoint(x: 40, y: 40), width: 240, cachedHeight: 60))
                $0.insertRegion(CanvasRegion(id: home, label: "", frame: regionFrame,
                                             homeMembers: [a]))
            }
            model.setScrapText(aWords, for: a)
            let f = fixture(model, selecting: .node(a))
            let before = ids(model)

            XCTAssertTrue(f.key(key))

            let made = try XCTUnwrap(ids(model).subtracting(before).first)
            let madeFrame = try frame(made, in: model)
            let label = "\(key) in a \(regionFrame == tight ? "tight" : "roomy") region"
            XCTAssertTrue(regionFrame.contains(madeFrame) || !regionFrame.intersects(madeFrame),
                          "\(label): \(madeFrame) straddles \(regionFrame)")
            if regionFrame == roomy {
                XCTAssertTrue(regionFrame.contains(madeFrame), "\(label): it fit, and was put outside")
                XCTAssertTrue(try XCTUnwrap(model.scene.region(home)).livesHere(made), label)
            }
            model.endGesture()
        }
    }
}
