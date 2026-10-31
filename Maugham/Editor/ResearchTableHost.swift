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
///   since (another grid, a reload).
/// - **`write(_:by:)` is the one door** (report plan 9d, spec §10.1): the only
///   code that writes over a Research CSV (`TripwireGrepTests`' census). Before
///   the file is replaced, the bytes on disk — outside edits included — and
///   the sidecar that described them are kept by `ResearchVersionStore.keep`
///   (this file its one caller), then this device's versions past
///   `ResearchVersionStore.retention` are pruned. Keep THEN save: the bytes
///   kept were on disk, so a save that then fails leaves a version that is a
///   true state (the one still there), never one the table did not reach;
///   staging it until the save landed would lose the prior bytes to a crash
///   between the two. A version that cannot be kept writes nothing.
/// - **The run rule** (`ResearchSaveRun`, the plan's ruling): a writer's saves
///   with no gap over ten minutes, in one host's life (one grid session), keep
///   one version — the state before the run. Every assistant save
///   (`assistantEdit`) keeps one and ends the run; so does bytes on disk that
///   are not ours (an outside change, a reload). Every save stamps the
///   sidecar's `writtenBy`, so the next version says whose bytes it holds,
///   and each version records whose save replaced it (`replacedBy`).
/// - **`restore(_:)`** puts a kept version back as one writer's save through
///   the door, always keeping what it replaces; its undo is the version list
///   (`DocumentStore.restoreResearchTable` reaches it with or without a grid).
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
    /// A Research table carries no notes: its grid never marks a cell.
    var openCellNotes: FigureCellNotes { .none }

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
    /// The writer's editing run: whether the next save keeps a version.
    @ObservationIgnored private(set) var run = ResearchSaveRun()
    /// The run rule's clock (a test sets it; the rule is never timed on the wall).
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
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
            return fileRead(data, text: text, sidecar: sidecar)
        }.value
        return (read, item.title)
    }

    /// A read of `data` (decoded as `text`) and the sidecar found beside it.
    nonisolated private static func fileRead(_ data: Data, text: String, sidecar: ResearchTableSidecar?) -> FileRead {
        // By scalar: a String holds "\r\n" as one Character.
        let scalars = text.unicodeScalars
        let crlf = scalars.firstIndex(of: "\n").map {
            $0 > scalars.startIndex && scalars[scalars.index(before: $0)] == "\r"
        } ?? false
        return FileRead(text: text, hash: ContentHash.of(data), sidecar: sidecar,
                        hasBOM: data.starts(with: [0xEF, 0xBB, 0xBF]), lineEnding: crlf ? "\r\n" : "\n")
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
        run.end()   // what is on disk now is not this run's: the next save keeps it
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
    /// The writer's: an assistant's save is `assistantEdit`'s own.
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

    /// Why an assistant's write was not saved.
    struct NotSaved: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// **An edit made by the assistant** (MCP), saved as its own save marked
    /// `.assistant`: the writer's pending edits are written first, as the
    /// writer's own save, so the two never share one; then `body` changes the
    /// table and it is written at once — keeping the version before it. It
    /// registers no ⌘Z on the grid: its undo is the version list. Refuses as
    /// every edit does. When the save does not land it throws `NotSaved`
    /// with the assistant's cells put back and anything the writer typed
    /// meanwhile kept, to be saved as the writer's (`ResearchAssistantRevert`);
    /// a change that cannot be taken back cell by cell stays and says so.
    func assistantEdit(_ body: (inout FigureTable) throws -> Void) async throws {
        if isClosed { throw Refused(reason: .closed) }
        if let refusal { throw Refused(reason: refusal) }
        // The writer's state lands first; a keystroke during that wait is
        // flushed too. A writer's save that did not land stops the write:
        // the two would otherwise share the assistant's save.
        await flush()
        while scheduledSave != nil { await flush() }
        guard !isDirty else {
            throw NotSaved(message: "The table’s unsaved edits couldn’t be saved first, so the change wasn’t made.")
        }
        if isClosed { throw Refused(reason: .closed) }
        if let refusal { throw Refused(reason: refusal) }
        var next = state.table
        try body(&next)
        guard next != state.table else { return }
        let prior = state.table
        state.table = next
        // Started with no suspension since the table changed: a writer's edit
        // after this point schedules its own save, which waits on this one.
        let previous = saving
        let write = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            guard let self else { return false }
            return await self.write(next, by: .assistant)
        }
        saving = Task { _ = await write.value }
        guard await write.value else {
            guard let back = ResearchAssistantRevert.reverted(state.table, prior: prior, next: next) else {
                throw NotSaved(message: "The table’s change couldn’t be saved. It is still in the table and "
                    + "will be saved with the writer’s next edit, so don’t send it again.")
            }
            // What is left is the writer's own typing (if any): its save is the writer's.
            isDirty = state.table != next
            state.table = back
            throw NotSaved(message: "The table’s change couldn’t be saved, so it wasn’t made.")
        }
    }

    /// How a restore landed: the version whole, or its cells only.
    enum Restored: Equatable {
        /// The version's cells with the header, formats and widths kept with it.
        case whole
        /// The kept sidecar described other bytes (the version was an outside
        /// change), so only the cells came back, as an outside change reads.
        case cellsOnly
    }

    /// **The table put back to a kept version** (report plan 9d Task 3, spec
    /// §10.1's "Restore previous version"): the version's bytes, and the
    /// sidecar kept with them while it was written for those bytes, replace
    /// the whole table as one save stamped `.writer` — through the one door,
    /// which always keeps the state it replaces (even inside the writer's
    /// run) and ends the run. Its undo is the version list, never the grid's
    /// ⌘Z (the plan's ruling): it registers no step, and the grid's earlier
    /// steps decline over it. The writer's pending edits land first as their
    /// own save. A kept sidecar whose `contentHash` is not the version's
    /// bytes' (the version was an outside change) is not laid on: the cells
    /// come back, said, and `.cellsOnly` returned. Refuses as every edit
    /// does; a version that will not read throws what the store throws
    /// (`ResearchVersionStore.ReadError`); a save that does not land throws
    /// `NotSaved` with the table as it was.
    @discardableResult
    func restore(_ version: ResearchVersion) async throws -> Restored {
        if isClosed { throw Refused(reason: .closed) }
        if let refusal { throw Refused(reason: refusal) }
        guard version.itemId == itemId else { throw Unreadable(message: "That version is another table’s.") }
        let versions = ResearchVersionStore(projectURL: projectURL)
        let read = try await Task.detached { () throws -> FileRead in
            let (data, kept) = try versions.read(version)
            guard let text = ProjectStore.decodeResearchTable(data) else {
                throw Unreadable(message: "Maugham couldn’t read that version as text.")
            }
            let cells = TableCSV.nonEmptyCellCount(text)
            guard cells <= TableCSV.figureCellLimit else { throw TooLarge(cells: cells) }
            return ResearchTableHost.fileRead(data, text: text, sidecar: kept)
        }.value
        guard let store else { throw Refused(reason: .closed) }
        let context = try await store.tableImportContext()
        // The writer's state lands first, as its own save (a keystroke during
        // that wait too); one that did not land stops the restore.
        await flush()
        while scheduledSave != nil { await flush() }
        guard !isDirty else {
            throw NotSaved(message: "The table’s unsaved edits couldn’t be saved first, so the version wasn’t restored.")
        }
        if isClosed { throw Refused(reason: .closed) }
        if let refusal { throw Refused(reason: refusal) }
        // A sidecar kept for other bytes is not laid on (`table(of:)`), as an outside change reads.
        let outcome: Restored
        if let kept = read.sidecar, kept.contentHash != read.hash {
            outcome = .cellsOnly
        } else {
            outcome = .whole
        }
        let restored = Self.table(of: read, context: context)
        let priorTable = state.table
        let priorFile = (separator, lineEnding, hasBOM)
        let restoredSeparator = TableCSV.rows(read.text).separator
        // The table is that version already: nothing is written, nothing kept.
        if restored == priorTable, priorFile == (restoredSeparator, read.lineEnding, read.hasBOM) { return outcome }
        separator = restoredSeparator
        lineEnding = read.lineEnding
        hasBOM = read.hasBOM
        state.table = restored
        // Started with no suspension since the table changed, as an assistant's write is.
        let previous = saving
        let write = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            guard let self else { return false }
            return await self.write(restored, by: .writer, restoring: true)
        }
        saving = Task { _ = await write.value }
        guard await write.value else {
            guard state.table == restored else {
                throw NotSaved(message: "The version couldn’t be restored. What is in the table now "
                    + "will be saved with your next edit.")
            }
            state.table = priorTable
            (separator, lineEnding, hasBOM) = priorFile
            isDirty = false
            throw NotSaved(message: "The version couldn’t be restored, so the table is as it was.")
        }
        if outcome == .cellsOnly {
            let title = store.projectStore.flatMap { $0.findResearchItem(id: itemId, in: $0.manifest.research) }?
                .title ?? "the table"
            MaughamEvent.postNotice(
                "Restored “\(title)”’s cells. The formats kept with that version were for other bytes "
                    + "(it had changed outside Maugham), so they weren’t applied.",
                projectURL: projectURL)
        }
        return outcome
    }

    /// The words for whose change a refused save did not write.
    private static func whose(_ writer: ResearchWriter, restoring: Bool) -> String {
        if restoring { return "the restored version wasn’t" }
        switch writer {
        case .writer: return "your edits weren’t"
        case .assistant: return "the assistant’s change wasn’t"
        }
    }

    /// An outside version kept as a conflict backup by a save that has not
    /// landed yet: a retry over the same bytes keeps no second, and the
    /// writer is told once the save lands.
    @ObservationIgnored private var pendingOutsideBackup: (hash: String, file: URL)?
    /// The hash of the bytes this host last kept as a version: a keep of the
    /// same bytes again (a retry after a failed save) keeps nothing.
    @ObservationIgnored private var lastKeptHash: String?

    /// **The one door: the version kept, the file, then its sidecar, then
    /// the cards** — what one save writes, `writer` its author. A restore
    /// (`restoring`) always keeps the state it replaces and ends the run.
    /// True when the file was written.
    @discardableResult
    private func write(_ table: FigureTable, by writer: ResearchWriter = .writer,
                       restoring: Bool = false) async -> Bool {
        guard let store else { return false }
        guard let item = store.projectStore.flatMap({ $0.findResearchItem(id: itemId, in: $0.manifest.research) }),
              let path = item.path else {
            MaughamEvent.postNotice("A Research table’s edits couldn’t be saved: it is no longer in Research.",
                                    projectURL: projectURL)
            return false
        }
        // A file that has gone (another Mac trashed it, and this manifest has
        // not caught up) is not made again: the edits are dropped and said
        // (task 7 re-review R2-2).
        guard await fileIsThere(at: path) else {
            MaughamEvent.postNotice(
                "“\(item.title)” isn’t there any more, so its edits weren’t saved.", projectURL: projectURL)
            return false
        }
        // A file that is there but will not read cannot be kept: nothing is written over it.
        guard let onDisk = await bytesOnDisk(at: path) else {
            isDirty = true
            MaughamEvent.postNotice(
                "Maugham couldn’t read “\(item.title)” to keep its previous version, so \(Self.whose(writer, restoring: restoring)) saved over it.",
                projectURL: projectURL)
            return false
        }
        let onDiskHash = ContentHash.of(onDisk)
        let overOwnBytes = onDiskHash == diskHash
        if !overOwnBytes, pendingOutsideBackup?.hash != onDiskHash {
            guard let backup = keepTheOutsideVersion(onDisk, of: item, at: path, by: writer, restoring: restoring) else {
                isDirty = true   // the next edit, or the close, tries again
                return false
            }
            pendingOutsideBackup = (onDiskHash, backup)
        }
        let at = now()
        var kept = false
        if restoring || run.keepsAVersion(by: writer, at: at, overOwnBytes: overOwnBytes), onDiskHash != lastKeptHash {
            guard await keepThePriorVersion(onDisk, of: item, at: at, by: writer, restoring: restoring) else {
                isDirty = true
                return false
            }
            lastKeptHash = onDiskHash
            kept = true
            // The inspector's list reloads only when it has a version to show (M1).
            store.researchVersionsRevision += 1
        }
        // Counted once the version is kept, saved or not: a retry after a
        // failed save is still the run whose start is kept. A restore ends it.
        if restoring { run.end() } else { run.saved(by: writer, at: at) }
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
            return false
        }
        diskHash = ContentHash.of(Data(text.utf8))
        if let backup = pendingOutsideBackup {
            pendingOutsideBackup = nil
            let (when, saved) = restoring ? ("", "the restored version was saved")
                : writer == .writer ? (" while you were editing it", "yours was saved")
                : ("", "the assistant’s change was saved")
            MaughamEvent.postNotice(
                "“\(item.title)” changed outside Maugham\(when). That version is kept in "
                    + ".maugham/conflicts/\(backup.file.lastPathComponent); \(saved).",
                projectURL: projectURL)
        }
        var next = ResearchTableSidecar(
            figureId: "", contentHash: diskHash, name: "",
            caption: sidecar?.caption, table: table, formulaNames: names.cited(by: table))
        next.figureId = sidecar?.figureId
        next.name = sidecar?.name
        next.writtenBy = writer
        do {
            try ResearchTableSidecar.write(next, forItem: itemId, in: projectURL)
            sidecar = next
        } catch {
            researchTableLog.error(
                "\(path, privacy: .public)'s sidecar was not written: \(error.localizedDescription, privacy: .public)")
        }
        store.invalidateFigureCards()
        if restoring, !kept { store.researchVersionsRevision += 1 }
        Self.wroteForTesting?(text)
        return true
    }

    /// Whether the item's file (or a link where it was) is on disk.
    private func fileIsThere(at path: String) async -> Bool {
        guard let file = try? store?.resolvedProjectPath(path) else { return false }
        return await Task.detached {
            (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil
        }.value
    }

    /// The item's file's bytes as they are now; nil when it will not read.
    private func bytesOnDisk(at path: String) async -> Data? {
        guard let file = try? store?.resolvedProjectPath(path) else { return nil }
        return await Task.detached { () -> Data? in
            try? Data(contentsOf: file) // adr-0018-ok: a Research table's CSV, compared and kept before a save; not manuscript
        }.value
    }

    /// **The bytes about to be replaced, kept as a version** with the sidecar
    /// that described them (the one on disk, else the one held), their
    /// author when that sidecar was written for these bytes, and `writer` as
    /// whose save replaces them (`replaced_by`); then this
    /// device's versions past the retention are pruned. False — write nothing
    /// — when the version could not be kept, and said.
    private func keepThePriorVersion(_ prior: Data, of item: ResearchItem, at date: Date,
                                     by writer: ResearchWriter, restoring: Bool) async -> Bool {
        let held = sidecar
        let itemId = itemId
        let versions = ResearchVersionStore(projectURL: projectURL)
        let projectURL = projectURL
        let device = DeviceIdentity.author.slug
        let kept: Error? = await Task.detached { () -> Error? in
            let described = (try? ResearchTableSidecar.read(forItem: itemId, in: projectURL)) ?? held
            let author = described?.contentHash == ContentHash.of(prior) ? described?.writtenBy : nil
            do {
                try versions.keep(priorBytes: prior, priorSidecar: described, writtenBy: author, replacedBy: writer,
                                  itemId: itemId, device: device, at: date)
            } catch {
                return error
            }
            versions.prune(itemId: itemId, device: device)
            return nil
        }.value
        guard let kept else { return true }
        researchTableLog.error(
            "\(item.title, privacy: .public)'s previous version was not kept: \(kept.localizedDescription, privacy: .public)")
        MaughamEvent.postNotice(
            "“\(item.title)”’s previous version couldn’t be kept, so \(Self.whose(writer, restoring: restoring)) saved over it.",
            projectURL: projectURL)
        return false
    }

    /// **The file changed outside since it was read or written here**: its
    /// bytes are kept as a conflict backup before the save replaces them (the
    /// writer is told once the save lands). Nil — write nothing — when they
    /// could not be kept, and said.
    private func keepTheOutsideVersion(_ outside: Data, of item: ResearchItem, at path: String,
                                       by writer: ResearchWriter, restoring: Bool) -> URL? {
        guard let file = try? store?.resolvedProjectPath(path) else { return nil }
        let text = ProjectStore.decodeResearchTable(outside) ?? String(decoding: outside, as: UTF8.self)
        do {
            return try Document.writeConflictBackup(forFileAt: file, docId: itemId, text: text, kind: "outside")
        } catch {
            researchTableLog.error(
                "\(path, privacy: .public)'s outside version was not kept: \(error.localizedDescription, privacy: .public)")
            MaughamEvent.postNotice(
                "“\(item.title)” changed outside Maugham, and that version couldn’t be kept, so \(Self.whose(writer, restoring: restoring)) saved over it.",
                projectURL: projectURL)
            return nil
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

    // A Research table carries no notes (`openCellNotes` is `.none`), so its
    // strip is never shown and any note asked about is unknown here.
    func acceptSuggestion(id: String, confirmChanged: Bool, undoManager: UndoManager?) async throws {
        throw FigureNoteError.unknownNote
    }
    func acceptNote(id: String, userResponse: String?, undoManager: UndoManager?) async throws {
        throw FigureNoteError.unknownNote
    }
    func rejectAnnotation(id: String, reason: String?, undoManager: UndoManager?) async throws {
        throw FigureNoteError.unknownNote
    }

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

/// **A writer's editing run** (report plan 9d's ruling on what a "save" is):
/// the writer's consecutive saves with no gap over `gap`, in one host's life,
/// keep one version — the state before the run. An assistant's save always
/// keeps one and ends the run, and so do bytes on disk that are not this
/// host's own last write (an outside change, a reload).
struct ResearchSaveRun: Equatable {
    /// The longest pause between two of the writer's saves inside one run.
    static let gap: TimeInterval = 10 * 60

    /// When the writer's last save in the run was; nil — no run.
    private(set) var lastWriterSave: Date?

    /// Whether a save by `writer` at `date`, over bytes that are
    /// (`overOwnBytes`) or are not this host's last write, keeps a version.
    func keepsAVersion(by writer: ResearchWriter, at date: Date, overOwnBytes: Bool) -> Bool {
        guard writer == .writer, overOwnBytes, let lastWriterSave else { return true }
        return date.timeIntervalSince(lastWriterSave) > Self.gap
    }

    /// A save by `writer` at `date`: the writer's continues (or begins) the
    /// run, the assistant's ends it.
    mutating func saved(by writer: ResearchWriter, at date: Date) {
        lastWriterSave = writer == .writer ? date : nil
    }

    /// What is on disk is no longer this run's (a reload).
    mutating func end() { lastWriterSave = nil }
}

/// **An assistant's change taken back cell by cell** when its save did not
/// land (`ResearchTableHost.assistantEdit`): every cell, setting and width
/// it changed from `prior` to `next` that `current` still holds as `next`
/// left it goes back to `prior`'s, and a row or column it added goes unless
/// the writer has typed in it since. What the writer changed meanwhile stays.
/// Nil when the change deleted or reordered rows or columns — nothing here
/// puts those back (the assistant's writes add, never delete or move).
enum ResearchAssistantRevert {
    static func reverted(_ current: FigureTable, prior: FigureTable, next: FigureTable) -> FigureTable? {
        let priorRows = Set(prior.rows), priorColumns = Set(prior.columns)
        guard priorRows.isSubset(of: Set(next.rows)), priorColumns.isSubset(of: Set(next.columns)),
              next.rows.filter(priorRows.contains) == prior.rows,
              next.columns.filter(priorColumns.contains) == prior.columns else { return nil }
        if current == next { return prior }   // nothing typed since: exactly as it was
        var table = current
        let addedRows = next.rows.filter { !priorRows.contains($0) }
        let addedColumns = next.columns.filter { !priorColumns.contains($0) }
        // A cell the assistant set that the writer has not touched since goes back.
        for row in next.rows {
            for column in next.columns {
                let key = CellKey(row: row, column: column)
                guard next[key] != prior[key], table.rowIndex(of: row) != nil,
                      table.columnIndex(of: column) != nil, table[key] == next[key] else { continue }
                table.setCell(priorRows.contains(row) && priorColumns.contains(column) ? prior[key] : nil, at: key)
            }
        }
        // An added row or column the writer left empty goes.
        for row in addedRows where table.rowIndex(of: row) != nil
            && table.columns.allSatisfy({ table[CellKey(row: row, column: $0)] == nil }) {
            table.deleteRow(row)
        }
        for column in addedColumns where table.columnIndex(of: column) != nil
            && table.rows.allSatisfy({ table[CellKey(row: $0, column: column)] == nil }) {
            table.deleteColumn(column)
        }
        if table.headerRows == next.headerRows { table.headerRows = prior.headerRows }
        if table.hasTotalRow == next.hasTotalRow { table.hasTotalRow = prior.hasTotalRow }
        for column in Set(prior.columns).union(next.columns)
            where table.columnIndex(of: column) != nil && table.columnWidths[column] == next.columnWidths[column] {
            table.columnWidths[column] = prior.columnWidths[column]
        }
        return table
    }
}
