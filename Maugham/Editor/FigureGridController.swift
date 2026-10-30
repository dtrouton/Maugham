import AppKit
import Observation
import MaughamCore

/// **One visit to a table figure's grid** (report plan 7c Task 5): the
/// host (`FigureGridHost` — a figure's `FigureDocument`), the pure
/// `FigureGridModel` (selection, edit state, keys), the `FigureGridValues` holder (computed values and cached strings), the
/// `FigureGridView` and its `FigureGridBars`.
///
/// - **The only grid file that calls a figure mutator** (tripwire 52 counts
///   this file's calls in `manuscriptWriterCallSites`): a cell through
///   `setCell`, a range (⌫, a format, decimals, align, Σ) through `setCells`
///   — one ⌘Z and one render however many cells — the structure verbs, and
///   a batch planned against the host (a delete of several rows or columns,
///   a paste) through `applyChanges`.
///   Each registers on the grid's own `gridUndo` (plan 7d Task 6): ⌘Z and
///   ⇧⌘Z in the grid, its bars and its cell editor run that stack, never
///   the window's (`undoInGrid`/`redoInGrid`); an in-place visit's steps
///   are collapsed into one window step when it folds (the coordinator's).
/// - **It observes `host.state`** (`withObservationTracking`; the coordinator
///   never does, tripwire 6) and advances the values incrementally, repainting
///   the visible cells that changed; a `figureCardVersion` edge reseeds
///   (`figureCardsChanged`).
/// - Writes run one after another, in the order asked; a refusal is said as
///   a notice (a sort says its own).
/// - **The caption** is text, so it is committed by the coordinator through
///   Route A (`Line.commitCaption`, membrane-gated); **the name** through
///   `ProjectStore.renameFigure`, whose refusal is said and the field put back.
/// - **Read-only** (Task 8, `FigureGridGate`): the coordinator sets the mode;
///   a read-only grid selects and scrolls, its bars disabled, and a key or
///   act that would change the figure is answered with the reason line and
///   writes nothing. A write the host refuses mid-visit is said, the cell
///   shows the host's value again, and `onAccessMayHaveChanged` has the gate
///   asked again — as does any change of the figure's drawn posture (a
///   trust change, *Edit Anyway*), card or no card.
/// - **The table commands** (Task 9, `FigureGridMenu.swift`): Format ▸ Table
///   and the right-click menu reach `performTableCommand`, which asks
///   `menuState` first; the menu state is told (`onMenuStateChange`) only
///   when it changes.
/// - **Cut, copy and paste** (plan 7d Task 3, `FigureGridClipboard`): a copy
///   writes the selection's cells and display text; a paste puts the block at
///   the selection's top-left (tiling a selection that is a whole multiple of
///   it), growing the table past its edge, as one visit and one ⌘Z; a cut is
///   a copy and a clear. A read-only grid copies, and answers a cut or paste
///   with the reason line.
/// - **Its frame** (plan 7d Task 9): the same visit mounts in place (the
///   coordinator's) or in a figure window (`FigureWindowGrid`); the frame
///   sets `onOpenInWindow` (⤢, shown only when set), `onSendToResearch`
///   (the fold before a send) and `researchPiece`.
/// - **Send to Research** (R7d-7): the grid's frame folds it first (an open
///   edit committed or said), then the figure is parked through
///   `ProjectStore.sendToResearch` in turn behind every write asked before —
///   no ⌘Z (ruling P-8), no alert; a refusal is said.
/// - **Fill and import** (plan 7d Task 4): Fill Down (⌘D, the menu item) and
///   Fill Right (⌘R while the grid has the keys, R7d-1) write `FigureFill`'s
///   cells as one ⌘Z; Import from CSV… matches the file onto the table
///   (`FigureGridImport`, R7d-8) and writes it through `applyChanges` as one
///   ⌘Z. A read-only grid answers each with the reason line.
@MainActor
final class FigureGridController: FigureGridDataSource, FigureGridViewDelegate, FigureGridBarsDelegate {

    /// What the bottom bar shows of the figure line, and how its caption is written.
    struct Line {
        /// "Table 2".
        var number: String
        var caption: String
        /// Writes the line's caption (the coordinator's `replaceFigureCaption`,
        /// Route A); answers false when it was not written.
        var commitCaption: @MainActor (String) -> Bool
    }

    let host: any FigureGridHost
    let gridView: FigureGridView
    let bars = FigureGridBars()
    var figureId: String { host.figureId }

    private let values: FigureGridValues
    private(set) var model: FigureGridModel
    private weak var store: DocumentStore?
    private weak var projectStore: ProjectStore?
    private var names: FormulaNames
    private(set) var line: Line
    private(set) var name: String
    /// **The grid's private undo stack** (plan 7d Task 6, ADR 0023's
    /// exception): every write this visit makes registers here; the
    /// window's stack never sees a grid step while the grid is open.
    let gridUndo = UndoManager()

    /// Told when the grid folds (Esc on a selected cell, Done).
    var onFold: (() -> Void)?
    /// Told after the host refused a write (the figure's door, a park, a
    /// close) and when the figure's drawn posture changed: the coordinator
    /// asks the gate again.
    var onAccessMayHaveChanged: (() -> Void)?
    /// The re-ask a posture change scheduled (a test awaits it).
    private(set) var postureChange: Task<Void, Never>?
    /// Told when what the table commands may do changes (the coordinator
    /// sets the window's `FigureGridPresence`).
    var onMenuStateChange: ((FigureTableMenuState) -> Void)?
    /// What the table commands may do now, last told.
    private(set) var menuState = FigureTableMenuState()
    /// The right-click menu's items' target.
    private let menuTarget = FigureTableMenuTarget()

    /// ⤢ was pressed (plan 7d Task 9); nil where the grid cannot open in a
    /// window, which hides the button — as does a host that offers no window
    /// (`FigureGridOffers.openInWindow`).
    var onOpenInWindow: (() -> Void)? {
        didSet { bars.openInWindow.isHidden = onOpenInWindow == nil || !host.offers.openInWindow }
    }
    /// Send to Research was chosen: the frame folds the grid (forced) before
    /// the send is asked (R7d-7).
    var onSendToResearch: (() -> Void)?
    /// That send was refused (after `onSendToResearch` folded the grid): the
    /// frame that let the figure go may take it again.
    var onSendRefused: (() -> Void)?
    /// Esc with nothing to cancel folds the grid — in place. A figure
    /// window sets this false: there Esc does nothing (Done or ⌘W closes it).
    var foldsOnEscape = true
    /// The piece whose Research Send to Research puts the table in by
    /// default; nil offers Shared alone.
    var researchPiece: String? {
        didSet { refreshMenuState() }
    }

    /// What the gate last said (`.editable` or `.readOnly`; at `.noExpand`
    /// the coordinator folds instead), and whether the caption, the line's
    /// text, may be changed (R7c-6).
    private(set) var mode: FigureGridGate.Mode = .editable
    private(set) var captionMayEdit = true

    /// Where the open edit is being typed: the cell editor or the formula bar.
    private enum EditSource { case cell, bar }
    private var editSource: EditSource = .cell

    /// The last write asked for; each awaits the one before it.
    private var writes: Task<Void, Never>?
    /// Writes asked for and not yet landed (an undo or redo among them).
    private(set) var writesInFlight = 0
    private var isClosed = false

    /// The pasteboard cut, copy and paste use: the general one; a test sets
    /// a private one (never the general pasteboard in a test).
    var pasteboard: NSPasteboard = .general

    /// Test seam: runs as each write's turn comes, before it reads the host —
    /// where a test lands a change made elsewhere.
    static var writeTurnForTesting: (@MainActor () async -> Void)?
    /// Test seam: runs between a batch's plan and its write
    /// (`applyPlanned`) — where a test lands a change that moves the table
    /// under the plan.
    static var afterPlanForTesting: (@MainActor () async -> Void)?

