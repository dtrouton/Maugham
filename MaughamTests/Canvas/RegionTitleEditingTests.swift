import AppKit
import SwiftUI
import XCTest
@testable import Maugham

/// A region's name typed on the canvas (spec §3), driven WITHOUT a window over
/// boxed bindings, as `CanvasCanvasKeyTests` drives the keys. When the title
/// opens (a sweep, a wrapped drop, Return, a double click on it), what Return,
/// Escape and a click elsewhere do with what was typed, and the one editor
/// slot it shares with a scrap.
///
/// The real field, keys and focus are `CanvasViewMountingRegionTests`'
/// (`test_typingANameAfterASweepAndPressingReturnNamesIt`,
/// `test_escapeWhileNamingOnADimmedBoardKeepsTheDim`).
@MainActor
final class RegionTitleEditingTests: XCTestCase {

    /// A value the test owns, handed to a helper as a `Binding` — the stand-in
    /// for the view's `@State`.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
        var binding: Binding<Value> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    /// Every helper `CanvasView` builds, over one set of boxes — so a click, a
    /// key, a drag and a drop all see the same title state, as they do on
    /// the view.
    @MainActor
    private struct Fixture {
        let model: CanvasModel
        var subject: CanvasSubject = .wholeProject
        var itemIndex: CanvasItemIndex = .empty
        var captureDrop: CanvasCaptureDrop = .unavailable
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
        let titleID = Box<CanvasRegionID?>(nil)
        let titleDraft = Box<CanvasRegionTitleDraft?>(nil)
        let interaction = Box(CanvasInteraction())
        let momentum = Box(CanvasMomentum())
        let selectionWhenPressed = Box<CanvasSelection?>(nil)
        let dropError = Box<String?>(nil)

        var layoutPass: CanvasLayoutPass {
            CanvasLayoutPass(model: model, itemIndex: model.itemIndex,
                             projectRoot: URL(fileURLWithPath: "/nonexistent"),
                             thumbnails: thumbnails.binding, layouts: layouts.binding,
                             itemPresentation: itemPresentation.binding,
                             thumbnailServiceTicket: thumbnailTicket.binding,
                             revision: revision.binding)
        }

        var editFocus: CanvasEditFocus {
            CanvasEditFocus(model: model, editingNodeID: editingNodeID.binding,
                            caretIndex: caretIndex.binding, straighten: straighten.binding,
                            lastKeystrokeAt: lastKeystrokeAt.binding, layouts: layouts.binding,
                            revision: revision.binding)
        }

        var titles: CanvasRegionTitleEditing {
            CanvasRegionTitleEditing(model: model, editFocus: editFocus,
                                     regionTitleEditingID: titleID.binding,
                                     regionTitleDraft: titleDraft.binding,
                                     editingNodeID: editingNodeID.binding,
                                     keyboardTicket: keyboardTicket.binding,
                                     revision: revision.binding)
        }

        var scrapFlow: CanvasScrapFlow {
            CanvasScrapFlow(model: model, subject: subject, layoutPass: layoutPass,
                            regionTitleEditing: titles,
                            editingNodeID: editingNodeID.binding, caretIndex: caretIndex.binding,
                            lastKeystrokeAt: lastKeystrokeAt.binding, straighten: straighten.binding)
        }

        var clicks: CanvasClickHandler {
            CanvasClickHandler(model: model, editFocus: editFocus, scrapFlow: scrapFlow,
                               regionTitleEditing: titles,
                               selectionWhenPressed: selectionWhenPressed.binding,
                               straighten: straighten.binding, layouts: layouts.binding,
                               revision: revision.binding)
        }

        var keys: CanvasKeyHandler {
            CanvasKeyHandler(model: model, subject: subject, selectTheProjectRow: {},
                             returnKeyboardToTree: nil, editFocus: editFocus,
                             layoutPass: layoutPass, scrapFlow: scrapFlow,
                             regionTitleEditing: titles,
                             editingNodeID: editingNodeID.binding, revision: revision.binding,
                             camera: camera.binding, keyboardTicket: keyboardTicket.binding)
        }

        var drags: CanvasDragHandler {
            CanvasDragHandler(model: model, subject: subject, layoutPass: layoutPass,
                              regionTitleEditing: titles,
                              interaction: interaction.binding, momentum: momentum.binding,
                              revision: revision.binding, editingNodeID: editingNodeID.binding,
                              selectionWhenPressed: selectionWhenPressed.binding)
        }

