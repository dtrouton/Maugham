import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **The centre figure view** (report plan 8a Task 6): a table figure's grid
/// mounted in the centre (`FigureSubjectSurface` → `FigureCentreGrid`, the
/// figure window's `FigureWindowGrid` in its centre frame) against the same
/// stores as a project window's editor (`FigureGridMountedTestCase`'s), so a
/// grid in place and the centre's share one figure host and one
/// `FigureWindows`. Keys go down the real path (`window.sendEvent`); ⌘Z is the
/// menu bar's item walked to its responder; the subject moves through the
/// probe's state; no control is pressed and no click synthesised (tripwire 33).
@MainActor
final class FigureCentreGridTests: FigureGridMountedTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // A signed book whose root is this Mac, so another author can be admitted.
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: temp.url.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: temp.url.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: temp.url.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        for centre in centres {
            centre.box.figureId = nil
            centre.window.reportsKey = false
            centre.window.close()
            _ = await centre.windows.settle(within: .seconds(5))
        }
        centres = []
        DocumentStore.figureHostAppendedForTesting = nil
        try await super.tearDown()
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
    }

    // MARK: - The probe

    /// What the window hands the figure route: the subject, the persona and
    /// the control plane (review mode, the share), moved by a test.
    @Observable
    @MainActor
    final class CentreBox {
        var figureId: String?
        var persona: Persona = .author
        var control = EditorControl()
    }

    /// The figure route as `CentreColumn` mounts it: production's
    /// `FigureSubjectSurface`, handed the window's presence, figure windows,
    /// listing and the window itself.
    private struct CentreProbe: View {
        let box: CentreBox
        let store: ProjectStore
        let documentStore: DocumentStore
        let windows: FigureWindows
        let presence: FigureGridPresence
        let listing: FigureListingModel
        @State private var window: NSWindow?

        var body: some View {
            ZStack {
                if let id = box.figureId {
                    FigureSubjectSurface(
                        figureID: id, store: store, documentStore: documentStore, figureWindows: windows,
                        presence: presence, listing: listing, control: box.control,
                        persona: box.persona, window: window)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WindowAccessor(window: $window))
        }
    }

    private struct Centre {
        let window: KeyTestWindow
        let box: CentreBox
        let windows: FigureWindows
        let presence: FigureGridPresence
        let listing: FigureListingModel
    }

    private var centres: [Centre] = []

    /// The centre mounted on `m`'s figure in a second window of the project.
    private func centre(_ m: Mounted, windows: FigureWindows, persona: Persona = .author,
                        listing: FigureListingModel? = nil,
                        figureId: String? = nil) throws -> Centre {
        let listing = listing ?? FigureListingModel()
        let box = CentreBox()
        box.persona = persona
        box.figureId = try figureId ?? XCTUnwrap(m.figure?.id)
        let presence = FigureGridPresence()
        let ds = try XCTUnwrap(m.store.documentStore)
        let window = TestWindow.mount(
            CentreProbe(box: box, store: m.store, documentStore: ds, windows: windows, presence: presence,
                        listing: listing),
            size: CGSize(width: 640, height: 420), as: KeyTestWindow.self)
        let centre = Centre(window: window, box: box, windows: windows, presence: presence, listing: listing)
        centres.append(centre)
        return centre
    }

    private static func gridView(in view: NSView?) -> FigureGridView? {
        guard let view else { return nil }
        if let grid = view as? FigureGridView { return grid }
        for sub in view.subviews { if let grid = gridView(in: sub) { return grid } }
        return nil
    }

    /// The centre's controller, once its visit has opened and mounted.
    private func mounted(_ centre: Centre, file: StaticString = #filePath,
                         line: UInt = #line) async throws -> FigureGridController {
        let up = await RunLoopPump.until(deadline: 5) {
            (Self.gridView(in: centre.window.contentView)?.delegate as? FigureGridController) != nil
        }
        XCTAssertTrue(up, "the centre's grid mounted", file: file, line: line)
        return try XCTUnwrap(Self.gridView(in: centre.window.contentView)?.delegate as? FigureGridController,
                             file: file, line: line)
    }

    private func cell(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    private func key(_ window: NSWindow, _ characters: String, code: UInt16 = 0,
                     _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func type(_ window: NSWindow, _ text: String) {
        for character in text { window.sendEvent(key(window, String(character))) }
    }

    /// The grid takes the keys as another surface asks it to (the tree's
    /// Open in Window, a card's double-click: `FigureWindows.focus`), and
    /// `text` is typed into `cell` and left open.
    private func typeOpen(_ centre: Centre, _ c: FigureGridController, _ cell: CellKey, _ text: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(centre.windows.focus(c.figureId), file: file, line: line)
        XCTAssertTrue(centre.window.firstResponder === c.gridView, "the grid has the keys", file: file, line: line)
        c.handle(.click(cell, extend: false))
        type(centre.window, text)
        XCTAssertNotNil(c.gridView.editingCell, "premise: an edit is open", file: file, line: line)
    }

    /// **⌘Z (⇧⌘Z) as the keyboard delivers it**: no view in the window's walk
    /// claims the chord; the menu bar's Edit item binds it; its action goes to
    /// the first responder in the window's chain answering it.
    @discardableResult
    private func pressUndo(_ window: NSWindow, redo: Bool = false,
                           file: StaticString = #filePath, line: UInt = #line) throws -> NSResponder {
        let chord = key(window, redo ? "Z" : "z", code: 6, redo ? [.command, .shift] : .command)
        XCTAssertFalse(window.performKeyEquivalent(with: chord), "no view claims ⌘Z", file: file, line: line)
        let action = Selector(redo ? "redo:" : "undo:")
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.action == action { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        let bound = try XCTUnwrap(find(NSApp.mainMenu), "premise: the menu bar has Edit ▸ Undo/Redo",
                                  file: file, line: line)
        XCTAssertEqual(bound.keyEquivalent.lowercased(), "z", file: file, line: line)
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
        let target = try XCTUnwrap(responder, "something answers \(action)", file: file, line: line)
        let item = NSMenuItem(title: bound.title, action: action, keyEquivalent: bound.keyEquivalent)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: item), file: file, line: line)
        return target
    }

    /// Sam is admitted as the author of the chapter, so this root yields on
    /// it — its text and its figures (a figure is its piece's).
    private func samWritesTheChapter(_ m: Mounted) async throws {
        let ds = try XCTUnwrap(m.store.documentStore)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await ds.admit(device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                               permit: .author(.pieces([try XCTUnwrap(m.store.manifest.structure.first?.id)])))
        await ds.postureSettled()
    }

    // MARK: - The surface, the keys and the stack

    /// The centre mounts the grid holding the figure in place, the window's
    /// presence enabled for Format ▸ Table, no Done, the caption locked, an
    /// unused figure's "—" and its name — and leaves the keys where they were
    /// until asked. Asked (`focus`), the grid has them at once; typing down
    /// the real key path writes the cell on the grid's own stack (nothing
    /// collapses into a text step), and ⌘Z there takes it back.
    func test_theCentreMountsTheGrid_typesThroughTheKeyPath_andKeepsItsOwnStack() async throws {
        let m = try await mount()
        let windows = FigureWindows()
        let centre = try centre(m, windows: windows)
        let c = try await mounted(centre)
        let figureId = try XCTUnwrap(m.figure?.id)

        XCTAssertNotNil(windows.inPlaceHolds[figureId], "the centre holds the figure in place")
        XCTAssertTrue(centre.presence.holdsTheKeys, "Format ▸ Table reads the centre's grid")
        XCTAssertEqual(centre.presence.menu, c.menuState)
        XCTAssertTrue(c.bars.doneButton.isHidden, "the centre has nothing to close")
        XCTAssertTrue(c.bars.openInWindow.isHidden)
        XCTAssertFalse(c.bars.captionField.isEditable, "the caption is the text's (R7d-6)")
        XCTAssertTrue(c.bars.nameField.isEditable)
        XCTAssertEqual(c.bars.numberLabel.stringValue, "—", "an unused figure")
        XCTAssertEqual(c.bars.nameField.stringValue, "t", "shows its name")
        XCTAssertEqual(c.mode, .editable)
        XCTAssertFalse(centre.window.firstResponder === c.gridView, "the keys stay where the writer had them")

        let a1 = cell(c, 1, 1)
        typeOpen(centre, c, a1, "42")
        XCTAssertTrue(centre.window.firstResponder === c.gridView.cellEditor.currentEditor(), "typing in the cell")
        centre.window.sendEvent(key(centre.window, "\r", code: 36))
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[a1]?.content, .value(.number(42)))
        XCTAssertTrue(c.gridUndo.canUndo, "on the grid's own stack")
        XCTAssertFalse(c.host.visitHasRecorded, "no visit recorded: nothing collapses into a text step")
        XCTAssertFalse(centre.window.undoManager?.canUndo ?? false, "nothing on the window's stack")

        let target = try pressUndo(centre.window)
        XCTAssertTrue(target === c.gridView, "the grid answers ⌘Z")
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[a1], "⌘Z took the cell back")
        try pressUndo(centre.window, redo: true)
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[a1]?.content, .value(.number(42)), "⇧⌘Z put it back")
    }

    /// **Esc with nothing to cancel does nothing**: an open edit is
    /// cancelled; a second Esc leaves the grid mounted, holding the figure,
    /// with the keys.
    func test_escWithNothingToCancelDoesNothing() async throws {
        let m = try await mount()
        let windows = FigureWindows()
        let centre = try centre(m, windows: windows)
        let c = try await mounted(centre)
        let b2 = cell(c, 2, 2)
        typeOpen(centre, c, b2, "4")
        centre.window.sendEvent(key(centre.window, "\u{1b}", code: 53))
        XCTAssertNil(c.gridView.editingCell, "Esc cancelled the open edit")
        XCTAssertNil(c.host.state.table[b2])
        centre.window.sendEvent(key(centre.window, "\u{1b}", code: 53))
        centre.window.sendEvent(key(centre.window, "\u{1b}", code: 53))
        XCTAssertTrue(centre.window.firstResponder === c.gridView, "the grid keeps the keys")
        XCTAssertTrue(Self.gridView(in: centre.window.contentView) === c.gridView, "still mounted")
        XCTAssertNotNil(windows.inPlaceHolds[c.figureId], "still holding the figure")
    }

    // MARK: - Leaving

    /// **Leaving the subject mid-edit commits**: the open edit is written,
    /// the hold goes, Format ▸ Table stands down, and no step is left on any
    /// stack — and the next grid on the figure begins after the write.
    func test_leavingTheSubjectMidEditCommits_andReleasesTheFigure() async throws {
        let m = try await mount()
        let windows = FigureWindows()
        let centre = try centre(m, windows: windows)
        let c = try await mounted(centre)
        let figureId = c.figureId
        let b3 = cell(c, 2, 3)
        typeOpen(centre, c, b3, "5")

        centre.box.figureId = nil
        let released = await RunLoopPump.until(deadline: 5) { windows.inPlaceHolds[figureId] == nil }
        XCTAssertTrue(released, "leaving the subject lets the figure go")
        XCTAssertFalse(centre.presence.holdsTheKeys, "Format ▸ Table stands down")
        XCTAssertNil(Self.gridView(in: centre.window.contentView), "the grid unmounted")
        let landed = await windows.settle(within: .seconds(5))
        XCTAssertTrue(landed, "the visit's writes are tracked for the project's close")
        await windows.visitEnded(figureId)
        XCTAssertEqual(c.host.state.table[b3]?.content, .value(.number(5)), "the open edit was committed")
        XCTAssertFalse(centre.window.undoManager?.canUndo ?? false, "no text step")

        // The editor may expand it now.
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        XCTAssertNotNil(m.coordinator.figureGrid, "the figure is free for another grid")
    }

    /// **Closing the project window ends the visit as a figure window's
    /// close does**: the open edit is committed and tracked for the
    /// project's close.
    func test_closingTheWindowCommitsTheOpenEdit() async throws {
        let m = try await mount()
        let windows = FigureWindows()
        let centre = try centre(m, windows: windows)
        let c = try await mounted(centre)
        let a2 = cell(c, 1, 2)
        typeOpen(centre, c, a2, "8")
        centre.window.close()
        XCTAssertNil(windows.inPlaceHolds[c.figureId], "the close let the figure go at once")
        let landed = await windows.settle(within: .seconds(5))
        XCTAssertTrue(landed)
        XCTAssertEqual(c.host.state.table[a2]?.content, .value(.number(8)))
    }

    // MARK: - Review Focus 1

    /// **Review Focus 1, a send from the tree**: `foldGrids(on:)` — what the
    /// row's Send to Research awaits first — folds the centre's grid with no
    /// write, and the figure is free before the park.
    func test_reviewFocus1_aSendFromTheTreeFoldsTheCentreWithoutAWrite() async throws {
        let m = try await mount()
        let windows = FigureWindows()
        let centre = try centre(m, windows: windows)
        let c = try await mounted(centre)
        var appended = 0
        DocumentStore.figureHostAppendedForTesting = { _ in appended += 1 }

        await windows.foldGrids(on: c.figureId)
        XCTAssertNil(windows.inPlaceHolds[c.figureId], "the centre let the figure go")
        XCTAssertFalse(centre.presence.holdsTheKeys)
        XCTAssertEqual(appended, 0, "folding the centre wrote nothing")
        let unmounted = await RunLoopPump.until(deadline: 5) { Self.gridView(in: centre.window.contentView) == nil }
        XCTAssertTrue(unmounted, "the grid is gone from the centre")
    }

    /// **Review Focus 1, a park from elsewhere** (another Mac's send arrives):
    /// the grid turns read-only with the parked reason at the card edge, and
    /// the subject leaving — the repair to the project row — unmounts it
    /// without a write.
    func test_reviewFocus1_aParkElsewhereTurnsTheCentreReadOnly_andLeavingWritesNothing() async throws {
        let m = try await mount()
        let windows = FigureWindows()
        let centre = try centre(m, windows: windows)
        let c = try await mounted(centre)
        _ = try await m.store.sendToResearch(figureId: c.figureId, scope: .shared)
        let parked = await RunLoopPump.until(deadline: 5) { c.mode == .readOnly(.parked) }
        XCTAssertTrue(parked, "the parked reason: \(c.mode)")
        XCTAssertEqual(c.bars.reasonMessage, "This table is in Research.")

        var appended = 0
        DocumentStore.figureHostAppendedForTesting = { _ in appended += 1 }
        centre.box.figureId = nil
        let released = await RunLoopPump.until(deadline: 5) { windows.inPlaceHolds[c.figureId] == nil }
        XCTAssertTrue(released)
        _ = await windows.settle(within: .seconds(5))
        XCTAssertEqual(appended, 0, "unmounting wrote nothing")
    }

    // MARK: - Review Focus 2: one grid per host

    /// **The centre first**: the same figure's card in a document does not
    /// expand — it says the figure is being edited in another window and
    /// brings the centre's grid front with the keys.
    func test_reviewFocus2_theCentreHoldsIt_aCardInTheTextFocusesTheCentre() async throws {
        let windows = FigureWindows()
        let m = try await mount(windows: windows)
        let centre = try centre(m, windows: windows)
        let c = try await mounted(centre)
        XCTAssertEqual(windows.heldElsewhere(c.figureId, besides: nil), .anotherWindow,
                       "a card says \(FigureWindows.Elsewhere.anotherWindow.cardLabel)")
        XCTAssertFalse(centre.window.firstResponder === c.gridView, "premise: the keys are elsewhere")

        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        XCTAssertNil(m.coordinator.figureGrid, "no second grid on the figure")
        XCTAssertTrue(centre.window.firstResponder === c.gridView, "the centre's grid has the keys")
    }

    /// **The text first**: the centre opens no second grid — it says where
    /// the figure is being edited and brings that grid front; when the text
    /// folds it, the centre takes the figure, after that visit's writes.
    func test_reviewFocus2_theTextHoldsIt_theCentreFocusesTheTextsGrid_thenTakesItWhenLetGo() async throws {
        let windows = FigureWindows()
        let m = try await mount(windows: windows)
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let inPlace = try await opened(m)
        let inPlaceGrid = try XCTUnwrap(inPlace.controller?.gridView)
        m.window.makeFirstResponder(nil)   // the keys elsewhere, not the text (which would fold it)
        XCTAssertNotNil(m.coordinator.figureGrid, "premise: still expanded")
        XCTAssertFalse(m.window.firstResponder === inPlaceGrid, "premise: the grid does not have the keys")
        let figureId = inPlace.figureId

        let centre = try centre(m, windows: windows)
        let focused = await RunLoopPump.until(deadline: 5) { m.window.firstResponder === inPlaceGrid }
        XCTAssertTrue(focused, "the centre brought the text's grid front")
        XCTAssertNil(Self.gridView(in: centre.window.contentView), "no second grid")
        XCTAssertEqual(windows.inPlaceHolds[figureId], inPlace.hold, "the text still holds it")
        XCTAssertFalse(centre.presence.holdsTheKeys)

        m.coordinator.foldFigureGrid(commit: true)
        let c = try await mounted(centre)
        XCTAssertNotNil(windows.inPlaceHolds[figureId], "the centre holds it now")
        XCTAssertNotEqual(windows.inPlaceHolds[figureId], inPlace.hold)
        XCTAssertEqual(c.figureId, figureId)
    }

    /// A figure window opening on the figure takes it from the centre (never
    /// two grids on one host); its close gives it back.
    func test_aFigureWindowOpeningOnTheFigureTakesItFromTheCentre() async throws {
        let m = try await mount()
        let windows = FigureWindows()
        let centre = try centre(m, windows: windows)
        let c = try await mounted(centre)
        let registration = windows.opened(c.figureId, close: {})
        let yielded = await RunLoopPump.until(deadline: 5) { windows.inPlaceHolds[c.figureId] == nil }
        XCTAssertTrue(yielded, "the centre let the figure go to the window")
        XCTAssertNil(Self.gridView(in: centre.window.contentView))

        windows.closed(registration)
        let back = try await mounted(centre)
        XCTAssertNotNil(windows.inPlaceHolds[back.figureId], "the centre takes it again")
    }

    // MARK: - Read-only reasons

    /// Review (a persona that does not edit figures) opens read-only with
    /// the review reason; the window's ⌘⌥⇧R flips an open grid; a view-only
    /// share is read-only.
    func test_reviewPersonaAndTheReviewToggleAndAViewOnlyShareAreReadOnly() async throws {
        let m = try await mount()
        let review = try centre(m, windows: FigureWindows(), persona: .review)
        let r = try await mounted(review)
        XCTAssertEqual(r.mode, .readOnly(.reviewMode))
        XCTAssertFalse(r.bars.nameField.isEditable)
        review.box.figureId = nil

        let windows = FigureWindows()
        let author = try centre(m, windows: windows)
        let c = try await mounted(author)
        XCTAssertEqual(c.mode, .editable)
        author.box.control.isManualReviewMode = true
        let flipped = await RunLoopPump.until(deadline: 5) { c.mode == .readOnly(.reviewMode) }
        XCTAssertTrue(flipped, "⌘⌥⇧R turns the open grid read-only")
        author.box.control.isManualReviewMode = false
        let back = await RunLoopPump.until(deadline: 5) { c.mode == .editable }
        XCTAssertTrue(back)
        author.box.control.shareIsReadOnly = true
        let share = await RunLoopPump.until(deadline: 5) { c.mode == .readOnly(.viewOnlyShare) }
        XCTAssertTrue(share, "a view-only share")
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.viewOnlyShare.sentence)
    }

    /// **Review Focus 5**: a figure in a piece another author holds opens
    /// read-only, typing answered with the reason and written nowhere.
    func test_anotherPersonsPieceOpensReadOnly() async throws {
        let m = try await mount()
        try await samWritesTheChapter(m)
        let windows = FigureWindows()
        let centre = try centre(m, windows: windows)
        let c = try await mounted(centre)
        XCTAssertEqual(c.mode, .readOnly(.notYours))
        XCTAssertTrue(windows.focus(c.figureId))
        XCTAssertTrue(centre.window.firstResponder === c.gridView)
        let a1 = cell(c, 1, 1)
        c.handle(.click(a1, extend: false))
        type(centre.window, "9")
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[a1], "nothing written")
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.notYours.sentence)
    }

    // MARK: - Format ▸ Table

    /// **Format ▸ Table reaches the centre's grid** while its window is key,
    /// and not while it is not.
    func test_formatTableReachesTheCentreGridWhileItsWindowIsKey() async throws {
        let m = try await mount()
        m.window.reportsKey = false
        let windows = FigureWindows()
        let centre = try centre(m, windows: windows)
        let c = try await mounted(centre)
        c.handle(.click(cell(c, 1, 1), extend: false))
        let rows = c.host.state.table.rows.count

        MaughamEvent.postFigureTableCommand(.insertRowBelow)
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table.rows.count, rows + 1, "the key window's centre grid took the command")
        XCTAssertTrue(c.gridUndo.canUndo, "on the grid's own stack")

        centre.window.reportsKey = false
        MaughamEvent.postFigureTableCommand(.insertRowBelow)
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table.rows.count, rows + 1, "a centre whose window is not key takes nothing")
    }

    // MARK: - The line from the listing

    /// **The bottom bar's number and caption are the window's listing's**:
    /// a figure the chapter uses shows "Table 1" and its caption, locked;
    /// the listing changing reaches the bar.
    func test_theBottomBarShowsTheListingsNumberAndCaption() async throws {
        let m = try await mount()
        let ds = try XCTUnwrap(m.store.documentStore)
        let chapter = try XCTUnwrap(m.store.manifest.structure.first)
        let path = try XCTUnwrap(chapter.path)
        try "Prose.\n\n![Cash flow](../figures/t.csv){#tbl:t}\n".write(
            to: m.store.url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let doc = try await Document.load(url: m.store.url.appendingPathComponent(path), actor: .author,
                                          session: "s", presenter: nil)
        await doc.close()
        let index = ReferenceIndexHost()
        index.attach(.window(store: m.store, documentStore: ds))
        await index.idle()
        let listing = FigureListingModel()
        listing.refresh(index: index.index, store: m.store)
        let figureId = try XCTUnwrap(m.figure?.id)
        XCTAssertEqual(listing.row(forFigureId: figureId)?.number, "Table 1", "premise: the book uses it")

        let centre = try centre(m, windows: FigureWindows(), listing: listing)
        let c = try await mounted(centre)
        XCTAssertEqual(c.bars.numberLabel.stringValue, "Table 1")
        XCTAssertEqual(c.bars.captionField.stringValue, "Cash flow")
        XCTAssertFalse(c.bars.captionField.isEditable)
        XCTAssertTrue(c.menuState.isEnabled(.sendTo(.piece)), "the piece holding the line")

        listing.clear()
        let followed = await RunLoopPump.until(deadline: 5) { c.bars.numberLabel.stringValue == "—" }
        XCTAssertTrue(followed, "the bar follows the listing")
        index.attach(nil)
    }
}