    // MARK: Opening

    /// **Open a visit** on `figureId`'s table through the window's store: its
    /// host (`DocumentStore.openFigure`), the book's language and names, and
    /// the values seeded from the whole book once.
    static func open(
        figureId: String, store: DocumentStore, projectStore: ProjectStore,
        typography: TypographySettings, line: Line
    ) async throws -> FigureGridController {
        let host = try await store.openFigure(figureId: figureId)
        let context = try await store.tableImportContext()
        let controller = FigureGridController(
            host: host, store: store, projectStore: projectStore, typography: typography,
            locale: context.locale, names: context.names, line: line)
        let repaint = try await controller.values.reseed()
        controller.gridView.repaint(repaint)
        return controller
    }

    private init(host: any FigureGridHost, store: DocumentStore, projectStore: ProjectStore,
                 typography: TypographySettings, locale: TableLocale, names: FormulaNames, line: Line) {
        self.host = host
        self.store = store
        self.projectStore = projectStore
        self.names = names
        self.line = line
        name = projectStore.manifest.figures?.first { $0.id == host.figureId }?.name ?? ""
        values = FigureGridValues(figureId: host.figureId, state: host.state, locale: locale, store: store)
        gridView = FigureGridView(typography: typography)
        // A placeholder first, so the real model's closure may capture `self`.
        model = FigureGridModel(table: host.state.table, editText: { _ in "" })
        model = FigureGridModel(table: host.state.table, editText: { [weak self] in self?.barText(for: $0) ?? "" })
        gridView.dataSource = self
        gridView.delegate = self
        bars.delegate = self
        menuTarget.onCommand = { [weak self] in self?.performTableCommand($0) }
        bars.showLine(number: line.number, caption: line.caption, name: name)
        // The bottom bar's figure fields, only where the host offers them.
        bars.nameField.isHidden = !host.offers.nameField
        bars.captionField.isHidden = !host.offers.caption
        refreshBars()
        observeHost()
        observeTheDoor()
    }

    /// **End the visit**: stop observing the host. The host stays the window's.
    func close() {
        isClosed = true
    }

    /// The grid is no longer on screen (the coordinator folded it); writes
    /// still in flight land, but one that no longer reads is said as a
    /// notice, never reopened in a grid nobody sees.
    private(set) var isFolded = false
    func didFold() { isFolded = true }

    /// **Fold, asked from outside the grid** (the coordinator's
    /// `foldFigureGrid(commit:)`): an open edit committed or discarded as
    /// `commit` says (R7c-8), then `onFold`. A commit that will not read
    /// keeps the grid open with its error shown, and `onFold` is not called.
    func fold(commit: Bool) {
        syncFromHost()
        commitPendingFields()
        execute(model.fold(commit: commit))
    }

    /// **A fold that cannot be refused** (the figure line gone, the editor
    /// torn down): an open edit that reads is committed; one that will not
    /// is said as a notice carrying its text, then discarded (R7c-8).
    func foldForced() {
        commitPendingFields()
        if let open = unreadableOpenEdit() {
            sayUnwritten(open.text, at: open.cell, open.error.message)
            execute(model.fold(commit: false))
        } else {
            execute(model.fold(commit: true))
        }
    }

    /// **The open edit, when committing it would be refused**: a formula
    /// that will not read, over the table as it is now. Nil with no edit
    /// open, or one that reads (or is unchanged, which writes nothing).
    func unreadableOpenEdit() -> (text: String, cell: CellKey, error: FormulaParseError)? {
        syncFromHost()
        let edit: FigureGridEdit
        switch model.edit {
        case .idle: return nil
        case .editing(let e), .composing(let e, _): edit = e
        }
        let table = values.table
        guard edit.text != barText(for: edit.cell),
              case .failure(let error) = FigureCellEntry.cell(
                from: edit.text, prior: table[edit.cell], table: table, names: names, locale: values.locale)
        else { return nil }
        return (edit.text, edit.cell, error)
    }

    /// **The text was refused the focus** over an edit that will not read:
    /// the edit opens again in its cell with the keys, the message shown and
    /// the caret at its offset, as a refused Return leaves it.
    func showOpenEditError() {
        guard !isClosed, !isFolded, let open = unreadableOpenEdit() else { return }
        if mode.readOnlyReason != nil {
            sayUnwritten(open.text, at: open.cell, open.error.message)
            execute(model.fold(commit: false).filter { $0 != .fold })
            return
        }
        editSource = .cell
        reopen(open.text, at: open.cell, open.error)
    }

    /// **A `figureCardVersion` edge**: another figure, a trust change or a
    /// rename may have changed what this one reads — assemble the book again
    /// and repaint what changed.
    func figureCardsChanged() async {
        if let context = try? await store?.tableImportContext() { names = context.names }
        guard let repaint = try? await values.reseed() else { return }
        gridView.repaint(repaint)
        refreshBars()
    }

    /// Every write asked for so far, landed (a test's and a fold's wait).
    func settleWrites() async {
        while let pending = writes {
            await pending.value
            if writes == pending { return }
        }
    }

    // MARK: The data source

    var figureGridTable: FigureTable { values.table }
    func figureGridDisplay(at key: CellKey) -> String { values.display(at: key) }
    func figureGridValue(at key: CellKey) -> CellValue { values.value(at: key) }
    var figureGridSelection: FigureGridSelection? { model.selection }
    var figureGridReference: FigureGridReference? {
        if case .composing(_, let reference) = model.edit { return reference }
        return nil
    }

    // MARK: Keys, clicks, the cell editor

    @discardableResult
    func figureGridView(_ view: FigureGridView, handle key: FigureGridKey) -> Bool {
        handle(key)
    }

    func figureGridView(_ view: FigureGridView, menuAt cell: CellKey?) -> NSMenu? {
        contextMenu(at: cell)
    }

    func figureGridView(_ view: FigureGridView, perform action: FigureGridClipboardAction) {
        switch action {
        case .cut: cutSelection()
        case .copy: copySelection()
        case .paste: paste()
        }
    }

    func figureGridView(_ view: FigureGridView, mayPerform action: FigureGridClipboardAction) -> Bool {
        mayPerform(action)
    }

    func figureGridViewFillRight(_ view: FigureGridView) {
        performTableCommand(.fillRight)
    }

    var figureGridUndoManager: UndoManager? { gridUndo }

    func figureGridView(_ view: FigureGridView, undo redo: Bool) {
        if redo { redoInGrid() } else { undoInGrid() }
    }

    func figureGridView(_ view: FigureGridView, undoItem redo: Bool) -> FigureGridUndoItem {
        undoItem(redo: redo)
    }

    func figureGridView(_ view: FigureGridView, didResizeColumn column: ColumnID, to width: CGFloat) {
        if let reason = mode.readOnlyReason { return answer(reason) }
        enqueue { [host, gridUndo] in
            try await host.setColumnWidth(column, Double(width), undoManager: gridUndo)
        }
    }

    /// **Feed one key to the model and do what it answers.** False when the
    /// key is the open cell editor's own.
    @discardableResult
    func handle(_ key: FigureGridKey) -> Bool {
        syncFromHost()
        if let reason = mode.readOnlyReason { return handleReadOnly(key, reason) }
        if case .editTextChanged(let text) = key {
            bars.clearError()
            if editSource == .cell { bars.setFormulaText(text) }
        }
        let effects = withoutAnEscapeFold(key, model.reduce(key))
        execute(effects)
        return effects != [.fieldEditorKeeps]
    }