        var drops: CanvasDropHandler {
            CanvasDropHandler(model: model, subject: subject, itemIndex: itemIndex,
                              projectRoot: URL(fileURLWithPath: "/nonexistent"),
                              captureDrop: captureDrop, assetIngest: .unavailable,
                              thumbnails: thumbnails.binding, camera: camera.binding,
                              revision: revision.binding, dropError: dropError.binding,
                              regionTitleEditingID: titleID.binding,
                              editingNodeID: editingNodeID.binding)
        }

        /// A sweep on bare canvas from `from` to `to`, the press, the drag and
        /// the release, as `CanvasEventNSView` delivers them.
        func sweep(from: CGPoint, to: CGPoint) {
            clicks.handleClick(at: from, clickCount: 1)
            drags.handleDrag(at: from, phase: .began, shiftHeld: false, timestamp: 0)
            drags.handleDrag(at: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2),
                             phase: .changed, shiftHeld: false, timestamp: 1.0 / 60)
            drags.handleDrag(at: to, phase: .changed, shiftHeld: false, timestamp: 2.0 / 60)
            // A pause at rest, so the release reports no flick.
            drags.handleDrag(at: to, phase: .changed, shiftHeld: false, timestamp: 1)
            drags.handleDrag(at: to, phase: .ended, shiftHeld: false, timestamp: 1.1)
        }

