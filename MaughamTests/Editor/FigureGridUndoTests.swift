import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **The grid's private undo stack and the collapse at fold** (report plan 7d
/// Task 6; rulings R7d-4, R7d-10, R7d-11, P1). While a table is expanded its
/// writes register on the grid's own stack and ⌘Z / ⇧⌘Z there run it; when
/// it folds, the whole visit becomes ONE window step, registered at the
/// moment of folding.
///
/// ⌘Z and ⇧⌘Z are delivered on the keyboard's own path as far as a host
/// that may not be key allows (`press(_:redo:)`): the window's walk of its
/// views leaves the chord, the menu bar's Edit item answers it, and its
/// target-less action goes to the first responder in the window's chain that
/// answers it, validated (enabled and titled) as the menu validates it. The
/// whole `NSApp.sendEvent` path runs where the host may be made active (CI)
/// and skips by name elsewhere. No control is pressed and no click
/// synthesised (tripwire 33).
@MainActor
final class FigureGridUndoTests: FigureGridMountedTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // A signed book whose root is this Mac, so another Mac can be admitted.
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
        DocumentStore.figureHostAppendedForTesting = nil
        try await super.tearDown()
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
    }

    // MARK: - Keys

    private func key(_ m: Mounted, _ characters: String, code: UInt16 = 0,
                     _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: m.window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func send(_ m: Mounted, _ characters: String, code: UInt16 = 0) {
        m.window.sendEvent(key(m, characters, code: code))
    }

    private func type(_ m: Mounted, _ text: String) {
        for character in text { send(m, String(character)) }
    }

    /// `body` as one event's undo group on the window's stack, as AppKit
    /// brackets a key event (the window's manager does not group by event
    /// here). Only around an event that registers something: AppKit opens an
    /// event's group at a registration, and an empty group made by hand is
    /// kept as an undoable step (measured) — a step the app never makes.
    private func asOneEvent(_ m: Mounted, _ body: () -> Void) throws {
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    /// The menu bar's Edit ▸ Undo (Redo) item, as the app holds it.
    private func editItem(redo: Bool) -> NSMenuItem? {
        let action = Selector(redo ? "redo:" : "undo:")
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.action == action { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    /// **⌘Z (⇧⌘Z) as the keyboard delivers it**: no view in the window's
    /// walk claims the chord; the menu bar's Edit item binds it; its action
    /// goes to the first responder in the window's chain answering it, which
    /// is answered here. Returns that responder and the item's title as
    /// validated there.
    @discardableResult
    private func press(_ m: Mounted, redo: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) throws -> (NSResponder, String) {
        let chord = key(m, redo ? "Z" : "z", code: 6, redo ? [.command, .shift] : .command)
        XCTAssertFalse(m.window.performKeyEquivalent(with: chord), "no view claims ⌘Z", file: file, line: line)
        let bound = try XCTUnwrap(editItem(redo: redo), "premise: the menu bar has Edit ▸ Undo/Redo",
                                  file: file, line: line)
        XCTAssertEqual(bound.keyEquivalent.lowercased(), "z", file: file, line: line)
        XCTAssertTrue(bound.keyEquivalentModifierMask.contains(.command), file: file, line: line)
        let action = try XCTUnwrap(bound.action)
        var responder = m.window.firstResponder
        while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
        let target = try XCTUnwrap(responder, "something answers \(action)", file: file, line: line)
        // A copy validated, so the app's own item is never retitled by a test.
        let item = NSMenuItem(title: bound.title, action: action, keyEquivalent: bound.keyEquivalent)
        let enabled = (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item)
            ?? (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
        XCTAssertTrue(enabled, "\(item.title) is enabled at \(target)", file: file, line: line)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: item), file: file, line: line)
        return (target, item.title)
    }

    private func expanded(_ m: Mounted) async throws -> (FigureGridExpansion, FigureGridController) {
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        let controller = try XCTUnwrap(grid.controller)
        XCTAssertTrue(m.window.firstResponder === controller.gridView, "premise: the grid has the keys")
        return (grid, controller)
    }

    private func cell(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    /// `text` typed into `cell` on the grid's keys and committed by Return.
    private func typeCell(_ m: Mounted, _ c: FigureGridController, _ cell: CellKey, _ text: String) {
        c.handle(.click(cell, extend: false))
        type(m, text)
        send(m, "\r", code: 36)
    }

    private func number(_ x: Double) -> CellContent { .value(.number(x)) }

    /// The fold's settling: writes landed, the visit ended, the step kept or removed.
    private func settled(_ m: Mounted) async {
        await m.coordinator.figureGridFolding?.value
        await m.coordinator.lastFigureVisitStep?.settled?.value
    }

    private func notices(during body: () async throws -> Void) async rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String { seen.append(message) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    // MARK: - Review Focus 2

    /// **Expand, type in five cells, sort, fold, type a sentence, ⌘Z, ⌘Z**:
    /// the first ⌘Z takes back the sentence, the second the whole visit —
    /// cells and sort — in one step and one render; ⇧⌘Z puts it back with
    /// the same rows. The fifth cell is still landing when Done folds (the
    /// fold commits it), and the typing before the expansion is a step of
    /// its own below the visit.
    func test_reviewFocus2_aWholeVisitIsOneWindowStepUnderTheSentenceTypedAfterIt() async throws {
        let m = try await mount(rows: 6)
        let undo = try XCTUnwrap(m.textView.undoManager)
        let end = location(m, "The end.") + ("The end." as NSString).length
        m.textView.setSelectedRange(NSRange(location: end, length: 0))
        try asOneEvent(m) { type(m, " Before.") }
        let (_, c) = try await expanded(m)
        let before = c.host.state.table

        for (row, x) in [(1, 3), (2, 1), (3, 5), (4, 2)] { typeCell(m, c, cell(c, 1, row), "\(x)") }
        await c.settleWrites()
        let unsorted = c.host.state.table.rows
        c.handle(.click(cell(c, 1, 2), extend: false))
        c.performTableCommand(.sortDescending)
        await c.settleWrites()
        XCTAssertNotEqual(c.host.state.table.rows, unsorted, "premise: sorted")
        XCTAssertEqual(undo.undoActionName, "Typing", "nothing of the grid's reached the window's stack")
        XCTAssertTrue(c.gridUndo.canUndo, "the grid's own stack holds them")

        // The fifth cell is typed and Done folds over it.
        c.handle(.click(cell(c, 2, 1), extend: false))
        try asOneEvent(m) {
            type(m, "4")
            c.perform(.done)
        }
        XCTAssertNil(m.coordinator.figureGrid, "folded")
        await settled(m)
        let after = c.host.state.table
        XCTAssertEqual(after[cell(c, 2, 1)]?.content, number(4), "the fold committed the fifth cell")
        XCTAssertEqual(undo.undoActionName, FigureVisitUndo.actionName, "one window step for the visit")

        m.textView.setSelectedRange(NSRange(location: (m.textView.string as NSString).length, length: 0))
        try asOneEvent(m) { type(m, " After.") }
        XCTAssertTrue(m.textView.string.hasSuffix("The end. Before. After."))

        // ⌘Z: the sentence.
        var (target, title) = try press(m)
        XCTAssertTrue(target === m.window, "in the text, the window's stack")
        XCTAssertEqual(title, undo.undoMenuTitle(forUndoActionName: "Typing"))
        XCTAssertTrue(m.textView.string.hasSuffix("The end. Before."), "the first ⌘Z took the sentence")
        XCTAssertEqual(c.host.state.table, after, "and only the sentence")

        // ⌘Z: the whole visit, in one render.
        var renders = 0
        DocumentStore.figureHostAppendedForTesting = { _ in renders += 1 }
        defer { DocumentStore.figureHostAppendedForTesting = nil }
        (_, title) = try press(m)
        XCTAssertEqual(title, undo.undoMenuTitle(forUndoActionName: FigureVisitUndo.actionName))
        await c.host.awaitPendingUndoWork()
        XCTAssertEqual(c.host.state.table, before, "the second ⌘Z took the whole visit back: cells and sort")
        XCTAssertEqual(renders, 1, "one render")
        XCTAssertTrue(m.textView.string.hasSuffix("The end. Before."), "the text untouched")

        // ⇧⌘Z: the visit again, the same rows.
        (_, title) = try press(m, redo: true)
        XCTAssertEqual(title, undo.redoMenuTitle(forUndoActionName: FigureVisitUndo.actionName))
        await c.host.awaitPendingUndoWork()
        XCTAssertEqual(c.host.state.table, after, "⇧⌘Z put the visit back, ids and all")
        XCTAssertEqual(undo.undoActionName, FigureVisitUndo.actionName, "undoable again")

        // And the typing before the expansion is still its own step, below.
        undo.undo()
        await c.host.awaitPendingUndoWork()
        XCTAssertEqual(c.host.state.table, before)
        XCTAssertEqual(undo.undoActionName, "Typing")
        undo.undo()
        XCTAssertTrue(m.textView.string.hasSuffix("The end."), "the typing before the visit, on its own")
    }

    /// **Another device changed what the visit touched meanwhile** (R7d-10):
    /// the sentence still goes on the first ⌘Z; the visit's ⌘Z declines whole
    /// with the "changed elsewhere" sentence and writes nothing.
    func test_reviewFocus2_aVisitWhoseCellChangedElsewhereDeclinesWithASentence() async throws {
        let m = try await mount(rows: 4)
        let (_, c) = try await expanded(m)
        typeCell(m, c, cell(c, 1, 1), "1")
        typeCell(m, c, cell(c, 1, 2), "2")
        await c.settleWrites()
        try asOneEvent(m) { send(m, "\u{1B}", code: 53) }   // Esc on a selected cell folds
        XCTAssertNil(m.coordinator.figureGrid)
        await settled(m)
        m.textView.setSelectedRange(NSRange(location: (m.textView.string as NSString).length, length: 0))
        try asOneEvent(m) { type(m, " More.") }

        // Another Mac, admitted as a whole-book author, writes over a cell the
        // visit touched, and its line arrives.
        let other = LocalIdentities.softwareForTesting()
        let ds = try XCTUnwrap(m.store.documentStore)
        _ = try await ds.admit(device: other.author.fingerprint, label: "Ada", ownName: "Ada’s Mac",
                               permit: .author(.book))
        await ds.postureSettled()
        let theirs = OpLogStore(
            projectURL: c.host.projectURL, identities: other,
            state: OpLogDeviceState(fileURL: TestTemp.root.appendingPathComponent("other-\(UUID().uuidString).json")))
        let touched = cell(c, 1, 2)
        try await theirs.append(Op(
            opId: ULID.generate(), docId: c.figureId, at: Date(), device: other.author.deviceId,
            session: "x", kind: .figureCellSet, changes: [],
            figure: FigureOpPayload(cell: touched, next: Cell(content: number(9)), prior: Cell(content: number(2)))))
        _ = try await theirs.sealChain(docId: c.figureId)
        try await c.host.reload()
        XCTAssertEqual(c.host.state.table[touched]?.content, number(9), "premise: their write arrived")
        let state = c.host.state
        try press(m)
        XCTAssertTrue(m.textView.string.hasSuffix("The end."), "the sentence went")
        let said = try await notices {
            try press(m)
            await c.host.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, ["Couldn't undo the change to the figure — it changed on another device."])
        XCTAssertEqual(c.host.state, state, "declined whole: nothing written")

        // The visit was never taken back, so ⇧⌘Z has nothing to put back.
        let redoSaid = try await notices {
            try press(m, redo: true)
            await c.host.awaitPendingUndoWork()
        }
        XCTAssertEqual(redoSaid, [], "nothing said")
        XCTAssertEqual(c.host.state, state, "nothing written")
    }

    // MARK: - ⌘Z inside the grid

    /// **⌘Z and ⇧⌘Z with the grid having the keys run the grid's own stack**,
    /// titled from it, and never the text's: the manuscript is untouched and
    /// the window's stack holds nothing of the grid's.
    func test_inTheGridCommandZRunsTheGridsOwnStack_titledFromIt() async throws {
        let m = try await mount()
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.removeAllActions()
        let (_, c) = try await expanded(m)
        let text = m.textView.string
        typeCell(m, c, cell(c, 1, 1), "7")
        await c.settleWrites()
        XCTAssertFalse(undo.canUndo, "nothing on the window's stack")

        let gridTitle = c.gridUndo.undoMenuItemTitle
        let (target, title) = try press(m)
        XCTAssertTrue(target === c.gridView, "the grid answers ⌘Z")
        XCTAssertEqual(title, gridTitle, "titled from the grid's stack")
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[cell(c, 1, 1)], "the grid's write taken back")
        XCTAssertEqual(m.textView.string, text, "the manuscript untouched")

        let (_, redoTitle) = try press(m, redo: true)
        XCTAssertEqual(redoTitle, c.gridUndo.redoMenuTitle(forUndoActionName: c.gridUndo.redoActionName))
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[cell(c, 1, 1)]?.content, number(7), "⇧⌘Z put it back")
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(c.gridView.undoManager === c.gridUndo, "the grid's undo manager is its own stack")
    }

    /// **⌘Z during an open cell edit cancels it** (R7d-4): the cell editor's
    /// field editor and field answer no `undo:`, so the grid takes it — the
    /// edit closes as Esc closes it, the grid's earlier step is left alone.
    func test_commandZDuringAnOpenCellEditCancelsTheEdit() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        typeCell(m, c, cell(c, 1, 1), "1")
        await c.settleWrites()
        c.handle(.click(cell(c, 1, 2), extend: false))
        type(m, "42")
        XCTAssertNotNil(c.gridView.editingCell, "premise: an edit is open")
        XCTAssertTrue(m.window.firstResponder === c.gridView.cellEditor.currentEditor(), "premise: typing in the cell")

        let (target, title) = try press(m)
        XCTAssertTrue(target === c.gridView)
        XCTAssertEqual(title, c.gridUndo.undoMenuTitle(forUndoActionName: "Typing"))
        await c.settleWrites()
        XCTAssertNil(c.gridView.editingCell, "the edit is cancelled")
        XCTAssertNil(c.host.state.table[cell(c, 1, 2)], "nothing written")
        XCTAssertEqual(c.host.state.table[cell(c, 1, 1)]?.content, number(1), "the grid's last step is left")
        XCTAssertTrue(m.window.firstResponder === c.gridView, "the grid has the keys")
    }

    /// **⌘Z over a caption, name or formula typed and not committed** puts
    /// back what was there (R7d-4): the bars answer `undo:` through the panel.
    func test_commandZInTheBarsCancelsTheirTyping() async throws {
        let m = try await mount()
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.removeAllActions()
        let (_, c) = try await expanded(m)
        for field in [c.bars.captionField, c.bars.nameField] {
            let committed = field.stringValue
            XCTAssertTrue(m.window.makeFirstResponder(field))
            type(m, "Draft")
            XCTAssertNotEqual(field.stringValue, committed, "premise: typed")
            let (target, _) = try press(m)
            XCTAssertTrue(target is FigureGridPanel, "the panel answers ⌘Z for the bars")
            XCTAssertEqual(field.stringValue, committed, "what was committed is back")
            XCTAssertTrue(m.window.firstResponder === c.gridView, "the grid has the keys")
        }
        c.handle(.click(cell(c, 1, 1), extend: false))
        XCTAssertTrue(m.window.makeFirstResponder(c.bars.formulaField))
        type(m, "5")
        XCTAssertNotNil(c.model.selection, "premise: the formula bar edits the active cell")
        try press(m)
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[cell(c, 1, 1)], "the formula bar's edit is cancelled, nothing written")
        XCTAssertFalse(undo.canUndo, "nothing on the window's stack")
        XCTAssertFalse(c.gridUndo.canUndo, "nor on the grid's")
    }

    /// **The fields leave no typing undo on the window's stack** (measured;
    /// the window's manager groups by event here, so any registration would
    /// open a group and show as `canUndo`):
    /// keys typed into the cell editor, the formula bar, the caption and the
    /// name — each field's own field-editor typing — register nothing on the
    /// window's stack nor the grid's. The control: the same keys typed into
    /// the manuscript register on the window's stack.
    func test_theGridsFieldsLeaveNoTypingUndoOnTheWindowsStack() async throws {
        let m = try await mount()
        let undo = try XCTUnwrap(m.textView.undoManager)
        let (_, c) = try await expanded(m)
        undo.removeAllActions()

        c.handle(.click(cell(c, 1, 1), extend: false))
        type(m, "12")
        XCTAssertNotNil(c.gridView.editingCell, "premise: typed in the cell editor")
        send(m, "\u{1B}", code: 53)
        for field in [c.bars.formulaField, c.bars.captionField, c.bars.nameField] {
            XCTAssertTrue(m.window.makeFirstResponder(field))
            type(m, "34")
            send(m, "\u{1B}", code: 53)
        }
        XCTAssertFalse(undo.canUndo, "no field's typing reached the window's stack")
        XCTAssertFalse(c.gridUndo.canUndo, "nor the grid's")

        m.coordinator.foldFigureGrid(commit: false)
        await settled(m)
        m.window.makeFirstResponder(m.textView)
        type(m, "34")
        XCTAssertTrue(undo.canUndo, "control: the same keys in the manuscript register typing undo")
    }

    /// **A read-only grid refuses ⌘Z and ⇧⌘Z with the reason line** (R7d-11):
    /// enabled, so the press is answered rather than beeped; nothing undone.
    func test_aReadOnlyGridRefusesUndoAndRedoWithTheReason() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        typeCell(m, c, cell(c, 1, 1), "3")
        await c.settleWrites()
        c.setAccess(.readOnly(.reviewMode), captionMayEdit: false)

        try press(m)
        await c.settleWrites()
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.reviewMode.sentence)
        XCTAssertEqual(c.host.state.table[cell(c, 1, 1)]?.content, number(3), "nothing undone")
        XCTAssertTrue(c.gridUndo.canUndo, "the step is still there")

        c.setAccess(.editable, captionMayEdit: true)
        c.undoInGrid()
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[cell(c, 1, 1)], "premise: editable again, it undoes")
        c.setAccess(.readOnly(.reviewMode), captionMayEdit: false)
        c.bars.showReason(nil)
        try press(m, redo: true)
        await c.settleWrites()
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.reviewMode.sentence)
        XCTAssertNil(c.host.state.table[cell(c, 1, 1)], "nothing redone")
    }

    // MARK: - What a fold registers

    /// **A visit that wrote nothing leaves no step**, not even for a moment
    /// (a ⌘Z at once must reach what is under it). The window's manager
    /// groups by event here, so a registration would show as `canUndo`.
    func test_aVisitThatWroteNothingLeavesNoStep() async throws {
        let m = try await mount()
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.removeAllActions()
        _ = try await expanded(m)
        send(m, "\u{1B}", code: 53)
        XCTAssertNil(m.coordinator.figureGrid)
        XCTAssertFalse(undo.canUndo, "no step at the fold")
        await settled(m)
        XCTAssertFalse(undo.canUndo, "nor after it")
    }

    /// **A teardown and a send to Research register nothing** (detach clears
    /// the window's stack; ruling P1): the visit is ended all the same, so
    /// the next visit on the figure records its own.
    func test_aTeardownOrASendToResearchFoldRegistersNoStep() async throws {
        let m = try await mount()
        let undo = try XCTUnwrap(m.textView.undoManager)
        for cause in [FigureGridFoldCause.sentToResearch, .teardown] {
            undo.removeAllActions()
            let (_, c) = try await expanded(m)
            typeCell(m, c, cell(c, 1, 1), "5")
            m.coordinator.forceFoldFigureGrid(cause)
            XCTAssertNil(m.coordinator.figureGrid)
            await settled(m)
            XCTAssertNotNil(c.host.state.table[cell(c, 1, 1)], "premise: the visit wrote")
            XCTAssertFalse(undo.canUndo, "\(cause): no step")
            XCTAssertNil(c.host.endVisit(), "\(cause): the visit was ended")
        }
        // The next visit records its own.
        undo.removeAllActions()
        let (_, c) = try await expanded(m)
        typeCell(m, c, cell(c, 2, 1), "1")
        try asOneEvent(m) { send(m, "\u{1B}", code: 53) }
        await settled(m)
        XCTAssertEqual(undo.undoActionName, FigureVisitUndo.actionName)
    }

    /// **A visit holding an op with no inverse** comes back un-undoable: no
    /// step is kept, and the reason is said.
    func test_aVisitThatCannotBeUndoneLeavesNoStepAndSaysWhy() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        let um = UndoManager()
        um.groupsByEvent = false
        let pinless = FigureReturnDiff.Change(kind: .figurePinClear, payload: FigureOpPayload(cell: cell(c, 1, 1)))
        let visit = FigureVisit(ops: [pinless])
        XCTAssertFalse(visit.isUndoable, "premise")
        var step: FigureVisitUndo?
        let said = await notices {
            um.beginUndoGrouping()
            step = FigureVisitUndo.register(on: um, host: c.host, visit: Task { visit })
            um.endUndoGrouping()
            XCTAssertEqual(um.undoActionName, FigureVisitUndo.actionName, "registered at once")
            await step?.settled?.value
        }
        XCTAssertFalse(um.canUndo, "removed once the visit is known")
        XCTAssertEqual(said, [FigureVisit.noUndoSentence])
    }

    // MARK: - The keyboard's own path

    /// **⌘Z with the grid focused, through `NSApp.sendEvent`**: the menu bar's
    /// Edit ▸ Undo reaches the grid's stack, never the manuscript's. Needs
    /// the host active with the grid's window key — with no key window `NSApp`
    /// sends the menu's action nowhere this window can hear — so a run that
    /// may not activate skips by name; the walk is pinned above on every run.
    func test_commandZThroughTheApplicationReachesTheGridsStack() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        typeCell(m, c, cell(c, 1, 1), "8")
        await c.settleWrites()
        _ = await TestWindow.activate(m.window)
        guard NSApp.keyWindow === m.window else {
            throw XCTSkip("the grid's window is not the app's key window (active: \(NSApp.isActive), "
                          + "activation allowed: \(TestWindow.activationAllowed)): NSApp.sendEvent "
                          + "sends Edit ▸ Undo to no responder of this window. CI's runner measures it.")
        }
        XCTAssertTrue(m.window.firstResponder === c.gridView, "premise: the grid has the keys")
        let text = m.textView.string
        NSApp.sendEvent(key(m, "z", code: 6, .command))
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[cell(c, 1, 1)], "⌘Z undid the grid's write")
        XCTAssertEqual(m.textView.string, text)
    }
}