    /// Esc's fold, dropped where Esc does not fold (`foldsOnEscape`).
    private func withoutAnEscapeFold(_ key: FigureGridKey, _ effects: [FigureGridEffect]) -> [FigureGridEffect] {
        guard !foldsOnEscape, case .escape = key else { return effects }
        return effects.filter { $0 != .fold }
    }

    // MARK: Read-only (Task 8)

    /// **The gate's answer for this visit** (the coordinator's). Read-only
    /// disables the bars that change the figure, shows the reason line and
    /// takes the column resize away; the caption follows `captionMayEdit`.
    /// Turning read-only over an open edit closes it, and typing that would
    /// have been written is said as a notice carrying its text.
    func setAccess(_ mode: FigureGridGate.Mode, captionMayEdit: Bool) {
        let reason = mode.readOnlyReason
        if let reason, self.mode.readOnlyReason == nil { closeOpenEdit(because: reason) }
        self.mode = mode
        self.captionMayEdit = captionMayEdit
        bars.setAccess(cellsMayEdit: reason == nil, captionMayEdit: captionMayEdit)
        bars.showReason(reason?.sentence)
        gridView.mayResizeColumns = reason == nil
        refreshMenuState()
    }

    /// A key on a read-only grid: one that only selects or scrolls is the
    /// model's as ever; one that would edit, clear or insert writes nothing
    /// and is answered with the reason line (a double-click still selects
    /// its cell).
    private func handleReadOnly(_ key: FigureGridKey, _ reason: FigureGridGate.Reason) -> Bool {
        if case .doubleClick(let cell) = key {
            execute(model.reduce(.click(cell, extend: false)))
            answer(reason)
            return true
        }
        var trial = model
        let effects = withoutAnEscapeFold(key, trial.reduce(key))
        if effects.contains(where: Self.changesTheFigure) {
            answer(reason)
            return true
        }
        model = trial
        execute(effects)
        return effects != [.fieldEditorKeeps]
    }

    // MARK: Undo (plan 7d Task 6)

    /// **⌘Z at the grid** — the grid, its bars or its cell editor having the
    /// keys. Typing still open (a cell's, the formula bar's, a caption or
    /// name changed and not yet committed) is cancelled as Esc cancels it
    /// (R7d-4): no field keeps an undo history the writer can reach. A
    /// read-only grid refuses with the reason line (R7d-11). Otherwise the
    /// grid's last step is taken back, in turn behind every write asked
    /// before it, so a ⌘Z never takes back the step under one still landing.
    func undoInGrid() { runUndo(redo: false) }

    /// **⇧⌘Z at the grid**: the last step undone is put back; refused, as
    /// ⌘Z is, on a read-only grid; nothing while typing is open (its item is
    /// disabled then).
    func redoInGrid() { runUndo(redo: true) }

    private func runUndo(redo: Bool) {
        syncFromHost()
        if let reason = mode.readOnlyReason { return answer(reason) }
        if hasOpenTyping {
            if !redo { cancelOpenTyping() }
            return
        }
        enqueue { [host, gridUndo] in
            await host.awaitPendingUndoWork()
            if redo {
                if gridUndo.canRedo { gridUndo.redo() }
            } else if gridUndo.canUndo {
                gridUndo.undo()
            }
            await host.awaitPendingUndoWork()
        }
    }

    /// **What Edit ▸ Undo and Redo say at the grid**: "Undo Typing" over open
    /// typing (Redo off), else the grid stack's own titles ("Undo Sort
    /// Ascending"), enabled while that stack has a step — on a read-only grid
    /// too, so the press is answered with the reason line, not a beep.
    func undoItem(redo: Bool) -> FigureGridUndoItem {
        if hasOpenTyping {
            return redo ? FigureGridUndoItem(enabled: false, title: gridUndo.redoMenuTitle(forUndoActionName: ""))
                : FigureGridUndoItem(enabled: true, title: gridUndo.undoMenuTitle(forUndoActionName: "Typing"))
        }
        return redo ? FigureGridUndoItem(enabled: gridUndo.canRedo, title: gridUndo.redoMenuItemTitle)
            : FigureGridUndoItem(enabled: gridUndo.canUndo, title: gridUndo.undoMenuItemTitle)
    }

    /// An edit open in a cell or the formula bar, or a caption or name typed
    /// and not yet committed.
    private var hasOpenTyping: Bool {
        if case .idle = model.edit { return bars.hasUncommittedFieldEdit }
        return true
    }

    private func cancelOpenTyping() {
        if case .idle = model.edit {
            bars.cancelFieldEdit()
            gridView.window?.makeFirstResponder(gridView)   // the keys stay the grid's
            return
        }
        bars.clearError()
        execute(model.reduce(.escape))
    }

    /// The reason line, said again.
    private func answer(_ reason: FigureGridGate.Reason) {
        bars.showReason(reason.sentence)
    }

    /// The edit open when the grid turned read-only: closed; changed typing
    /// is said with the reason, so it is never lost.
    private func closeOpenEdit(because reason: FigureGridGate.Reason) {
        let edit: FigureGridEdit
        switch model.edit {
        case .idle: return
        case .editing(let e), .composing(let e, _): edit = e
        }
        if edit.text != barText(for: edit.cell) {
            let address = FigureGridAddress.string(from: edit.cell, to: edit.cell, in: values.table)
                .map { " in \($0)" } ?? ""
            MaughamEvent.postNotice("Couldn't write “\(edit.text)”\(address) — \(reason.sentence)",
                                    projectURL: host.projectURL)
        }
        bars.clearError()
        execute(model.reduce(.escape))
    }

    /// The model's effects that change the figure.
    private static func changesTheFigure(_ effect: FigureGridEffect) -> Bool {
        switch effect {
        case .beginEdit, .commitEdit, .insertReference, .clear, .insertRow, .insertColumn: return true
        case .moveSelection, .extendSelection, .scrollTo, .cancelEdit, .fold, .fieldEditorKeeps: return false
        }
    }

    /// The bars' acts that change the figure (the caption is the text's).
    private static func changesTheFigure(_ action: FigureGridBarAction) -> Bool {
        switch action {
        case .formulaTextChanged, .format, .decimals, .align, .headerRow, .totalRow, .sum, .name: return true
        case .formulaCommand, .caption, .done, .openInWindow: return false
        }
    }

    // MARK: The bars

    @discardableResult
    func figureGridBars(_ bars: FigureGridBars, perform action: FigureGridBarAction) -> Bool {
        perform(action)
    }

    /// **What a bar asked for.** The toolbar's verbs act on the selection.
    @discardableResult
    func perform(_ action: FigureGridBarAction) -> Bool {
        syncFromHost()
        if let reason = mode.readOnlyReason, Self.changesTheFigure(action) {
            answer(reason)
            refreshBars(force: true)
            bars.nameField.stringValue = name
            return true
        }
        if case .caption = action, !captionMayEdit {
            bars.captionField.stringValue = line.caption
            return true
        }
        switch action {
        case .formulaTextChanged(let text): formulaBarChanged(text)
        case .formulaCommand(let key): return formulaBarCommand(key)
        case .format(let choice): restyle("Format Cells") { $0.format.number = choice.applied(to: $0.format.number) }
        case .decimals(let delta):
            restyle(delta > 0 ? "More Decimal Places" : "Fewer Decimal Places") {
                $0.format.number = FigureGridFormatting.decimals($0.format.number, by: delta)
            }
        case .align(let alignment): restyle("Align Cells") { $0.alignment = alignment }
        case .headerRow(let on):
            enqueue { [host, gridUndo] in try await host.setHeaderRows(on ? 1 : 0, undoManager: gridUndo) }
        case .totalRow(let on):
            enqueue { [host, gridUndo] in try await host.setTotalRow(on, undoManager: gridUndo) }
        case .sum: sumAbove()
        case .caption(let caption): commitCaption(caption)
        case .name(let newName): commitName(newName)
        case .done:
            commitPendingFields()
            execute(model.fold(commit: true))
        case .openInWindow:
            if host.offers.openInWindow { onOpenInWindow?() }
        }
        return true
    }

