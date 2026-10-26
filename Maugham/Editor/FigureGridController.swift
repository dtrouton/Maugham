import AppKit
import Observation
import MaughamCore

/// **One visit to a table figure's grid** (report plan 7c Task 5): the figure
/// host, the pure `FigureGridModel` (selection, edit state, keys), the
/// `FigureGridValues` holder (computed values and cached strings), the
/// `FigureGridView` and its `FigureGridBars`.
///
/// - **The only grid file that calls a figure mutator** (tripwire 52 counts
///   this file's calls in `manuscriptWriterCallSites`): a cell through
///   `setCell`, a range (⌫, a format, decimals, align, Σ) through `setCells`
///   — one ⌘Z and one render however many cells — and the structure verbs.
///   Each registers on the window's `UndoManager` (ruling R7c-1, until 7d).
/// - **It observes `host.state`** (`withObservationTracking`; the coordinator
///   never does, tripwire 6) and advances the values incrementally, repainting
///   the visible cells that changed; a `figureCardVersion` edge reseeds
///   (`figureCardsChanged`).
/// - Writes run one after another, in the order asked; a refusal is said as
///   a notice (a sort says its own).
/// - **The caption** is text, so it is committed by the coordinator through
///   Route A (`Line.commitCaption`, membrane-gated); **the name** through
///   `ProjectStore.renameFigure`, whose refusal is said and the field put back.
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

    let host: FigureDocument
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
    private let undoManager: @MainActor () -> UndoManager?

    /// Told when the grid folds (Esc on a selected cell, Done).
    var onFold: (() -> Void)?

    /// Where the open edit is being typed: the cell editor or the formula bar.
    private enum EditSource { case cell, bar }
    private var editSource: EditSource = .cell

    /// The last write asked for; each awaits the one before it.
    private var writes: Task<Void, Never>?
    private var isClosed = false

    /// Test seam: runs as each write's turn comes, before it reads the host —
    /// where a test lands a change made elsewhere.
    static var writeTurnForTesting: (@MainActor () async -> Void)?

    // MARK: Opening

    /// **Open a visit** on `figureId`'s table through the window's store: its
    /// host (`DocumentStore.openFigure`), the book's language and names, and
    /// the values seeded from the whole book once.
    static func open(
        figureId: String, store: DocumentStore, projectStore: ProjectStore,
        typography: TypographySettings, line: Line,
        undoManager: @escaping @MainActor () -> UndoManager?
    ) async throws -> FigureGridController {
        let host = try await store.openFigure(figureId: figureId)
        let context = try await store.tableImportContext()
        let controller = FigureGridController(
            host: host, store: store, projectStore: projectStore, typography: typography,
            locale: context.locale, names: context.names, line: line, undoManager: undoManager)
        let repaint = try await controller.values.reseed()
        controller.gridView.repaint(repaint)
        return controller
    }

    private init(host: FigureDocument, store: DocumentStore, projectStore: ProjectStore,
                 typography: TypographySettings, locale: TableLocale, names: FormulaNames, line: Line,
                 undoManager: @escaping @MainActor () -> UndoManager?) {
        self.host = host
        self.store = store
        self.projectStore = projectStore
        self.names = names
        self.line = line
        self.undoManager = undoManager
        name = projectStore.manifest.figures?.first { $0.id == host.figureId }?.name ?? ""
        values = FigureGridValues(figureId: host.figureId, state: host.state, locale: locale, store: store)
        gridView = FigureGridView(typography: typography)
        // A placeholder first, so the real model's closure may capture `self`.
        model = FigureGridModel(table: host.state.table, editText: { _ in "" })
        model = FigureGridModel(table: host.state.table, editText: { [weak self] in self?.barText(for: $0) ?? "" })
        gridView.dataSource = self
        gridView.delegate = self
        bars.delegate = self
        bars.showLine(number: line.number, caption: line.caption, name: name)
        refreshBars()
        observeHost()
    }

    /// **End the visit**: stop observing the host. The host stays the window's.
    func close() {
        isClosed = true
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

    func figureGridView(_ view: FigureGridView, didResizeColumn column: ColumnID, to width: CGFloat) {
        enqueue { [host, undoManager] in
            try await host.setColumnWidth(column, Double(width), undoManager: undoManager())
        }
    }

    /// **Feed one key to the model and do what it answers.** False when the
    /// key is the open cell editor's own.
    @discardableResult
    func handle(_ key: FigureGridKey) -> Bool {
        syncFromHost()
        if case .editTextChanged(let text) = key {
            bars.clearError()
            if editSource == .cell { bars.setFormulaText(text) }
        }
        let effects = model.reduce(key)
        execute(effects)
        return effects != [.fieldEditorKeeps]
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
            enqueue { [host, undoManager] in try await host.setHeaderRows(on ? 1 : 0, undoManager: undoManager()) }
        case .totalRow(let on):
            enqueue { [host, undoManager] in try await host.setTotalRow(on, undoManager: undoManager()) }
        case .sum: sumAbove()
        case .caption(let caption): commitCaption(caption)
        case .name(let newName): commitName(newName)
        case .done: execute(model.fold(commit: true))
        }
        return true
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
                enqueue { [weak self, host, undoManager] in
                    let id = try await host.insertRow(after: after, undoManager: undoManager())
                    self?.selectInserted { CellKey(row: id, column: $0.column) }
                }
            case .insertColumn(let after):
                enqueue { [weak self, host, undoManager] in
                    let id = try await host.insertColumn(after: after, undoManager: undoManager())
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

    /// Close whichever field the edit was typed in; the grid takes the keys back.
    private func endEdit() {
        gridView.endEditing()
        if editSource == .bar {
            editSource = .cell
            gridView.window?.makeFirstResponder(gridView)
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
            enqueue { [weak self, host, undoManager] in
                let table = host.state.table
                switch FigureCellEntry.cell(from: text, prior: table[cell], table: table, names: names, locale: locale) {
                case .success(let next):
                    try await host.setCell(next, at: cell, undoManager: undoManager())
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
        if case .idle = model.edit, values.table.rowIndex(of: cell.row) != nil,
           values.table.columnIndex(of: cell.column) != nil {
            editSource = .cell
            reopen(text, at: cell, error)
            return
        }
        let address = FigureGridAddress.string(from: cell, to: cell, in: values.table).map { " in \($0)" } ?? ""
        MaughamEvent.postNotice("Couldn't write “\(text)”\(address) — \(error.message).", projectURL: host.projectURL)
    }

    /// ⌫ over the selection: each cell emptied as typing nothing would (a
    /// chosen format kept), as one ⌘Z.
    private func clear(_ keys: [CellKey]) {
        let (names, locale) = (names, values.locale)
        write(keys, actionName: "Clear Cells") { prior, _, table in
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
        enqueue { [host, undoManager] in
            let table = host.state.table
            var edits: [CellKey: Cell?] = [:]
            for key in keys where table.rowIndex(of: key.row) != nil && table.columnIndex(of: key.column) != nil {
                if case .some(let cell) = make(table[key], key, table), cell != table[key] { edits[key] = cell }
            }
            guard !edits.isEmpty else { return }
            try await host.setCells(edits, actionName: actionName, undoManager: undoManager())
        }
    }

    // MARK: Caption and name

    /// The caption is the figure line's text: Route A through the coordinator.
    /// Refused (the membrane, a line gone), the field shows the caption again.
    private func commitCaption(_ caption: String) {
        if line.commitCaption(caption) { line.caption = FigureIngest.keptCaption(caption) }
        bars.showLine(number: line.number, caption: line.caption, name: name)
        bars.captionField.stringValue = line.caption
    }

    /// The name through `ProjectStore.renameFigure` (every door it asks, the
    /// line relabelled). Refused, the refusal is said and the field put back.
    private func commitName(_ newName: String) {
        enqueue { [weak self, projectStore, figureId] in
            guard let projectStore else { return }
            do {
                let record = try await projectStore.renameFigure(id: figureId, to: newName)
                self?.name = record.name
            } catch {
                self?.say(error)
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
        writes = Task { @MainActor [weak self] in
            await previous?.value
            await Self.writeTurnForTesting?()
            do {
                try await act()
            } catch {
                self?.say(error)
            }
            self?.syncFromHost()
        }
    }

    /// A refusal as a notice; a sort's refusal says itself (`FigureSortRefused`).
    private func say(_ error: Error) {
        if error is FigureSortRefused || error is CancellationError { return }
        MaughamEvent.postNotice(error.localizedDescription, projectURL: host.projectURL)
    }

    /// Re-armed after each change: the host's state is read on the next turn.
    private func observeHost() {
        guard !isClosed else { return }
        withObservationTracking {
            _ = host.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.syncFromHost()
                self.observeHost()
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
        let repaint = values.advance(to: next)
        if tableChanged { execute(model.tableChanged(next.table)) }
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
