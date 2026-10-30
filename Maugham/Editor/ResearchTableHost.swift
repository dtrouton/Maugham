import Foundation
import Observation
import os
import MaughamCore

private let researchTableLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham", category: "ResearchTableHost")

/// **A Research table's CSV, edited in the table grid** (report plan 8b
/// Task 7, spec §4.2, ruling D8-3): the grid's second host (`FigureGridHost`).
/// A Research file follows Research rules — plain, last writer wins, no op
/// log: the table is held here, each edit changes it in memory and registers
/// its ⌘Z on the grid's own stack, and the file is written whole.
///
/// - **Opened, it reads** the item's file (`ProjectStore.decodeResearchTable`,
///   the store's decoder) through `TableCSV.read` in the book's language, and
///   lays the sidecar's header, formats and widths on while the sidecar was
///   written for these bytes (`contentHash`). A file that is missing, will
///   not decode or is past `TableCSV.figureCellLimit` throws: the grid says
///   why and never shows an empty table over it (RULING-7's precedent,
///   `ResearchNoteLoad`).
/// - **It writes only on an edit**, never on open: an edit schedules a save
///   `saveDelay` later (the research-note cadence), and a later edit moves it
///   on. The save writes `TableCSV.renderResearch` in the file's own
///   separator, UTF-8, through the window's coordinated atomic write
///   (`DocumentStore.performFileSave`, the item's path asked of the manifest
///   at the save — tripwire 58's `resolvedProjectPathToChange`); then the
///   sidecar with the new bytes' hash, keeping `figureId`, `name` and
///   `caption`; then `invalidateFigureCards()`, so a figure pinning this table
///   says "changed".
/// - **`flush()`** writes a pending save now: the grid's leave (the subject
///   moved on, the window closing) and `DocumentStore.flushPendingSave` (⌘S,
///   the typed mover before a move, the store's close at ⌘Q) reach it — the
///   store holds every open host (`attachResearchTable`).
/// - **Undo is the grid's while it is open**: each edit registers one step
///   restoring the table it replaced (and the redo, the table it made); the
///   saved file is not versioned (D8-3).
/// - **Read-only** (`refusal`, set by the mount): every mutator refuses,
///   writing nothing — the grid's gate says why first.
/// - It is not a figure: it offers none of the figure's own commands
///   (`FigureGridOffers.none`), asks no figure's door, keeps no pins and
///   begins no in-place visit.
@MainActor
@Observable
final class ResearchTableHost: FigureGridHost {

    /// Why a Research table refused an edit.
    struct Refused: LocalizedError, Equatable {
        let reason: FigureGridGate.Reason
        var errorDescription: String? { reason.sentence }
    }

    /// Why a Research table could not be opened in the grid.
    struct Unreadable: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The Research item's id: what the grid is keyed by, and what the
    /// table's formulas call it (`FigureGridValues`' overlay).
    let itemId: String
    var figureId: String { itemId }
    let projectURL: URL
    private(set) var state: FigureState
    private(set) var isClosed = false
    var offers: FigureGridOffers { .none }
    var asksTheFigureDoor: Bool { false }

    /// The file's separator, kept by every save.
    let separator: Character
    /// While set, every edit refuses with it (the mount's gate: Review, a
    /// view-only share).
    var refusal: FigureGridGate.Reason?

    @ObservationIgnored var _lastUndoWorkTask: Task<Void, Never>?
    @ObservationIgnored private weak var store: DocumentStore?
    @ObservationIgnored private let locale: TableLocale
    @ObservationIgnored private var names: FormulaNames
    /// The sidecar as last read or written: who the table was (`figureId`,
    /// `name`, `caption`) is kept by every save.
    @ObservationIgnored private(set) var sidecar: ResearchTableSidecar?
    /// An edit not yet written.
    @ObservationIgnored private(set) var isDirty = false
    @ObservationIgnored private(set) var scheduledSave: Task<Void, Never>?
    /// The last save asked; each waits for the one before it.
    @ObservationIgnored private(set) var saving: Task<Void, Never>?
    /// How long after the last edit the file is written.
    @ObservationIgnored var saveDelay: Duration = .milliseconds(750)

    /// Test seam: told the text of each write that landed.
    static var wroteForTesting: (@MainActor (String) -> Void)?

    private init(itemId: String, projectURL: URL, store: DocumentStore, table: FigureTable,
                 separator: Character, locale: TableLocale, names: FormulaNames,
                 sidecar: ResearchTableSidecar?) {
        self.itemId = itemId
        self.projectURL = projectURL
        self.store = store
        self.state = FigureState(kind: .table, table: table)
        self.separator = separator
        self.locale = locale
        self.names = names
        self.sidecar = sidecar
    }