    /// **The bottom bar's typing, written before the grid goes** (final
    /// review I1): a click on Done takes no focus, so the caption or name
    /// field may still be open when a fold removes it. Its text is committed
    /// now, while the expansion is current — the formula bar's edit is the
    /// model's, which the fold commits. A caption that is refused (the line
    /// gone under a forced fold, the membrane) is said as a notice carrying
    /// its text, as an unreadable cell is.
    func commitPendingFields() {
        let fieldHadKeys = bars.captionField.currentEditor() != nil || bars.nameField.currentEditor() != nil
        let pending = bars.takePendingEdits()
        // The keys stay the grid's, so the fold hands them to the text.
        if fieldHadKeys { gridView.window?.makeFirstResponder(gridView) }
        if let caption = pending.caption {
            if captionMayEdit, host.offers.caption, line.commitCaption(caption) {
                line.caption = FigureIngest.keptCaption(caption)
            } else {
                MaughamEvent.postNotice("Couldn't write the caption “\(caption)” to the figure line.",
                                        projectURL: host.projectURL)
            }
            bars.showLine(number: line.number, caption: line.caption, name: name)
        }
        if let newName = pending.name {
            if mode.readOnlyReason == nil { commitName(newName) } else { bars.nameField.stringValue = name }
        }
    }

    /// **The figure line's number or caption changed in the text** (an undo,
    /// a sync, a figure line added above): the bottom bar follows, a field
    /// the writer is typing in left alone (final review I2).
    func refreshLine(number: String, caption: String) {
        guard number != line.number || caption != line.caption else { return }
        line.number = number
        line.caption = caption
        bars.showLine(number: number, caption: caption, name: name)
    }

    // MARK: The table commands (Task 9)

    /// **A Format ▸ Table or right-click command**, asked of `menuState`
    /// first: one it does not enable does nothing (on a read-only grid, the
    /// reason line is said). The toolbar's acts go the bars' way; the inserts
    /// go to the model (an open edit committed first, as Tab would); a delete,
    /// move or sort commits an open edit first, and does nothing when that
    /// edit will not read (its error shown, R7c-8).
    func performTableCommand(_ command: FigureTableCommand) {
        syncFromHost()
        refreshMenuState()
        guard menuState.isEnabled(command) else {
            if let reason = mode.readOnlyReason { answer(reason) }
            return
        }
        switch command {
        case .format(let choice): perform(.format(choice))
        case .fewerDecimals: perform(.decimals(-1))
        case .moreDecimals: perform(.decimals(1))
        case .align(let alignment): perform(.align(alignment))
        case .headerRow: perform(.headerRow(!menuState.header))
        case .totalRow: perform(.totalRow(!menuState.total))
        case .sum: perform(.sum)
        case .insertRowAbove: handle(.insert(.up))
        case .insertRowBelow: handle(.insert(.down))
        case .insertColumnLeft: handle(.insert(.left))
        case .insertColumnRight: handle(.insert(.right))
        case .deleteRows, .deleteColumns, .moveRowsUp, .moveRowsDown, .moveColumnsLeft, .moveColumnsRight,
             .sortAscending, .sortDescending:
            guard commitOpenEdit(), let block = selectedBlock() else { return }
            restructure(command, block)
        case .fillDown:
            guard commitOpenEdit() else { return }
            fill(.down)
        case .fillRight:
            guard commitOpenEdit() else { return }
            fill(.right)
        case .importCSV:
            guard commitOpenEdit() else { return }
            chooseFileToImport()
        case .sendTo(let destination):
            sendFigureToResearch(destination)
        }
    }

    /// **Send the figure to Research** (R7d-7): the frame folds the grid
    /// first — forced, so an open edit that reads is committed and one that
    /// will not is said — then the park is asked in turn behind every write
    /// before it, so what the writer typed goes with the figure. Not
    /// undoable (ruling P-8; the fold registers no step); a refusal is said
    /// and told (`onSendRefused`).
    private func sendFigureToResearch(_ destination: FigureResearchDestination) {
        guard host.offers.sendToResearch else { return }
        let scope: ResearchScope
        switch destination {
        case .piece:
            guard let researchPiece else { return }
            scope = .document(researchPiece)
        case .shared:
            scope = .shared
        }
        onSendToResearch?()
        enqueue { [weak self, projectStore, figureId] in
            guard let projectStore else { return }
            do { _ = try await projectStore.sendToResearch(figureId: figureId, scope: scope) } catch {
                self?.onSendRefused?()   // the figure stays: the frame may take it again
                throw error
            }
        }
    }

    /// **The right-click menu** over `cell` (nil off the cells): a cell
    /// outside the selection is selected first, as a click would; the items
    /// are `FigureTableMenu`'s, enabled by `menuState`. While a cell edit is
    /// open the selection is left on the edit's cell — a click there would
    /// compose a reference, not select — so the menu acts on the edit's cell
    /// (each command commits the edit first).
    func contextMenu(at cell: CellKey?) -> NSMenu {
        syncFromHost()
        if let cell, case .idle = model.edit,
           !(model.selection?.cells(in: values.table).contains(cell) ?? false) {
            handle(.click(cell, extend: false))
        }
        refreshMenuState()
        return FigureTableMenu.contextMenu(state: menuState, target: menuTarget)
    }

    /// The menu state over the table, the selection and the gate; told only on a change.
    private func refreshMenuState() {
        let next = FigureTableMenuState.of(table: values.table, selection: model.selection, mode: mode,
                                           knowsItsPiece: researchPiece != nil,
                                           maySend: host.offers.sendToResearch)
        guard next != menuState else { return }
        menuState = next
        onMenuStateChange?(next)
    }

    /// An open edit committed, as a fold would (without folding): false — and
    /// the edit reopened with its error — when it will not read.
    private func commitOpenEdit() -> Bool {
        guard case .idle = model.edit else {
            execute(model.fold(commit: true).filter { $0 != .fold })
            if case .idle = model.edit { return true }
            return false
        }
        return true
    }

    /// The selection's rows and columns, by id and position, top-left first.
    private struct Block {
        var rows: [RowID]
        var columns: [ColumnID]
        var firstRow: Int, lastRow: Int, firstColumn: Int, lastColumn: Int
    }

    private func selectedBlock() -> Block? {
        let table = values.table
        guard let selection = model.selection,
              let ar = table.rowIndex(of: selection.anchor.row), let fr = table.rowIndex(of: selection.focus.row),
              let ac = table.columnIndex(of: selection.anchor.column),
              let fc = table.columnIndex(of: selection.focus.column) else { return nil }
        let (r0, r1, c0, c1) = (min(ar, fr), max(ar, fr), min(ac, fc), max(ac, fc))
        return Block(rows: Array(table.rows[r0...r1]), columns: Array(table.columns[c0...c1]),
                     firstRow: r0, lastRow: r1, firstColumn: c0, lastColumn: c1)
    }

