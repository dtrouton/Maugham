import Foundation
import Observation
import os
import MaughamCore

private let researchTableLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham", category: "ResearchTableHost")

/// **A Research table's CSV, edited in the table grid** (report plan 8b
/// Task 7, spec §4.2, ruling D8-3): the grid's second host (`FigureGridHost`).
/// A Research file has no op log: the table is held here, each edit changes
/// it in memory and registers its ⌘Z on the grid's own stack, and the file is
/// written whole.
///
/// - **One per item per window store** (`DocumentStore.openResearchTable`, as
///   `openFigure` shares a figure's host): every grid on the item edits the
///   same table, and the last to let go closes it (its last save landed).
/// - **Opened, it reads** the item's file (`ProjectStore.decodeResearchTable`,
///   the store's decoder) through `TableCSV.read` in the book's language, and
///   lays the sidecar's header, formats and widths on while the sidecar was
///   written for these bytes (`contentHash`). A file that is missing or will
///   not decode throws `Unreadable`, one past `TableCSV.figureCellLimit`
///   `TooLarge` (shown as text instead): the grid never shows an empty table
///   over a file (RULING-7's precedent, `ResearchNoteLoad`).
/// - **It writes only on an edit**, never on open: an edit schedules a save
///   `saveDelay` later (the research-note cadence), and a later edit moves it
///   on. The save writes `TableCSV.renderResearch` in the file's own
///   separator and line ending, UTF-8 (with the byte-order mark the file had),
///   through the window's coordinated atomic write (`performFileSave`, the
///   item's path asked of the manifest at the save — tripwire 58); then the
///   sidecar with the new bytes' hash, keeping `figureId`, `name` and
///   `caption`; then `invalidateFigureCards()`, so a figure pinning this table
///   says "changed".
/// - **An outside change is never overwritten silently** (Denver's ruling):
///   the hash of the bytes last read or written is kept (`diskHash`). The file
///   changed while the grid holds no edit → read again and said
///   (`fileMayHaveChanged`, from the window's file presenter); changed under a
///   pending edit → the outside version is kept as a conflict backup under
///   `.maugham/conflicts/` (`Document.writeConflictBackup`), said, then the
///   grid's version is written.
/// - **`settle()`** writes everything asked: a visit still ending, each open
///   grid's open edit committed (`addSettler`), then a pending save —
///   `DocumentStore.flushPendingSave` (⌘S, the typed mover, the store's close
///   at ⌘Q) and the verbs that read the CSV (`settleResearchTable`) ask it.
/// - **Undo is the grid's while it is open**: each edit registers one step
///   restoring the table it replaced, declined once the table has moved on
///   since (another grid, a reload); the saved file is not versioned (D8-3).
/// - **A view-only share** (`refusal`, set by the mounts): every mutator
///   refuses. Review is the grid's own gate, as it is for a figure.
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

    /// A table too large for the grid: it is shown as text instead.
    struct TooLarge: LocalizedError, Equatable {
        let cells: Int
        var errorDescription: String? {
            "This table has \(cells) cells, more than the grid edits (\(TableCSV.figureCellLimit)), so it is shown as text."
        }
    }

    /// One read of the item's file.
    struct FileRead: Sendable {
        let text: String
        let hash: String
        let sidecar: ResearchTableSidecar?
        let hasBOM: Bool
        let lineEnding: String
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

    /// The file's separator, line ending and byte-order mark, kept by every save.
    @ObservationIgnored private(set) var separator: Character
    @ObservationIgnored private(set) var lineEnding: String
    @ObservationIgnored private(set) var hasBOM: Bool
    /// The hash of the bytes last read or written here.
    @ObservationIgnored private(set) var diskHash: String
    /// While set, every edit refuses with it (a view-only share).
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
    /// Each open grid's "commit what is typed" (`addSettler`).
    @ObservationIgnored private var settlers: [UUID: @MainActor () async -> Void] = [:]
    /// Visits ending: their open edits committed and their writes landing.
    @ObservationIgnored private var endingVisits: [Task<Void, Never>] = []

    /// Test seam: told the text of each write that landed.
    static var wroteForTesting: (@MainActor (String) -> Void)?

    private init(itemId: String, projectURL: URL, store: DocumentStore, table: FigureTable,
                 read: FileRead, locale: TableLocale, names: FormulaNames) {
        self.itemId = itemId
        self.projectURL = projectURL
        self.store = store
        self.state = FigureState(kind: .table, table: table)
        self.separator = TableCSV.rows(read.text).separator
        self.lineEnding = read.lineEnding
        self.hasBOM = read.hasBOM
        self.diskHash = read.hash
        self.locale = locale
        self.names = names
        self.sidecar = read.sidecar
    }

    // MARK: Opening

    /// **Read Research item `itemId`'s table** into a new host — the store's
    /// to call (`DocumentStore.openResearchTable`, one host per item).
    /// Read, never written. Throws `Unreadable` (or the path's refusal) for a
    /// file that is not there or will not decode, `TooLarge` past the limit.
    static func load(itemId: String, store: DocumentStore) async throws -> ResearchTableHost {
        let (read, _) = try await readFile(itemId: itemId, store: store)
        let context = try await store.tableImportContext()
        return ResearchTableHost(
            itemId: itemId, projectURL: store.projectURL, store: store,
            table: table(of: read, context: context), read: read,
            locale: context.locale, names: context.names)
    }

    /// The item's file read off the main actor, and its title.
    private static func readFile(itemId: String, store: DocumentStore) async throws -> (FileRead, String) {
        guard let projectStore = store.projectStore else {
            throw Unreadable(message: "The project isn’t open.")
        }
        guard let item = projectStore.findResearchItem(id: itemId, in: projectStore.manifest.research),
              item.type == .asset, item.kind == .table, let path = item.path else {
            throw Unreadable(message: "This item isn’t a table in Research.")
        }
        let file = try projectStore.resolvedProjectPath(path)
        let projectURL = store.projectURL
        let read = try await Task.detached { () throws -> FileRead in
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw Unreadable(message: "Maugham couldn’t find \(path).")
            }
            let data = try Data(contentsOf: file) // adr-0018-ok: a Research table's CSV, read to edit in the grid; not manuscript
            guard let text = ProjectStore.decodeResearchTable(data) else {
                throw Unreadable(message: "Maugham couldn’t read \(path) as text.")
            }
            let cells = TableCSV.nonEmptyCellCount(text)
            guard cells <= TableCSV.figureCellLimit else { throw TooLarge(cells: cells) }
            // A sidecar that will not read is no sidecar: the table opens as its file reads.
            let sidecar = try? ResearchTableSidecar.read(forItem: itemId, in: projectURL)
            // By scalar: a String holds "\r\n" as one Character.
            let scalars = text.unicodeScalars
            let crlf = scalars.firstIndex(of: "\n").map {
                $0 > scalars.startIndex && scalars[scalars.index(before: $0)] == "\r"
            } ?? false
            return FileRead(text: text, hash: ContentHash.of(data), sidecar: sidecar,
                            hasBOM: data.starts(with: [0xEF, 0xBB, 0xBF]), lineEnding: crlf ? "\r\n" : "\n")
        }.value
        return (read, item.title)
    }

    /// The table a read gives: the sidecar laid on while it was written for these bytes.
    private static func table(of read: FileRead, context: (locale: TableLocale, names: FormulaNames)) -> FigureTable {
        let current = read.sidecar?.contentHash == read.hash ? read.sidecar : nil
        let table = TableCSV.read(
            read.text, locale: context.locale,
            names: current.map { context.names.renaming($0.formulaNames) } ?? context.names).table
        return current.map { $0.applied(to: table) } ?? table
    }

    /// **The table read again from its file** (another writer's change): what
    /// is on disk replaces what is held, and an edit not yet written is
    /// dropped — unless the table is edited while the file is being read, when
    /// nothing is replaced (`reloadUnlessEdited`).
    func reload() async throws {
        _ = try await reloadUnlessEdited()
    }

    /// Test seam: runs in a reload after the file is read and before it lands
    /// — where a test types into the grid.
    static var duringReloadForTesting: (@MainActor (ResearchTableHost) async -> Void)?

    /// The reload; false — nothing replaced — when an edit landed while the
    /// file and the book were read (task 7 re-review N2): that edit is the
    /// writer's, and its save keeps the outside version first (`write`).
    private func reloadUnlessEdited() async throws -> Bool {
        guard let store else { return false }
        let before = state.table
        let (read, _) = try await Self.readFile(itemId: itemId, store: store)
        await Self.duringReloadForTesting?(self)
        let context = try await store.tableImportContext()
        guard state.table == before, !isClosed else { return false }
        scheduledSave?.cancel()
        scheduledSave = nil
        isDirty = false
        sidecar = read.sidecar
        separator = TableCSV.rows(read.text).separator
        lineEnding = read.lineEnding
        hasBOM = read.hasBOM
        diskHash = read.hash
        names = context.names
        state = FigureState(kind: .table, table: Self.table(of: read, context: context))
        return true
    }

    /// **The file may have changed outside Maugham** (the window's file
    /// presenter, a grid's window coming front): a clean grid whose file no
    /// longer hashes to what it read or wrote reads it again, and says so. A
    /// grid holding an edit — or given one while the file is read — is left
    /// to its save, which keeps the outside version first (`write`).
    func fileMayHaveChanged() async {
        await saving?.value
        guard !isClosed, !isDirty, scheduledSave == nil, let store,
              let item = store.projectStore.flatMap({ $0.findResearchItem(id: itemId, in: $0.manifest.research) }),
              let path = item.path, let file = try? store.resolvedProjectPath(path) else { return }
        let lastSave = saving
        let onDisk = try? await Task.detached { try ContentHash.ofFile(file) }.value
        // A save of ours begun meanwhile is no outside change.
        guard let onDisk, onDisk != diskHash, !isDirty, scheduledSave == nil, saving == lastSave else { return }
        do {
            guard try await reloadUnlessEdited() else { return }
            MaughamEvent.postNotice("Reloaded “\(item.title)” — the file changed outside Maugham.",
                                    projectURL: projectURL)
        } catch {
            researchTableLog.error(
                "\(path, privacy: .public) changed outside and did not read again: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Saving

    /// Every edit asked has been written (a pending save now, not later).
    func flush() async {
        scheduledSave?.cancel()
        scheduledSave = nil
        await save()
    }

    /// An open grid's "commit what is typed and let it land", asked by
    /// `settle` (⌘S, ⌘Q, a verb about to read the file).
    func addSettler(_ id: UUID, _ settle: @escaping @MainActor () async -> Void) {
        settlers[id] = settle
    }

    func removeSettler(_ id: UUID) {
        settlers[id] = nil
    }

    /// A grid's visit ending (its open edit committed, its writes landing).
    func addEndingVisit(_ visit: Task<Void, Never>) {
        endingVisits.append(visit)
    }

    /// **Everything asked of this table, written**: visits still ending land
    /// first, each open grid commits what is typed, then any pending save —
    /// `DocumentStore.flushPendingSave`'s wait, so ⌘S, ⌘Q and a window's close
    /// write what the grid was holding.
    ///
    /// `commitOpenEdits` is the writer's own verbs' (⌘S, the window's close and
    /// ⌘Q, Use in Document and Bring Back): a background flush — MCP, search,
    /// a promotion, the typed mover — writes what is committed and leaves a
    /// cell the writer is typing in open (task 7 re-review N1).
    func settle(commitOpenEdits: Bool) async {
        let ending = endingVisits
        for visit in ending { await visit.value }
        endingVisits.removeAll { ending.contains($0) }
        if commitOpenEdits {
            for settle in Array(settlers.values) { await settle() }
        }
        await flush()
    }

    /// The last grid let go (`DocumentStore.releaseResearchTable`): its last
    /// save lands, and nothing more is written.
    func close() async {
        await flush()
        isClosed = true
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

    /// The outside version, the file, then its sidecar, then the cards: what
    /// one save writes.
    private func write(_ table: FigureTable) async {
        guard let store else { return }
        guard let item = store.projectStore.flatMap({ $0.findResearchItem(id: itemId, in: $0.manifest.research) }),
              let path = item.path else {
            MaughamEvent.postNotice("A Research table’s edits couldn’t be saved: it is no longer in Research.",
                                    projectURL: projectURL)
            return
        }
        guard await keepTheOutsideVersion(of: item, at: path) else {
            isDirty = true   // the next edit, or the close, tries again
            return
        }
        // The names its formulas read as they are now; the ones it opened with if they will not read.
        if let fresh = try? await store.formulaNamesForUse() { names = fresh }
        let text = (hasBOM ? "\u{FEFF}" : "") + TableCSV.renderResearch(
            table, locale: locale, names: names, separator: separator, lineEnding: lineEnding)
        do {
            try await store.performFileSave(path: path, text: text)
        } catch {
            isDirty = true
            researchTableLog.error(
                "\(path, privacy: .public) was not saved: \(error.localizedDescription, privacy: .public)")
            MaughamEvent.postNotice("Couldn’t save “\(item.title)”: \(error.localizedDescription)",
                                    projectURL: projectURL)
            return
        }
        diskHash = ContentHash.of(Data(text.utf8))
        var next = ResearchTableSidecar(
            figureId: "", contentHash: diskHash, name: "",
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

    /// **The file changed outside since it was read or written here**: its
    /// bytes are kept as a conflict backup and the writer told, before the
    /// grid's version replaces them. False — write nothing — when they could
    /// not be kept. A file that is gone has nothing to keep.
    private func keepTheOutsideVersion(of item: ResearchItem, at path: String) async -> Bool {
        guard let file = try? store?.resolvedProjectPath(path) else { return true }
        let outside = await Task.detached { () -> Data? in
            try? Data(contentsOf: file) // adr-0018-ok: a Research table's CSV, compared before a save; not manuscript
        }.value
        guard let outside, ContentHash.of(outside) != diskHash else { return true }
        let text = ProjectStore.decodeResearchTable(outside) ?? String(decoding: outside, as: UTF8.self)
        do {
            let backup = try Document.writeConflictBackup(forFileAt: file, docId: itemId, text: text, kind: "outside")
            MaughamEvent.postNotice(
                "“\(item.title)” changed outside Maugham while you were editing it. That version is kept in "
                    + ".maugham/conflicts/\(backup.lastPathComponent); yours was saved.",
                projectURL: projectURL)
            return true
        } catch {
            researchTableLog.error(
                "\(path, privacy: .public)'s outside version was not kept: \(error.localizedDescription, privacy: .public)")
            MaughamEvent.postNotice(
                "“\(item.title)” changed outside Maugham, and that version couldn’t be kept, so your edits weren’t saved over it.",
                projectURL: projectURL)
            return false
        }
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
        register(undoManager, actionName, restoring: prior, over: next)
        scheduleSave()
    }

    /// One step on `undoManager` putting `prior` back over `made`; taken, it
    /// registers the reverse — the redo (and the redo's undo again). Declined,
    /// and said, once the table is no longer `made` (another grid's edit, a
    /// reload): a step never takes back what it did not make.
    private func register(_ undoManager: UndoManager?, _ actionName: String,
                          restoring prior: FigureTable, over made: FigureTable) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] host in
            // The grid's stack is run on the main thread (`undoInGrid`).
            MainActor.assumeIsolated {
                guard !host.isClosed, host.refusal == nil else { return }
                guard host.state.table == made else {
                    return MaughamEvent.postNotice(
                        "Couldn’t undo “\(actionName)”: the table has changed since.", projectURL: host.projectURL)
                }
                host.state.table = prior
                host.register(undoManager, actionName, restoring: made, over: prior)
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