    // MARK: Opening

    /// **Open Research item `itemId`'s table** through the window's stores:
    /// read, never written. Throws `Unreadable` (or the path's refusal) for a
    /// file that is not there, will not decode or is too large.
    static func open(itemId: String, store: DocumentStore) async throws -> ResearchTableHost {
        guard let projectStore = store.projectStore else {
            throw Unreadable(message: "The project isn’t open.")
        }
        guard let item = projectStore.findResearchItem(id: itemId, in: projectStore.manifest.research),
              item.type == .asset, item.kind == .table, let path = item.path else {
            throw Unreadable(message: "This item isn’t a table in Research.")
        }
        let file = try projectStore.resolvedProjectPath(path)
        let projectURL = store.projectURL
        let (text, hash, sidecar) = try await Task.detached {
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw Unreadable(message: "Maugham couldn’t find \(path).")
            }
            let data = try Data(contentsOf: file) // adr-0018-ok: a Research table's CSV, read to edit in the grid; not manuscript
            guard let text = ProjectStore.decodeResearchTable(data) else {
                throw Unreadable(message: "Maugham couldn’t read \(path) as text.")
            }
            let cells = TableCSV.nonEmptyCellCount(text)
            guard cells <= TableCSV.figureCellLimit else {
                throw Unreadable(message: "This table is too large to edit here (\(cells) cells; the limit is \(TableCSV.figureCellLimit)).")
            }
            // A sidecar that will not read is no sidecar: the table opens as its file reads.
            let sidecar = try? ResearchTableSidecar.read(forItem: itemId, in: projectURL)
            return (text, ContentHash.of(data), sidecar)
        }.value
        let context = try await store.tableImportContext()
        let current = sidecar?.contentHash == hash ? sidecar : nil
        let read = TableCSV.read(
            text, locale: context.locale, names: current.map { context.names.renaming($0.formulaNames) } ?? context.names)
        let table = current.map { $0.applied(to: read.table) } ?? read.table
        let host = ResearchTableHost(
            itemId: itemId, projectURL: projectURL, store: store, table: table,
            separator: TableCSV.rows(text).separator, locale: context.locale, names: context.names,
            sidecar: sidecar)
        store.attachResearchTable(host)
        return host
    }

    /// **The table read again from its file** (another writer's change): what
    /// is on disk replaces what is held, and an edit not yet written is
    /// dropped — the file is the last writer.
    func reload() async throws {
        guard let store else { return }
        let fresh = try await Self.open(itemId: itemId, store: store)
        store.detachResearchTable(fresh)
        scheduledSave?.cancel()
        scheduledSave = nil
        isDirty = false
        sidecar = fresh.sidecar
        state = fresh.state
    }

    // MARK: Saving

    /// Every edit asked has been written (a pending save now, not later).
    func flush() async {
        scheduledSave?.cancel()
        scheduledSave = nil
        await save()
    }

    /// The grid's visit ending (its open edit committed, its writes landing,
    /// then `close`), set by the grid's mount as it leaves.
    @ObservationIgnored var visitEnding: Task<Void, Never>?

    /// **Everything asked of this table, written**: a visit still ending
    /// lands first, then any pending save — `DocumentStore.flushPendingSave`'s
    /// wait, so a window's close writes the edit its grid was holding.
    func settle() async {
        await visitEnding?.value
        await flush()
    }

    /// The visit is over: its last save lands, and nothing more is written.
    func close() async {
        await flush()
        isClosed = true
        store?.detachResearchTable(self)
    }

    private func scheduleSave() {
        isDirty = true
        scheduledSave?.cancel()
        let delay = saveDelay
        scheduledSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.scheduledSave = nil
            await self.save()
        }
    }

    /// One save at a time, in the order asked; nothing when nothing changed.
    private func save() async {
        let previous = saving
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.isDirty else { return }
            self.isDirty = false
            await self.write(self.state.table)
        }
        saving = task
        await task.value
    }

    /// The file, then its sidecar, then the cards: what one save writes.
    private func write(_ table: FigureTable) async {
        guard let store else { return }
        guard let item = store.projectStore.flatMap({ $0.findResearchItem(id: itemId, in: $0.manifest.research) }),
              let path = item.path else {
            MaughamEvent.postNotice("A Research table’s edits couldn’t be saved: it is no longer in Research.",
                                    projectURL: projectURL)
            return
        }
        // The names its formulas read as they are now; the ones it opened with if they will not read.
        if let fresh = try? await store.formulaNamesForUse() { names = fresh }
        let text = TableCSV.renderResearch(table, locale: locale, names: names, separator: separator)
        do {
            try await store.performFileSave(path: path, text: text)
        } catch {
            isDirty = true   // the next edit, or the close, tries again
            researchTableLog.error(
                "\(path, privacy: .public) was not saved: \(error.localizedDescription, privacy: .public)")
            MaughamEvent.postNotice("Couldn’t save “\(item.title)”: \(error.localizedDescription)",
                                    projectURL: projectURL)
            return
        }
        var next = ResearchTableSidecar(
            figureId: "", contentHash: ContentHash.of(Data(text.utf8)), name: "",
            caption: sidecar?.caption, table: table, formulaNames: names.cited(by: table))
        next.figureId = sidecar?.figureId
        next.name = sidecar?.name
        do {
            try ResearchTableSidecar.write(next, forItem: itemId, in: projectURL)
            sidecar = next
        } catch {
            researchTableLog.error(
                "\(path, privacy: .public)'s sidecar was not written: \(error.localizedDescription, privacy: .public)")
        }
        store.invalidateFigureCards()
        Self.wroteForTesting?(text)
    }

    // MARK: Editing

    /// One edit: the table changed in memory, one ⌘Z registered, the save
    /// scheduled. Nothing happens for an edit that changes nothing.
    private func edit(_ actionName: String, undoManager: UndoManager?,
                      _ body: (inout FigureTable) throws -> Void) throws {
        if isClosed { throw Refused(reason: .closed) }
        if let refusal { throw Refused(reason: refusal) }
        var next = state.table
        try body(&next)
        guard next != state.table else { return }
        let prior = state.table
        state.table = next
        register(undoManager, actionName, restoring: prior)
        scheduleSave()
    }

    /// One step on `undoManager` putting `prior` back; taken, it registers
    /// the table it replaced — the redo (and the redo's undo again).
    private func register(_ undoManager: UndoManager?, _ actionName: String, restoring prior: FigureTable) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] host in
            // The grid's stack is run on the main thread (`undoInGrid`).
            MainActor.assumeIsolated {
                guard !host.isClosed, host.refusal == nil else { return }
                let replaced = host.state.table
                host.state.table = prior
                host.register(undoManager, actionName, restoring: replaced)
                host.scheduleSave()
            }
        }
        undoManager.setActionName(actionName)
    }

    private func requireCell(_ key: CellKey, in table: FigureTable) throws {
        guard table.rowIndex(of: key.row) != nil, table.columnIndex(of: key.column) != nil else {
            throw FigureEditInvalid(reason: "that cell's row or column is gone")
        }
    }

    func setCell(_ cell: Cell?, at key: CellKey, undoManager: UndoManager?) async throws {
        try edit("Edit Cell", undoManager: undoManager) { table in
            try requireCell(key, in: table)
            table.setCell(cell, at: key)
        }
    }

    func setCells(_ edits: [CellKey: Cell?], actionName: String, undoManager: UndoManager?) async throws {
        try edit(actionName, undoManager: undoManager) { table in
            for (key, cell) in edits {
                try requireCell(key, in: table)
                table.setCell(cell, at: key)
            }
        }
    }

    func insertRow(after: RowID?, undoManager: UndoManager?) async throws -> RowID {
        var id: RowID?
        try edit("Insert Row", undoManager: undoManager) { table in
            if let after, table.rowSlotIndex(of: after) == nil {
                throw FigureEditInvalid(reason: "no such row to insert after")
            }
            id = table.insertRow(after: after)
        }
        guard let id else { throw FigureEditInvalid(reason: "the row was not inserted") }
        return id
    }

    func insertColumn(after: ColumnID?, undoManager: UndoManager?) async throws -> ColumnID {
        var id: ColumnID?
        try edit("Insert Column", undoManager: undoManager) { table in
            if let after, table.columnSlotIndex(of: after) == nil {
                throw FigureEditInvalid(reason: "no such column to insert after")
            }
            id = table.insertColumn(after: after)
        }
        guard let id else { throw FigureEditInvalid(reason: "the column was not inserted") }
        return id
    }

    func deleteRow(_ id: RowID, undoManager: UndoManager?) async throws {
        try edit("Delete Row", undoManager: undoManager) { table in
            guard table.rowIndex(of: id) != nil else { throw FigureEditInvalid(reason: "that row is gone") }
            table.deleteRow(id)
        }
    }

    func deleteColumn(_ id: ColumnID, undoManager: UndoManager?) async throws {
        try edit("Delete Column", undoManager: undoManager) { table in
            guard table.columnIndex(of: id) != nil else { throw FigureEditInvalid(reason: "that column is gone") }
            table.deleteColumn(id)
        }
    }

    func moveRow(_ id: RowID, after: RowID?, undoManager: UndoManager?) async throws {
        try edit("Move Row", undoManager: undoManager) { table in
            guard table.rowIndex(of: id) != nil, after != id else {
                throw FigureEditInvalid(reason: "that row cannot move there")
            }
            table.moveRow(id, after: after)
        }
    }

    func moveColumn(_ id: ColumnID, after: ColumnID?, undoManager: UndoManager?) async throws {
        try edit("Move Column", undoManager: undoManager) { table in
            guard table.columnIndex(of: id) != nil, after != id else {
                throw FigureEditInvalid(reason: "that column cannot move there")
            }
            table.moveColumn(id, after: after)
        }
    }

    /// The body rows in `column`'s order, and the table's own ranges over
    /// them re-anchored (`FigureRangeAnchors`), as a figure's sort does.
    func sortRows(by column: ColumnID, ascending: Bool, values: (CellKey) -> CellValue,
                  actionName: String, undoManager: UndoManager?) async throws {
        try edit(actionName, undoManager: undoManager) { table in
            guard table.columnIndex(of: column) != nil else { throw FigureEditInvalid(reason: "that column is gone") }
            let old = table
            let order = FigureSort.order(table: old, values: values, column: column, ascending: ascending)
            for (i, row) in order.enumerated() { table.moveRow(row, after: i == 0 ? nil : order[i - 1]) }
            for (key, cell) in FigureRangeAnchors.reanchoredCells(old: old, new: table, ownId: itemId) {
                table.setCell(cell, at: key)
            }
        }
    }

    func setHeaderRows(_ rows: Int, undoManager: UndoManager?) async throws {
        try edit(rows > 0 ? "Header Row" : "No Header Row", undoManager: undoManager) { $0.headerRows = rows }
    }

    func setTotalRow(_ total: Bool, undoManager: UndoManager?) async throws {
        try edit(total ? "Total Row" : "No Total Row", undoManager: undoManager) { $0.hasTotalRow = total }
    }

    func setColumnWidth(_ column: ColumnID, _ width: Double?, undoManager: UndoManager?) async throws {
        try edit("Column Width", undoManager: undoManager) { table in
            guard table.columnIndex(of: column) != nil else { throw FigureEditInvalid(reason: "that column is gone") }
            table.columnWidths[column] = width
        }
    }

    /// A batch planned against `expecting` (a paste, an import, a delete of
    /// several rows or columns), applied as `FigureReturnDiff.applied` folds
    /// it: refused, writing nothing, once the table moved under the plan or a
    /// change does not fit. One ⌘Z.
    func applyChanges(_ changes: [FigureReturnDiff.Change], expecting: FigureState,
                      actionName: String, undoManager: UndoManager?) async throws {
        guard !changes.isEmpty else { return }
        guard state == expecting else {
            throw FigureEditInvalid(reason: "the table changed while the change was being prepared")
        }
        let current = state
        try edit(actionName, undoManager: undoManager) { table in
            guard let applied = FigureReturnDiff.applied(changes, onto: current) else {
                throw FigureEditInvalid(reason: "the changes don't fit the table")
            }
            table = applied.table
        }
    }

    /// A Research table keeps no pins (`offers.refreshPins` is false).
    func refreshPins(undoManager: UndoManager?) async throws {}

    // MARK: Undo and the visit

    func awaitPendingUndoWork() async {
        await _lastUndoWorkTask?.value
    }

    /// A Research table is never expanded in place: it records no visit.
    @discardableResult
    func beginVisit(undoManager: UndoManager) -> Bool { false }
    func endVisit() -> FigureVisit? { nil }
    func endVisit(ownedBy manager: UndoManager) -> FigureVisit? { nil }
    var visitHasRecorded: Bool { false }
    @discardableResult
    func undoVisit(_ visit: FigureVisit) async -> Bool { false }
    @discardableResult
    func redoVisit(_ visit: FigureVisit) async -> Bool { false }
}

extension FigureGridOffers {
    /// A host that is not a figure: none of the figure's own commands.
    static let none = FigureGridOffers(nameField: false, rename: false, caption: false,
                                       sendToResearch: false, refreshPins: false, openInWindow: false)
}