    /// **Delete, move or sort** through the host, each behind its own door.
    ///
    /// - A delete takes every selected row (column) as one visit
    ///   (`applyChanges`): one render, one ⌘Z.
    /// - A move shifts the selected block one place by moving its neighbour
    ///   across it (one `moveRow`/`moveColumn`, one ⌘Z); the selection rides
    ///   its ids. References follow their ids, as an Excel cut-and-insert
    ///   does (Task 1's ledger).
    /// - A sort orders the body by the active cell's column, its values as
    ///   the grid shows them (`sortRows`, which says its own refusal).
    private func restructure(_ command: FigureTableCommand, _ block: Block) {
        let table = values.table
        switch command {
        case .deleteRows:
            enqueue { [weak self, host, gridUndo] in
                var rows: [RowID] = []
                do {
                    try await Self.applyPlanned(
                        on: host, actionName: block.rows.count == 1 ? "Delete Row" : "Delete Rows",
                        undoManager: gridUndo
                    ) { state in
                        rows = block.rows.filter { state.table.rowIndex(of: $0) != nil }
                        return rows.map { row in
                            FigureReturnDiff.Change(kind: .figureStructure, payload: FigureOpPayload(
                                structure: .deleteRow(row), removed: state.removedSlice(row: row)))
                        }
                    }
                } catch {
                    let deleted = Self.deletedBeforeFailure(rows, error) { host.state.table.rowIndex(of: $0) == nil }
                    self?.sayPartlyDeleted(deleted, of: rows.count, "rows")
                    throw error
                }
            }
        case .deleteColumns:
            enqueue { [weak self, host, gridUndo] in
                var columns: [ColumnID] = []
                do {
                    try await Self.applyPlanned(
                        on: host, actionName: block.columns.count == 1 ? "Delete Column" : "Delete Columns",
                        undoManager: gridUndo
                    ) { state in
                        columns = block.columns.filter { state.table.columnIndex(of: $0) != nil }
                        return columns.map { column in
                            FigureReturnDiff.Change(kind: .figureStructure, payload: FigureOpPayload(
                                structure: .deleteColumn(column), removed: state.removedSlice(column: column)))
                        }
                    }
                } catch {
                    let deleted = Self.deletedBeforeFailure(columns, error) {
                        host.state.table.columnIndex(of: $0) == nil
                    }
                    self?.sayPartlyDeleted(deleted, of: columns.count, "columns")
                    throw error
                }
            }
        case .moveRowsUp:
            let above = table.rows[block.firstRow - 1]
            enqueue { [host, gridUndo] in
                try await host.moveRow(above, after: block.rows.last, undoManager: gridUndo)
            }
        case .moveRowsDown:
            let below = table.rows[block.lastRow + 1]
            let after = block.firstRow == 0 ? nil : table.rows[block.firstRow - 1]
            enqueue { [host, gridUndo] in
                try await host.moveRow(below, after: after, undoManager: gridUndo)
            }
        case .moveColumnsLeft:
            let left = table.columns[block.firstColumn - 1]
            enqueue { [host, gridUndo] in
                try await host.moveColumn(left, after: block.columns.last, undoManager: gridUndo)
            }
        case .moveColumnsRight:
            let right = table.columns[block.lastColumn + 1]
            let after = block.firstColumn == 0 ? nil : table.columns[block.firstColumn - 1]
            enqueue { [host, gridUndo] in
                try await host.moveColumn(right, after: after, undoManager: gridUndo)
            }
        case .sortAscending, .sortDescending:
            guard let column = model.selection?.anchor.column else { return }
            let ascending = command == .sortAscending
            enqueue { [weak self, host, gridUndo] in
                try await host.sortRows(
                    by: column, ascending: ascending, values: { self?.values.value(at: $0) ?? .empty },
                    actionName: ascending ? "Sort Ascending" : "Sort Descending", undoManager: gridUndo)
            }
        default:
            break
        }
    }

    /// **A batch planned against the host as its turn comes** (plan 7d
    /// Task 2's review M1): planned after any ⌘Z still landing has landed, and
    /// planned once more when the host refuses it because the table changed
    /// between the plan and the write (another device, an undo's last hop).
    /// `plan` answers nil to write nothing (it has said why).
    static func applyPlanned(
        on host: any FigureGridHost, actionName: String, undoManager: UndoManager?,
        plan: (FigureState) -> [FigureReturnDiff.Change]?
    ) async throws {
        for attempt in 0..<2 {
            await host.awaitPendingUndoWork()
            let state = host.state
            guard let changes = plan(state), !changes.isEmpty else { return }
            await afterPlanForTesting?()
            do {
                try await host.applyChanges(changes, expecting: state, actionName: actionName, undoManager: undoManager)
                return
            } catch is FigureEditInvalid where attempt == 0 && host.state != state {
                continue   // the table moved under the plan: plan again
            }
        }
    }

    /// **How many of a batch's deletes landed before it failed** (plan 7d
    /// Task 2's review M2): none when it was refused before writing (it did
    /// not fit the table as it is, or a door said no) — a row another device
    /// deleted is not this batch's; else the run of `planned` gone from the
    /// front, since the batch writes in order.
    static func deletedBeforeFailure<ID>(_ planned: [ID], _ error: Error, isGone: (ID) -> Bool) -> Int {
        if error is FigureEditInvalid || error is FigureEditRefused || error is FigureParkedRefused
            || error is DocumentNotWritableError { return 0 }
        return planned.prefix(while: isGone).count
    }

    /// A delete of several rows (columns) whose append failed part way: what
    /// landed is said (its one ⌘Z takes it back; the failure says itself).
    private func sayPartlyDeleted(_ deleted: Int, of count: Int, _ what: String) {
        guard deleted > 0 else { return }
        MaughamEvent.postNotice("Only \(deleted) of the \(count) \(what) were deleted.", projectURL: host.projectURL)
    }

    /// The writer typed in the formula bar: it edits the active cell (an edit
    /// opened there if none is, or moved there from the cell editor).
    private func formulaBarChanged(_ text: String) {
        bars.clearError()
        switch model.edit {
        case .idle:
            editSource = .bar
            execute(model.reduce(.editInPlace))
            // No edit opened (nothing to edit): the bar is not the edit's.
            if case .idle = model.edit {
                editSource = .cell
                return
            }
        case .editing, .composing:
            if editSource == .cell {
                editSource = .bar
                gridView.endEditing()
            }
        }
        execute(model.reduce(.editTextChanged(text)))
    }

    /// Return, Tab or Esc in the formula bar: the grid's keys for the open
    /// edit; with none open, the bar shows the cell again and the grid takes the keys.
    private func formulaBarCommand(_ key: FigureGridKey) -> Bool {
        if case .idle = model.edit {
            bars.clearError()
            refreshBars(force: true)
            gridView.window?.makeFirstResponder(gridView)
            return true
        }
        editSource = .bar
        execute(model.reduce(key))
        return true
    }

    // MARK: Effects

    private func execute(_ effects: [FigureGridEffect]) {
        defer { refreshBars() }
        for effect in effects {
            switch effect {
            case .moveSelection, .extendSelection:
                gridView.reloadData()
            case .scrollTo(let key):
                gridView.scrollTo(key)
            case .beginEdit(let cell, let text):
                // Begun in the formula bar, the bar already holds what is typed.
                if editSource == .cell {
                    gridView.beginEditing(cell, text: text)
                    bars.setFormulaText(text)
                }
            case .commitEdit(let cell, let text):
                // A refused commit (a formula that will not read) reopens the
                // edit and ends the list: nothing after it (a move, a fold) runs.
                guard commit(text, to: cell) else { return }
            case .cancelEdit:
                bars.clearError()
                endEdit()
            case .insertReference(_, let editText):
                if editSource == .cell { gridView.setEditingText(editText) }
                bars.setFormulaText(editText)
                gridView.reloadData()
            case .clear(let keys):
                clear(keys)
            case .insertRow(let after):
                enqueue { [weak self, host, gridUndo] in
                    let id = try await host.insertRow(after: after, undoManager: gridUndo)
                    self?.selectInserted { CellKey(row: id, column: $0.column) }
                }
            case .insertColumn(let after):
                enqueue { [weak self, host, gridUndo] in
                    let id = try await host.insertColumn(after: after, undoManager: gridUndo)
                    self?.selectInserted { CellKey(row: $0.row, column: id) }
                }
            case .fold:
                onFold?()
            case .fieldEditorKeeps:
                break
            }
        }
    }