        /// The writer is inside `id` and has typed `typed`: the shared stack
        /// holds the words and the model does not yet.
        func enter(_ id: CanvasNodeID, typed: String) {
            layoutPass.rebuildLayouts()
            scrapFlow.enter(id, caretIndex: 0)
            layouts.value[id] = ScrapLayout(text: typed, width: 220,
                                            font: .systemFont(ofSize: 13))
        }
    }

    private let r = CanvasRegionID("r1")
    private let s = CanvasNodeID("s1ab")
    private let regionFrame = CGRect(x: 100, y: 100, width: 400, height: 300)
    /// On the region's bar, inside its title's double-click target.
    private var onTheTitle: CGPoint { CGPoint(x: 120, y: 112) }
    private var root: URL!

    override func setUpWithError() throws {
        root = TestTemp.root.appendingPathComponent("region-titles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Attached, so `CanvasUndo` records snapshots; `groupsByEvent` off, as
    /// the canvas's undo tests run it.
    private func attachedModel(at projectRoot: URL? = nil) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: projectRoot ?? root)
        model.undoManager.groupsByEvent = false
        addTeardownBlock { @MainActor in model.detach() }
        return model
    }

    /// A region "Fog" at `regionFrame`, and a measured scrap far from it.
    private func populatedModel() -> CanvasModel {
        let model = attachedModel()
        model.withScene(persist: false) {
            $0.insertRegion(CanvasRegion(id: r, label: "Fog", frame: regionFrame))
            $0.insert(CanvasNode(id: s, kind: .scrap, origin: CGPoint(x: 700, y: 600),
                                 width: 240, cachedHeight: 60))
        }
        model.setScrapText("already", for: s)
        return model
    }

    private func readOnlyModel() throws -> CanvasModel {
        let project = root.appendingPathComponent(UUID().uuidString)
        let sidecar = project.appendingPathComponent(CanvasStore.sidecarRelativePath)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "not json at all".write(to: sidecar, atomically: true, encoding: .utf8)
        let model = attachedModel(at: project)
        XCTAssertTrue(model.isReadOnly, "precondition: the damaged layout file was refused")
        model.withScene(persist: false) {
            $0.insertRegion(CanvasRegion(id: r, label: "Fog", frame: regionFrame))
        }
        return model
    }

    // MARK: - On creation

    /// The sweep's "New Region" closes, THEN the title opens: the step is still
    /// the region's, and naming has not nested inside it.
    func test_aSweptRegionOpensItsTitleAfterTheNewRegionStepCloses() throws {
        let model = attachedModel()
        let f = Fixture(model: model)

        f.sweep(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 340))

        let region = try XCTUnwrap(model.scene.regions.first, "the sweep made no region")
        XCTAssertEqual(f.titleID.value, region.id, "the new region's title did not open")
        XCTAssertFalse(model.isInGesture,
                       "a gesture is still open with the title: \"New Region\" never closed")
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo New Region",
                       "the sweep's step is not the last one, or it was renamed by the title")
    }

    /// A sweep that made nothing (too small) opens no title, and neither does a
    /// card move.
    func test_aSweepThatMadeNoRegionOpensNoTitle() {
        let model = attachedModel()
        let f = Fixture(model: model)
        f.sweep(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 130, y: 120))
        XCTAssertEqual(model.scene.regionCount, 0, "precondition: too small to mint")
        XCTAssertNil(f.titleID.value, "a sweep that made no region opened a title")
    }

    // MARK: - Return, Escape, a click elsewhere

    func test_returnCommitsAsRenameRegion() throws {
        let model = populatedModel()
        let f = Fixture(model: model)
        f.titles.begin(r)
        XCTAssertEqual(f.titleID.value, r, "precondition: the title opened")

        f.titles.noteTyping("Falls", in: r)
        f.titles.commit("Falls at night")

        XCTAssertEqual(model.scene.region(r)?.label, "Falls at night",
                       "Return commits what the field holds")
        XCTAssertNil(f.titleID.value, "Return left the title open")
        XCTAssertNil(f.titleDraft.value, "Return left a draft behind")
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo Rename Region")
        XCTAssertEqual(f.keyboardTicket.value, 1, "Return did not hand the keyboard to the canvas")
        XCTAssertFalse(model.isInGesture)

        model.undo.undo()
        XCTAssertEqual(model.scene.region(r)?.label, "Fog", "one ⌘Z takes the name back")
    }

    /// The name written as the inspector writes it: no trim, and no step when
    /// nothing changed.
    func test_returnWithTheNameUnchangedAddsNoStep() {
        let model = populatedModel()
        model.mutate("Unrelated") { $0.move(self.s, to: CGPoint(x: 710, y: 600)) }
        let f = Fixture(model: model)
        f.titles.begin(r)
        let structural = model.sceneRevision
        f.titles.commit("Fog")
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo Unrelated",
                       "an unchanged name registered a step")
        XCTAssertEqual(model.sceneRevision, structural,
                       "an unchanged name was written: the tree and the inspector rebuilt for nothing")
        XCTAssertNil(f.titleID.value, "control: Return closed the title all the same")

        f.titles.begin(r)
        f.titles.commit("  Fog ")
        XCTAssertEqual(model.scene.region(r)?.label, "  Fog ", "the name was trimmed")
    }

    /// Escape on a region just swept: no name, the region kept, no step of its
    /// own — one ⌘Z still takes back the region.
    func test_escapeLeavesTheRegionUntitledAndKeepsIt() throws {
        let model = attachedModel()
        let f = Fixture(model: model)
        f.sweep(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 340))
        let region = try XCTUnwrap(f.titleID.value, "precondition: the title opened")

        f.titles.noteTyping("Half a na", in: region)
        f.titles.cancel()

        XCTAssertNil(f.titleID.value, "Escape left the title open")
        XCTAssertEqual(model.scene.region(region)?.label, "", "Escape wrote what was typed")
        XCTAssertNotNil(model.scene.region(region), "Escape took the region away")
        XCTAssertEqual(f.keyboardTicket.value, 1, "Escape did not hand the keyboard to the canvas")
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo New Region",
                       "Escape added a step of its own")

        model.undo.undo()
        XCTAssertEqual(model.scene.regionCount, 0, "one ⌘Z did not take back the region")
    }

    /// After Escape the field resigns as it is torn down; that is not a lost
    /// focus, and nothing is written. Pinned on the field's delegate and on the
    /// helper, each with its control.
    func test_cancelThenResignDoesNotCommit() {
        let container = RegionTitleEditorContainer(frame: CGRect(x: 0, y: 0, width: 200, height: 18))
        var cancels = 0
        var lost: [String] = []
        container.onCancel = { cancels += 1; return true }
        container.onLostFocus = { lost.append($0); return true }
        container.bind(to: r, label: "Fog")
        container.field.stringValue = "typed"
        let editor = NSTextView()
        let note = Notification(name: NSControl.textDidEndEditingNotification, object: container.field)

        XCTAssertTrue(container.control(container.field, textView: editor,
                                        doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        container.controlTextDidEndEditing(note)
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(lost, [], "the resign after Escape reported a lost focus")

        // The control: a lost focus with no Escape before it does report.
        let other = RegionTitleEditorContainer(frame: .zero)
        var otherLost: [String] = []
        other.onLostFocus = { otherLost.append($0); return true }
        other.bind(to: r, label: "Fog")
        other.field.stringValue = "typed"
        other.controlTextDidEndEditing(note)
        XCTAssertEqual(otherLost, ["typed"])

        // The helper's half: a lost focus arriving after the cancel closed the
        // title writes nothing.
        let model = populatedModel()
        let f = Fixture(model: model)
        f.titles.begin(r)
        f.titles.cancel()
        f.titles.fieldLostFocus("typed", in: r)
        XCTAssertEqual(model.scene.region(r)?.label, "Fog", "a late lost focus wrote the name")
    }

    /// A click on the canvas while the title is open commits what was typed —
    /// at the click handler's HEAD, before the click does anything else — and
    /// leaves the keyboard alone.
    func test_clickElsewhereCommitsWhatWasTyped() {
        let model = populatedModel()
        let f = Fixture(model: model)
        f.titles.begin(r)
        f.titles.noteTyping("Falls at night", in: r)

        f.clicks.handleClick(at: CGPoint(x: 900, y: 900), clickCount: 1)

        XCTAssertEqual(model.scene.region(r)?.label, "Falls at night",
                       "the click lost what the writer typed")
        XCTAssertNil(f.titleID.value, "the click left the title open")
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo Rename Region")
        XCTAssertEqual(f.keyboardTicket.value, 0,
                       "a click elsewhere took the keyboard; it goes where the click went")
    }

    /// A draft typed into ANOTHER region's field is never written into this one.
    func test_aDraftForAnotherRegionIsNotWritten() {
        let model = populatedModel()
        let other = CanvasRegionID("r2")
        model.withScene(persist: false) {
            $0.insertRegion(CanvasRegion(id: other, label: "Weir",
                                         frame: CGRect(x: 600, y: 100, width: 200, height: 200)))
        }
        let f = Fixture(model: model)
        f.titles.begin(r)
        f.titles.noteTyping("Stale", in: other)
        f.titles.commitIfOpen()
        XCTAssertEqual(model.scene.region(r)?.label, "Fog")
        XCTAssertEqual(model.scene.region(other)?.label, "Weir")
        XCTAssertNil(f.titleID.value, "control: the title still closed")
    }

    // MARK: - One editor slot

    func test_beginClosesAnOpenScrapVisitWithItsWordsFolded() {
        let model = populatedModel()
        let f = Fixture(model: model)
        f.enter(s, typed: "the falls at night")
        XCTAssertTrue(model.isInGesture, "precondition: \"Edit Scrap\" is open")

        f.titles.begin(r)

        XCTAssertEqual(f.titleID.value, r, "the title did not open over an open scrap")
        XCTAssertNil(f.editingNodeID.value, "the scrap is still open beside the title")
        XCTAssertEqual(model.scraps[s], "the falls at night",
                       "the scrap's words were not folded in before it closed")
        XCTAssertFalse(model.isInGesture, "\"Edit Scrap\" was left open")
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo Edit Scrap")
    }

    func test_enteringAScrapCommitsAnOpenTitle() {
        let model = populatedModel()
        let f = Fixture(model: model)
        f.layoutPass.rebuildLayouts()
        f.titles.begin(r)
        f.titles.noteTyping("Falls", in: r)

        f.scrapFlow.enter(s, caretIndex: 0)

        XCTAssertEqual(model.scene.region(r)?.label, "Falls", "entering a scrap lost the name")
        XCTAssertNil(f.titleID.value, "the title is still open beside the scrap")
        XCTAssertEqual(f.editingNodeID.value, s)
        model.endGesture()
        XCTAssertEqual(model.undo.undoMenuItemTitle, "Undo Rename Region",
                       "the rename is not its own step before the visit")
    }

    // MARK: - The other ways in

    func test_aWrappedDropOpensItsTitleOnlyWithNoScrapOpen() throws {
        let noteID = "rn01"
        let index = CanvasItemIndex(entriesByID: [noteID: .init(title: "The falls", kind: .researchNote)])

        let model = attachedModel()
        var f = Fixture(model: model)
        f.subject = .piece("p1")
        f.itemIndex = index
        XCTAssertTrue(f.drops.handleDrop([noteID], at: CGPoint(x: 300, y: 300)))
        let region = try XCTUnwrap(model.scene.regions.first, "precondition: the drop was wrapped")
        XCTAssertEqual(f.titleID.value, region.id, "the wrap's title did not open")
        XCTAssertEqual(model.selection, .region(region.id), "the wrap's region is not selected")

        // A scrap open: the region is selected and its title stays shut.
        let busy = populatedModel()
        var g = Fixture(model: busy)
        g.subject = .piece("p1")
        g.itemIndex = index
        g.enter(s, typed: "already")
        XCTAssertTrue(g.drops.handleDrop([noteID], at: CGPoint(x: 1300, y: 1300)))
        let wrap = try XCTUnwrap(busy.scene.regions.first { $0.id != r }, "precondition: wrapped")
        XCTAssertNil(g.titleID.value, "a wrap opened a title while a scrap was open")
        XCTAssertEqual(busy.selection, wrap.homeMembers.first.map { .node($0) },
                       "with the title shut, the dropped card is selected, as before")
        XCTAssertEqual(wrap.homeMembers.count, 1, "precondition: the wrap holds the dropped card")
        XCTAssertEqual(g.editingNodeID.value, s, "the drop closed the writer's scrap")
    }

    /// The capture route opens the title from the region its send REPORTS —
    /// never one derived from where the card ended up, which for a capture that
    /// joined an existing region would be that region.
    func test_aWrappedCaptureOpensTheReportedRegionAndAJoinedOneOpensNothing() async throws {
        let model = populatedModel()
        let wrap = CanvasRegionID("w1")
        let card = s
        // The send's own writing is `InboxToCanvasTests`'; here the region it
        // reports is already in the scene.
        model.withScene(persist: false) {
            $0.insertRegion(CanvasRegion(id: wrap, label: "",
                                         frame: CGRect(x: 0, y: 900, width: 200, height: 200)))
        }
        var f = Fixture(model: model)
        f.subject = .piece("p1")
        f.captureDrop = CanvasCaptureDrop(send: { _, _, _ in
            CanvasCapture.Sent(node: card, wrappedIn: wrap)
        })
        XCTAssertTrue(f.drops.handleDrop(["inbox:c1"], at: CGPoint(x: 10, y: 910)))
        for _ in 0..<50 where f.titleID.value == nil { await Task.yield() }
        XCTAssertEqual(f.titleID.value, wrap, "the reported wrap's title did not open")

        // Joined the existing region `r`: nothing reported, nothing opens.
        var g = Fixture(model: model)
        g.subject = .piece("p1")
        g.captureDrop = CanvasCaptureDrop(send: { _, _, _ in
            CanvasCapture.Sent(node: card, wrappedIn: nil)
        })
        XCTAssertTrue(g.drops.handleDrop(["inbox:c2"], at: CGPoint(x: 150, y: 150)))
        for _ in 0..<50 where model.selection != .node(s) { await Task.yield() }
        XCTAssertEqual(model.selection, .node(s), "control: the send landed")
        XCTAssertNil(g.titleID.value, "a capture that joined a region opened a title")
    }

    func test_returnOnASelectedRegionOpensItsTitle() {
        let model = populatedModel()
        model.selection = .region(r)
        let f = Fixture(model: model)
        XCTAssertTrue(f.keys.handleCanvasKey(.returnKey, viewSize: CGSize(width: 1200, height: 900)))
        XCTAssertEqual(f.titleID.value, r)
        XCTAssertFalse(model.isInGesture)
    }

    func test_aDoubleClickOnTheTitleOpensIt() {
        let model = populatedModel()
        let f = Fixture(model: model)
        f.clicks.handleClick(at: onTheTitle, clickCount: 1)
        XCTAssertEqual(model.selection, .region(r), "precondition: click 1 selected the region")
        f.clicks.handleClick(at: onTheTitle, clickCount: 2)
        XCTAssertEqual(f.titleID.value, r, "a double click on the title did not open it")
        XCTAssertEqual(model.scene.count, 1, "a double click on the title minted a scrap")
        XCTAssertFalse(model.isInGesture)
    }

    /// Escape on a dimmed board with a title open belongs to the title.
    func test_escapeWithATitleOpenDoesNotAskForTheWholeBoard() {
        let model = populatedModel()
        var f = Fixture(model: model)
        f.subject = .piece("p1")
        XCTAssertTrue(f.keys.escapeAsksForTheWholeBoard(), "control: a dimmed board takes Escape")
        f.titles.begin(r)
        XCTAssertFalse(f.keys.escapeAsksForTheWholeBoard(),
                       "the board took the Escape meant for the title")
    }

    func test_readOnlyOpensNothing() throws {
        let model = try readOnlyModel()
        model.selection = .region(r)
        let f = Fixture(model: model)

        f.titles.begin(r)
        XCTAssertNil(f.titleID.value, "a read-only canvas opened a title")
        XCTAssertFalse(f.keys.handleCanvasKey(.returnKey, viewSize: CGSize(width: 1200, height: 900)))
        XCTAssertNil(f.titleID.value, "Return opened a title on a read-only canvas")
        f.clicks.handleClick(at: onTheTitle, clickCount: 2)
        XCTAssertNil(f.titleID.value, "a double click opened a title on a read-only canvas")
        XCTAssertFalse(model.isInGesture)

        // The control: the same model writable opens.
        let writable = populatedModel()
        let g = Fixture(model: writable)
        g.titles.begin(r)
        XCTAssertEqual(g.titleID.value, r)
    }

    /// A press on the bar that has just opened the title belongs to the field:
    /// no drag begins under it (the double-click's own second press).
    func test_thePressThatOpensTheTitleBeginsNoDrag() {
        let model = populatedModel()
        let f = Fixture(model: model)
        f.clicks.handleClick(at: onTheTitle, clickCount: 1)
        f.clicks.handleClick(at: onTheTitle, clickCount: 2)
        f.drags.handleDrag(at: onTheTitle, phase: .began, shiftHeld: false, timestamp: 0)
        XCTAssertFalse(f.interaction.value.isActive, "a drag began under the open title")
        XCTAssertFalse(model.isInGesture)
    }

    // MARK: - Review round 1

    /// **A refused write leaves a live field.** Mid-gesture (or read-only) the
    /// commit is refused and reported as such, the title stays open with the
    /// words, and the field takes Return again; the control is an accepted
    /// commit, which reports once.
    func test_aRefusedCommitLeavesTheTitleOpenAndTheFieldLive() {
        let model = populatedModel()
        let f = Fixture(model: model)
        f.titles.begin(r)
        f.titles.noteTyping("Falls", in: r)
        model.beginGesture("Move Card")
        XCTAssertFalse(f.titles.commit("Falls"), "a commit mid-gesture was not refused")
        XCTAssertEqual(f.titleID.value, r, "a refused commit closed the title")
        XCTAssertEqual(f.titleDraft.value?.text, "Falls", "a refused commit dropped the words")
        XCTAssertEqual(model.scene.region(r)?.label, "Fog")
        model.endGesture()
        XCTAssertTrue(f.titles.commit("Falls"), "control: the same commit, gesture closed")
        XCTAssertEqual(model.scene.region(r)?.label, "Falls")

        let container = RegionTitleEditorContainer(frame: .zero)
        var commits = 0
        var accepts = false
        container.onCommit = { _ in commits += 1; return accepts }
        container.bind(to: r, label: "Fog")
        let returnKey = #selector(NSResponder.insertNewline(_:))
        _ = container.control(container.field, textView: NSTextView(), doCommandBy: returnKey)
        _ = container.control(container.field, textView: NSTextView(), doCommandBy: returnKey)
        XCTAssertEqual(commits, 2, "after a refused Return the field took no second Return")
        accepts = true
        _ = container.control(container.field, textView: NSTextView(), doCommandBy: returnKey)
        _ = container.control(container.field, textView: NSTextView(), doCommandBy: returnKey)
        XCTAssertEqual(commits, 3, "control: an accepted Return reports once")
    }

    /// **An undo that takes the region away closes its title**, so a redo
    /// cannot bring the field back and take the keyboard. Nothing is written.
    func test_aTitleWhoseRegionAnUndoTookAwayIsForgotten() {
        let model = attachedModel()
        let f = Fixture(model: model)
        f.sweep(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 340))
        XCTAssertNotNil(f.titleID.value, "precondition: the title opened")
        f.titles.forgetIfTheRegionIsGone()
        XCTAssertNotNil(f.titleID.value, "control: a region still there is not forgotten")

        model.undo.undo()
        XCTAssertEqual(model.scene.regionCount, 0, "precondition: the undo took the region")
        f.titles.forgetIfTheRegionIsGone()
        XCTAssertNil(f.titleID.value, "the title still names a region the undo took away")
        model.undo.redo()
        XCTAssertEqual(model.scene.regionCount, 1, "precondition: the redo brought it back")
        XCTAssertNil(f.titleID.value, "the redo reopened the title")
    }
}