    /// The host just inserted a row or column: catch up with it, then select
    /// the new one beside the active cell.
    private func selectInserted(_ cell: (CellKey) -> CellKey) {
        syncFromHost()
        guard let active = model.selection?.anchor else { return }
        execute(model.select(cell(active)))
    }

    /// Close whichever field the edit was typed in; the grid takes the keys
    /// back if that field still had them — not when it has already given
    /// them up to the text, whose taking the focus is folding the grid.
    private func endEdit() {
        gridView.endEditing()
        if editSource == .bar {
            editSource = .cell
            if bars.formulaField.currentEditor() != nil { gridView.window?.makeFirstResponder(gridView) }
        }
    }

    /// **Commit `text` to `cell`**, read the way typing is (`FigureCellEntry`).
    /// Unchanged text writes nothing (a date in General, an error value, would
    /// not read back as the same cell). A formula that will not read reopens
    /// the edit with its message shown and the caret at its offset, writes
    /// nothing, and answers false.
    private func commit(_ text: String, to cell: CellKey) -> Bool {
        let table = values.table
        if text == barText(for: cell) {
            endEdit()
            return true
        }
        switch FigureCellEntry.cell(from: text, prior: table[cell], table: table, names: names, locale: values.locale) {
        case .failure(let error):
            reopen(text, at: cell, error)
            return false
        case .success:
            bars.clearError()
            endEdit()
            // Read again when its turn comes, over the cell as the host then holds it.
            let (names, locale) = (names, values.locale)
            enqueue { [weak self, host, gridUndo] in
                let table = host.state.table
                switch FigureCellEntry.cell(from: text, prior: table[cell], table: table, names: names, locale: locale) {
                case .success(let next):
                    try await host.setCell(next, at: cell, undoManager: gridUndo)
                case .failure(let error):
                    // The table changed under it (a column it names deleted
                    // elsewhere): the typing is never dropped (R7c-8).
                    self?.reopenDrifted(text, at: cell, error)
                }
            }
            return true
        }
    }

    /// A formula that will not read: the edit opens again on its cell holding
    /// `text`, the message shown, the caret at its offset (in UTF-16).
    private func reopen(_ text: String, at cell: CellKey, _ error: FormulaParseError) {
        execute(model.reopenEdit(cell: cell, text: text))
        bars.showError(error.message)
        let caret = NSRange(location: FigureGridFormatting.utf16Offset(ofCharacter: error.offset, in: text), length: 0)
        let field = editSource == .bar ? bars.formulaField : gridView.cellEditor
        field.currentEditor()?.selectedRange = caret
    }

    /// **A commit that read when asked but not at its turn** (the table
    /// changed meanwhile): reopened like a fresh parse error when the grid is
    /// free; when the writer is already editing elsewhere, or the cell is
    /// gone, said as a notice that carries the text, so it is never lost.
    private func reopenDrifted(_ text: String, at cell: CellKey, _ error: FormulaParseError) {
        syncFromHost()
        // A grid turned read-only meanwhile reopens nothing (review M5).
        if !isFolded, mode.readOnlyReason == nil, case .idle = model.edit,
           values.table.rowIndex(of: cell.row) != nil, values.table.columnIndex(of: cell.column) != nil {
            editSource = .cell
            reopen(text, at: cell, error)
            return
        }
        sayUnwritten(text, at: cell, error.message)
    }

    /// A notice that carries typing the grid could not write, so it is never
    /// lost; the address read in `table` (the one the cell was in).
    private func sayUnwritten(_ text: String, at cell: CellKey, in table: FigureTable? = nil, _ why: String) {
        let address = FigureGridAddress.string(from: cell, to: cell, in: table ?? values.table)
            .map { " in \($0)" } ?? ""
        MaughamEvent.postNotice("Couldn't write “\(text)”\(address) — \(why).", projectURL: host.projectURL)
    }

    /// ⌫ over the selection (or a cut's clear): each cell emptied as typing
    /// nothing would (a chosen format kept), as one ⌘Z.
    private func clear(_ keys: [CellKey], actionName: String = "Clear Cells") {
        let (names, locale) = (names, values.locale)
        write(keys, actionName: actionName) { prior, _, table in
            guard prior != nil, case .success(let cleared) = FigureCellEntry.cell(
                from: "", prior: prior, table: table, names: names, locale: locale) else { return .none }
            return .some(cleared)
        }
    }

    /// The toolbar's format, decimals or alignment over every selected cell —
    /// an empty one too, so what is typed there later takes it — as one ⌘Z.
    private func restyle(_ actionName: String, _ change: @escaping (inout Cell) -> Void) {
        guard let selection = model.selection else { return }
        write(selection.cells(in: values.table), actionName: actionName) { prior, _, _ in
            var cell = prior ?? Cell(content: .value(.empty))
            change(&cell)
            return .some(cell)
        }
    }

    /// **Σ**: each cell of the selection's bottom row takes `SUM` over its
    /// column above it, from the first row under the header — one ⌘Z. A cell
    /// with nothing above it in the body is left.
    private func sumAbove() {
        let table = values.table
        guard let selection = model.selection, let anchor = table.rowIndex(of: selection.anchor.row),
              let focus = table.rowIndex(of: selection.focus.row) else { return }
        let bottom = max(anchor, focus), first = table.headerRows
        guard bottom > first else { return }
        var sums: [CellKey: String] = [:]
        for key in selection.cells(in: table) where key.row == table.rows[bottom] {
            let top = CellKey(row: table.rows[first], column: key.column)
            let above = CellKey(row: table.rows[bottom - 1], column: key.column)
            if let range = FigureGridAddress.string(from: top, to: above, in: table) { sums[key] = "=SUM(\(range))" }
        }
        let (names, locale) = (names, values.locale)
        write(Array(sums.keys), actionName: "Sum") { prior, key, table in
            guard let text = sums[key], case .success(let cell?) = FigureCellEntry.cell(
                from: text, prior: prior, table: table, names: names, locale: locale) else { return .none }
            return .some(cell)
        }
    }

    /// **Many cells as one visit** (`setCells`: one door check, one render,
    /// one ⌘Z). Each cell is made when the write's turn comes, from what the
    /// host holds then — so an earlier write still landing is built on, never
    /// overwritten. `make` answers `.none` to leave a cell.
    private func write(_ keys: [CellKey], actionName: String,
                       make: @escaping (_ prior: Cell?, _ key: CellKey, _ table: FigureTable) -> Cell??) {
        guard !keys.isEmpty else { return }
        write(actionName: actionName) { table in
            var edits: [CellKey: Cell?] = [:]
            for key in keys where table.rowIndex(of: key.row) != nil && table.columnIndex(of: key.column) != nil {
                if case .some(let cell) = make(table[key], key, table), cell != table[key] { edits[key] = cell }
            }
            return edits
        }
    }

    /// The batch as the host's table stands when the write's turn comes;
    /// `afterPendingUndo` plans it once a ⌘Z still landing has landed (a
    /// fill reads the cells it copies).
    private func write(actionName: String, afterPendingUndo: Bool = false,
                       plan: @escaping (FigureTable) -> [CellKey: Cell?]) {
        enqueue { [host, gridUndo] in
            if afterPendingUndo { await host.awaitPendingUndoWork() }
            let edits = plan(host.state.table)
            guard !edits.isEmpty else { return }
            try await host.setCells(edits, actionName: actionName, undoManager: gridUndo)
        }
    }

    /// **Fill Down (⌘D) or Fill Right (⌘R in the grid)** (R7d-1): the
    /// selection's top row (left column) copied into the rest, formulas
    /// translated (`FigureFill.edits`; one row or column deep, from the row
    /// above or the column left) — one ⌘Z, planned when its turn comes.
    private func fill(_ direction: FigureFill.Direction) {
        guard let selection = model.selection else { return }
        let names = names
        write(actionName: direction == .down ? "Fill Down" : "Fill Right", afterPendingUndo: true) { table in
            FigureFill.edits(table: table, selection: selection, direction: direction, names: names)
        }
    }

    // MARK: Cut, copy and paste (plan 7d Task 3)

    /// Whether Edit ▸ Cut, Copy or Paste is enabled: each needs a selection,
    /// a paste something it reads. A read-only grid enables them all, so a
    /// cut or paste is answered with the reason line rather than a beep.
    func mayPerform(_ action: FigureGridClipboardAction) -> Bool {
        guard model.selection != nil else { return false }
        switch action {
        case .cut, .copy: return true
        case .paste: return FigureGridClipboard.canRead(pasteboard)
        }
    }

    /// **Copy the selection**: its cells as stored and the values they show,
    /// with this figure and the block's top-left position, in Maugham's own
    /// flavour; its display text as tab-separated text and an HTML table.
    /// Allowed on a read-only grid. Answers whether anything was copied.
    @discardableResult
    func copySelection(isCut: Bool = false) -> Bool {
        syncFromHost()
        guard let block = selectedBlock() else { return false }
        let table = values.table
        let keys = block.rows.map { row in block.columns.map { CellKey(row: row, column: $0) } }
        let copied = FigureGridClipboard.Cells(
            figureId: figureId, originRow: block.firstRow, originColumn: block.firstColumn,
            cells: keys.map { $0.map { table[$0] } }, values: keys.map { $0.map { values.value(at: $0) } },
            isCut: isCut)
        FigureGridClipboard.write(copied, display: keys.map { $0.map { values.display(at: $0) } }, to: pasteboard)
        return true
    }

    /// **Cut the selection**: copied as a cut (pasted back into this figure
    /// its formulas keep their references — a move), then cleared as one ⌘Z ("Cut"). A
    /// read-only grid copies nothing and says why; an open edit that will
    /// not read stops it (its error shown).
    func cutSelection() {
        syncFromHost()
        if let reason = mode.readOnlyReason { return answer(reason) }
        guard commitOpenEdit(), let selection = model.selection, copySelection(isCut: true) else { return }
        clear(selection.cells(in: values.table), actionName: "Cut")
    }

    /// **Paste at the selection** (R7d-2): what the pasteboard holds
    /// (`FigureGridClipboard.read`) put with its top-left at the selection's,
    /// tiling a selection that is a whole multiple of it; the table grows past
    /// its edge (never over a total row), as one visit and one ⌘Z, and the
    /// pasted cells are selected. Planned when its turn comes, against the
    /// host as it then is. More cells than a table may hold is refused with a
    /// notice and writes nothing. A read-only grid says why.
    func paste() {
        syncFromHost()
        if let reason = mode.readOnlyReason { return answer(reason) }
        guard commitOpenEdit(), let block = selectedBlock() else { return }
        guard let source = FigureGridClipboard.read(from: pasteboard) else { return NSSound.beep() }
        let anchor = CellKey(row: block.rows[0], column: block.columns[0])
        let area = (rows: block.rows.count, columns: block.columns.count)
        let (names, locale, figureId) = (names, values.locale, figureId)
        enqueue { [weak self, host, gridUndo] in
            var pasted: FigureGridSelection?
            try await Self.applyPlanned(on: host, actionName: "Paste", undoManager: gridUndo) { state in
                let cells = FigureGridClipboard.block(
                    from: source, into: figureId, table: state.table, names: names, locale: locale)
                switch FigurePaste.changes(state: state, anchor: anchor, block: cells, area: area, names: names) {
                case .paste(let plan):
                    pasted = plan.pasted
                    return plan.changes
                case .tooLarge(let count):
                    pasted = nil
                    self?.sayTooLargeToPaste(count)
                    return nil
                case .anchorGone:
                    pasted = nil
                    MaughamEvent.postNotice("Couldn't paste — the cell it was pasted at was deleted.",
                                            projectURL: host.projectURL)
                    return nil
                }
            }
            if let pasted { self?.selectPasted(pasted) }
        }
    }

    private func sayTooLargeToPaste(_ count: Int) {
        let limit = TableCSV.figureCellLimit
        MaughamEvent.postNotice(
            "Couldn't paste — \(count.formatted()) cells are more than a table can hold (\(limit.formatted())).",
            projectURL: host.projectURL)
    }

    /// The pasted cells selected, once the host holds them — unless the
    /// writer has begun an edit meanwhile, or the grid is gone.
    private func selectPasted(_ selection: FigureGridSelection) {
        syncFromHost()
        guard !isFolded, case .idle = model.edit else { return }
        execute(model.select(selection.anchor))
        if selection.focus != selection.anchor { execute(model.reduce(.click(selection.focus, extend: true))) }
    }

    // MARK: Refresh from Research (report plan 8a Task 7)

    /// **Refresh** (spec §4.3): the figure inspector's Compare sheet asks the
    /// grid open on the figure, so the refresh is one step on THIS grid's
    /// stack (`refreshPins`, one ⌘Z, ruling P-8), in turn behind every write
    /// asked before it. An open edit is committed first, and one that will
    /// not read stops it (R7c-8); a read-only grid answers with its reason
    /// and writes nothing. Answers the write (a test awaits it), nil when
    /// nothing was asked.
    @discardableResult
    func refreshPinsFromResearch() -> Task<Void, Never>? {
        syncFromHost()
        if let reason = mode.readOnlyReason {
            answer(reason)
            return nil
        }
        guard host.offers.refreshPins, !isFolded, commitOpenEdit() else { return nil }
        enqueue { [host, gridUndo] in try await host.refreshPins(undoManager: gridUndo) }
        return writes
    }

    // MARK: Import from CSV (plan 7d Task 4)

    /// Shows the open panel and answers the chosen file (nil: cancelled). A
    /// test sets this; the app leaves it nil and the panel is a sheet on the
    /// grid's window (`FigureGridImport.panelConfiguration`).
    var chooseImportFile: (@MainActor (_ chosen: @escaping @MainActor (URL?) -> Void) -> Void)?

    private func chooseFileToImport() {
        let projectURL = host.projectURL
        let chosen: @MainActor (URL?) -> Void = { [weak self] url in
            guard let url else { return }   // cancelled
            // The grid folded while the panel was up: said, never dropped (T4 M5).
            guard let self, !self.isClosed, !self.isFolded else {
                return MaughamEvent.postNotice(FigureGridImport.closedSentence(url.lastPathComponent),
                                               projectURL: projectURL)
            }
            self.importCSV(from: url)
        }
        if let chooseImportFile { return chooseImportFile(chosen) }
        let panel = NSOpenPanel()
        FigureGridImport.panelConfiguration.apply(to: panel)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated { chosen(response == .OK ? panel.url : nil) }
        }
        if let window = gridView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// **Import `url`'s cells over the table** (R7d-8): read, counted and
    /// parsed off the main actor (`FigureGridImport.read`), then matched
    /// onto the host as it is when the write's turn comes
    /// (`FigureGridImport.changes`, bounded by the cell limit) and written as
    /// one visit and one ⌘Z. Refused with a notice, writing nothing: a
    /// read-only grid (the reason line), a grid already folded, a file that
    /// will not read or holds no cells, more cells than a table may hold. A
    /// file the table already matches is said, as are cells the read kept as
    /// text.
    func importCSV(from url: URL) {
        syncFromHost()
        if let reason = mode.readOnlyReason { return answer(reason) }
        let file = url.lastPathComponent
        let projectURL = host.projectURL
        guard !isFolded, let store else {
            return MaughamEvent.postNotice(FigureGridImport.closedSentence(file), projectURL: projectURL)
        }
        enqueue { [weak self, host, store, gridUndo] in
            let context = try await store.tableImportContext()
            let (locale, names) = (context.locale, context.names)
            let outcome = try await Task.detached {
                try FigureGridImport.read(url, locale: locale, names: names)
            }.value
            let read: FigureGridImport.Read
            switch outcome {
            case .tooManyCells(let cells):
                return MaughamEvent.postNotice(FigureGridImport.tooManyCellsSentence(file, cells: cells),
                                               projectURL: projectURL)
            case .noCells:
                return MaughamEvent.postNotice(FigureGridImport.noCellsSentence(file), projectURL: projectURL)
            case .read(let table, let problems):
                read = .init(table: table, problems: problems)
            }
            var problems: [CSVReadProblem] = []
            var planned = false, totalRowOff = false
            try await Self.applyPlanned(on: host, actionName: FigureGridImport.actionName,
                                        undoManager: gridUndo) { state in
                let changes = FigureGridImport.changes(
                    onto: state, read: read.table, names: names, problems: read.problems)
                problems = changes.problems
                planned = !changes.ops.isEmpty
                totalRowOff = changes.ops.contains { $0.payload.settings == .totalRow(false, prior: true) }
                return changes.ops
            }
            guard planned else {
                return MaughamEvent.postNotice(FigureGridImport.unchangedSentence(file), projectURL: projectURL)
            }
            if totalRowOff {
                MaughamEvent.postNotice(FigureGridImport.totalRowOffSentence(file), projectURL: projectURL)
            }
            if !problems.isEmpty { self?.sayKeptAsText(problems.count, file) }
        }
    }

    private func sayKeptAsText(_ count: Int, _ file: String) {
        let cells = count == 1 ? "1 cell" : "\(count) cells"
        MaughamEvent.postNotice(
            "Imported “\(file)”; \(cells) couldn't be read as a formula and \(count == 1 ? "was" : "were") kept as text.",
            projectURL: host.projectURL)
    }

    // MARK: Caption and name

    /// The caption is the figure line's text: Route A through the coordinator.
    /// Refused (the membrane, a line gone), the field shows the caption again.
    private func commitCaption(_ caption: String) {
        if host.offers.caption, line.commitCaption(caption) { line.caption = FigureIngest.keptCaption(caption) }
        bars.showLine(number: line.number, caption: line.caption, name: name)
        bars.captionField.stringValue = line.caption
    }

    /// The name through `ProjectStore.renameFigure` (every door it asks, the
    /// line relabelled). Refused, the refusal is said and the field put back.
    private func commitName(_ newName: String) {
        guard host.offers.rename else {
            bars.nameField.stringValue = name
            return
        }
        enqueue { [weak self, projectStore, figureId] in
            guard let projectStore else { return }
            do {
                let record = try await projectStore.renameFigure(id: figureId, to: newName)
                self?.name = record.name
            } catch {
                self?.refused(error)
            }
            guard let self else { return }
            self.bars.showLine(number: self.line.number, caption: self.line.caption, name: self.name)
            self.bars.nameField.stringValue = self.name
        }
    }

    // MARK: The host

    /// Writes run in the order asked, each after the one before; a refusal is said.
    private func enqueue(_ act: @escaping @MainActor () async throws -> Void) {
        let previous = writes
        writesInFlight += 1
        writes = Task { @MainActor [weak self] in
            defer { self?.writesInFlight -= 1 }
            await previous?.value
            await Self.writeTurnForTesting?()
            do {
                try await act()
            } catch {
                self?.refused(error)
            }
            self?.syncFromHost()
        }
    }

    /// A write that failed: said, and — when the host refused it at its door
    /// (the figure's posture, a park, a close) — the cells shown as the host
    /// holds them and the gate asked again (`onAccessMayHaveChanged`).
    private func refused(_ error: Error) {
        say(error)
        guard error is FigureEditRefused || error is FigureParkedRefused || error is DocumentNotWritableError
        else { return }
        gridView.reloadData()
        onAccessMayHaveChanged?()
    }

    /// **The figure's drawn posture, observed** (the window's door, read as
    /// a view reads it): a trust change bumps the door's epoch and *Edit
    /// Anyway* lifts a yield, neither of which need move a card. Re-armed
    /// after each change; the gate is asked on the next turn.
    private func observeTheDoor() {
        guard !isClosed, let store else { return }
        let figureId = figureId
        withObservationTracking {
            _ = store.posture(forDocId: figureId).allows(.editFigure)
        } onChange: { [weak self] in
            // The door is the main actor's: its change is announced there.
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                self.postureChange = Task { @MainActor [weak self] in
                    guard let self, !self.isClosed else { return }
                    self.onAccessMayHaveChanged?()
                    self.observeTheDoor()
                }
            }
        }
    }

    /// A refusal as a notice; a sort's refusal says itself (`FigureSortRefused`).
    private func say(_ error: Error) {
        if error is FigureSortRefused || error is CancellationError { return }
        MaughamEvent.postNotice(error.localizedDescription, projectURL: host.projectURL)
    }

    /// The catch-up a host change scheduled (a test awaits it).
    private(set) var hostSync: Task<Void, Never>?

    /// Re-armed after each change: the host's state is read on the next turn.
    private func observeHost() {
        guard !isClosed else { return }
        withObservationTracking {
            _ = host.state
        } onChange: { [weak self] in
            // The host is the main actor's: its change is announced there.
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                self.hostSync = Task { @MainActor [weak self] in
                    guard let self, !self.isClosed else { return }
                    self.syncFromHost()
                    self.observeHost()
                }
            }
        }
    }

    /// **Catch up with the host's state**: the values advanced (only the cells
    /// that read what changed), the model's selection checked against the
    /// table, the visible cells that changed repainted.
    private func syncFromHost() {
        guard !isClosed else { return }
        let next = host.state
        guard next != values.state else { return }
        let tableChanged = next.table != values.table
        // An open edit whose row or column goes with this change is closed
        // by the model; typing it held is said, never lost (final review I3).
        let old = values.table
        let changedEdit: FigureGridEdit? = switch model.edit {
        case .idle: nil
        case .editing(let e), .composing(let e, _): tableChanged && e.text != barText(for: e.cell) ? e : nil
        }
        let repaint = values.advance(to: next)
        if tableChanged {
            let effects = model.tableChanged(next.table)
            if let changedEdit, effects.contains(.cancelEdit) {
                sayUnwritten(changedEdit.text, at: changedEdit.cell, in: old, "its row or column was deleted")
            }
            execute(effects)
        }
        if repaint == .everything { gridView.reloadData() } else { gridView.repaint(repaint) }
        refreshBars()
    }

    // MARK: Showing

    /// What the formula bar shows for `key`: its formula with `=`, or its value.
    private func barText(for key: CellKey) -> String {
        let table = values.table
        return FigureCellEntry.formulaBarText(for: table[key], table: table, names: names, locale: values.locale)
    }

    /// The bars follow the selection, the open edit and the table.
    private func refreshBars(force: Bool = false) {
        refreshMenuState()
        let table = values.table
        guard let selection = model.selection else {
            bars.showSelection(address: "", text: "")
            return
        }
        let text: String
        switch model.edit {
        case .idle: text = barText(for: selection.anchor)
        case .editing(let e), .composing(let e, _): text = e.text
        }
        if force { bars.setFormulaText(text) }
        bars.showSelection(address: selection.address(in: table) ?? "", text: text)
        let cell = table[selection.anchor]
        bars.showFormat(cell?.format.number ?? .general, alignment: cell?.alignment ?? .automatic,
                        header: table.headerRows > 0, total: table.hasTotalRow)
    }
}
