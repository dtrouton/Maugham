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
///   changed while the grid holds no edit → read again and said, and the
///   figure cards told (`fileMayHaveChanged`, from the window's file
///   presenter); changed under a
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
        /// What was refused: "table", or "note" for a note's restore.
        var noun = "table"
        var errorDescription: String? { reason.sentence(noun: noun) }
    }

    /// Why a Research table could not be opened in the grid.
    struct Unreadable: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// A table let go by another caller each time it was opened for this
    /// one (`DocumentStore.openResearchTable` opens it twice, then says so).
    struct ClosedWhileOpening: LocalizedError, Equatable {
        var errorDescription: String? {
            "This table was closed while it was being opened. Open it again."
        }
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
    /// The sidecar for the CSV now on disk whose write failed; the next save
    /// writes it alone (the CSV did save, so the host is not dirty).
    @ObservationIgnored private(set) var pendingSidecar: ResearchTableSidecar?
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
    /// Test seam: replaces the sidecar write, so a test can make it fail.
    static var sidecarWriteForTesting: (@MainActor (ResearchTableSidecar) throws -> Void)?
    /// Test seam: replaces the outside version's backup (nil: it could not be
    /// kept), so a test can fail it while the unsaved backup beside it lands.
    static var outsideBackupForTesting: (@MainActor (Data) -> URL?)?

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
        let host = ResearchTableHost(
            itemId: itemId, projectURL: store.projectURL, store: store,
            table: table(of: read, context: context), read: read,
            locale: context.locale, names: context.names)
        await Self.duringLoadForTesting?()
        return host
    }

    /// Test seam: runs in a load after the host is built and before it is
    /// handed back — where a test holds the store's shared opening while
    /// other callers come and go (`DocumentStore.openResearchTable`).
    static var duringLoadForTesting: (@MainActor () async -> Void)?

    /// The item's file read off the main actor, and its title.
    private static func readFile(itemId: String, store: DocumentStore) async throws -> (FileRead, String) {
        guard let projectStore = store.projectStore else {
            throw Unreadable(message: "The project isn’t open.")
        }
        // A table outside a research root (a synced manifest's `.table`
        // naming the manuscript or a `.maugham/` file) is not opened.
        guard let item = projectStore.findResearchItem(id: itemId, in: projectStore.manifest.research),
              let path = ResearchTextRole.tablePath(of: item, structure: projectStore.manifest.structure) else {
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

    /// **A write is in flight**: set as a save's body begins (`write`),
    /// cleared as it ends. No reload lands while it is set (final review G3).
    @ObservationIgnored private(set) var writeInFlight = false
    /// How many writes have begun: a reload that read the file before one
    /// began does not land after it.
    @ObservationIgnored private var writesBegun = 0

    /// Test seam: runs in a reload after the file is read and before it lands
    /// — where a test types into the grid.
    static var duringReloadForTesting: (@MainActor (ResearchTableHost) async -> Void)?

    /// What a reload did.
    private enum Reloaded {
        /// The file's table replaced the one held.
        case replaced
        /// Nothing replaced: an edit landed while the file and the book were
        /// read (or the host closed). That edit's save keeps the outside
        /// version first (`write`).
        case edited
        /// Nothing replaced: a write was in flight, or began, while the file
        /// was read — what was read may be older than what it writes.
        case writing
    }

    /// The reload; nothing replaced when an edit landed while the file and
    /// the book were read (task 7 re-review N2): that edit is the writer's,
    /// and its save keeps the outside version first (`write`). **Nor over a
    /// write in flight, or one begun since the file was read here** (final
    /// review G3): the grid would show the outside table while the write puts
    /// the writer's on disk. The caller asks again once the write has ended.
    private func reloadUnlessEdited() async throws -> Reloaded {
        guard let store else { return .edited }
        guard !writeInFlight else { return .writing }
        let before = state.table
        let begun = writesBegun
        let (read, _) = try await Self.readFile(itemId: itemId, store: store)
        await Self.duringReloadForTesting?(self)
        let context = try await store.tableImportContext()
        guard !writeInFlight, writesBegun == begun else { return .writing }
        guard state.table == before, !isClosed else { return .edited }
        scheduledSave?.cancel()
        scheduledSave = nil
        isDirty = false
        keptAside = nil        // what is held now is the file's
        pendingSidecar = nil   // it described bytes that are gone
        run.end()   // what is on disk now is not this run's: the next save keeps it
        sidecar = read.sidecar
        separator = TableCSV.rows(read.text).separator
        lineEnding = read.lineEnding
        hasBOM = read.hasBOM
        diskHash = read.hash
        names = context.names
        state = FigureState(kind: .table, table: Self.table(of: read, context: context))
        // A figure pinning this table reads the file just read: its card
        // follows the grid on screen (sweep 11-01 S2, #131).
        store.invalidateFigureCards()
        return .replaced
    }

    /// **The file may have changed outside Maugham** (the window's file
    /// presenter, a grid's window coming front): a clean grid whose file no
    /// longer hashes to what it read or wrote reads it again, and says so. A
    /// grid holding an edit — or given one while the file is read — is left
    /// to its save, which keeps the outside version first (`write`).
    ///
    /// **Never while a write is in flight** (final review G3): every save
    /// asked is waited for — one queued behind the save seen at entry too —
    /// and a reload a write overtook is refused (`reloadUnlessEdited`) and
    /// asked again here once that write has ended, so an outside change
    /// landing after it is still read.
    func fileMayHaveChanged() async {
        while true {
            // Every save asked so far has ended: each waits on the one before it.
            var waited: Task<Void, Never>?
            while let last = saving, last != waited {
                waited = last
                await last.value
            }
            guard !isClosed, !isDirty, !writeInFlight, scheduledSave == nil, let store,
                  let item = store.projectStore.flatMap({ $0.findResearchItem(id: itemId, in: $0.manifest.research) }),
                  let path = item.path, let file = try? store.resolvedProjectPath(path) else { return }
            let lastSave = saving
            let onDisk = try? await Task.detached { try ContentHash.ofFile(file) }.value
            // A save of ours begun meanwhile is no outside change: it is
            // waited for, and the file asked about again.
            guard saving == lastSave, !writeInFlight else { continue }
            guard let onDisk, onDisk != diskHash, !isDirty, scheduledSave == nil else { return }
            do {
                switch try await reloadUnlessEdited() {
                case .replaced:
                    MaughamEvent.postNotice("Reloaded “\(item.title)” — the file changed outside Maugham.",
                                            projectURL: projectURL)
                    return
                case .edited:
                    return
                case .writing:
                    continue
                }
            } catch {
                researchTableLog.error(
                    "\(path, privacy: .public) changed outside and did not read again: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    // MARK: Saving

    /// **Which kind of save `write` is** (hardening 11-11 R1, after
    /// `ResearchNoteDoor.SaveSource`): the debounced save, a flush that
    /// commits the held edits for the last time or on the writer's say-so,
    /// or a save the caller answers for itself. A `.flush` never drops the
    /// edits (ruling R-C): saved anyway, or kept aside and said (`write`).
    enum SaveSource: Equatable {
        /// The debounced save (`scheduleSave`).
        case timer
        /// `settle` (⌘S, ⌘Q, a window's close), the grid's leave, `close()`.
        case flush
        /// `assistantEdit`, `restore`, and the pre-flush each runs to land
        /// the writer's pending edits (`landPendingEdits`).
        case direct
    }

    /// **What one save did**: wrote the file; refused, and why — every
    /// refusal leaves the host dirty, and says so once (`noStore` silently);
    /// or, a `.flush` only, kept the edits aside where they could not be
    /// written. The two flush arms leave the host dirty (the edits are still
    /// not in the file) and remember what they kept, so a second flush on the
    /// way out keeps no second copy and says nothing again.
    enum WriteOutcome: Equatable {
        case wrote
        case refused(Refusal)
        /// A flush that could not write: the table's CSV is kept as this
        /// conflict backup; the host stays dirty (an `-unsaved-` `.csv` under `.maugham/conflicts`), and said.
        case keptAside(URL)
        /// A flush that could not write, whose backup failed too: said in
        /// plain words.
        case notKept

        enum Refusal: Equatable {
            /// The `DocumentStore` has gone.
            case noStore
            /// The item (or its path) is no longer in Research.
            case itemGone
            /// The research-root guard (`ResearchTextRole.tablePath`) refuses the path.
            case outsideResearch
            /// The file has gone (another Mac trashed it): it is not made again.
            case fileGone
            /// The file is there but will not read, so its prior version cannot be kept.
            case priorUnreadable
            /// The file changed outside, and that version could not be backed up.
            case outsideVersionNotKept
            /// The prior version could not be kept.
            case versionNotKept
            /// The file save itself failed.
            case saveFailed
        }
    }

    /// Every edit asked has been written (a pending save now, not later).
    func flush() async {
        scheduledSave?.cancel()
        scheduledSave = nil
        await save(source: .flush)
    }

    /// The debounced save, run now with no sleep (the scheduled one cancelled).
    func saveAsTheTimerForTesting() async {
        scheduledSave?.cancel()
        scheduledSave = nil
        await save(source: .timer)
    }

    /// **The writer's pending edits landed first** by `assistantEdit` and
    /// `restore`, as the writer's own save: a refusal leaves the host dirty,
    /// which stops the caller.
    @discardableResult
    private func landPendingEdits() async -> WriteOutcome {
        scheduledSave?.cancel()
        scheduledSave = nil
        return await save(source: .direct)
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
            await self.save(source: .timer)
        }
    }

    /// One save at a time, in the order asked; nothing when nothing changed
    /// (`.wrote`). The writer's: an assistant's save is `assistantEdit`'s own.
    /// Marked clean as the write begins, so an edit made during it marks the
    /// host dirty again; a refusal, or a flush that kept the edits aside,
    /// marks it dirty (`write`): clean iff it wrote.
    @discardableResult
    private func save(source: SaveSource) async -> WriteOutcome {
        let previous = saving
        let task = Task { @MainActor [weak self] () -> WriteOutcome in
            await previous?.value
            guard let self else { return .refused(.noStore) }
            guard self.isDirty else { self.retryPendingSidecar(); return .wrote }
            self.isDirty = false
            return await self.write(self.state.table, source: source)
        }
        saving = Task { _ = await task.value }
        return await task.value
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
        await landPendingEdits()
        while scheduledSave != nil { await landPendingEdits() }
        guard !isDirty else {
            throw NotSaved(message: "The table’s unsaved edits couldn’t be saved first, so the change wasn’t made. "
                + "Don’t send it again; ask the writer to save or reopen the table.")
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
        let write = Task { @MainActor [weak self] () -> WriteOutcome in
            await previous?.value
            guard let self else { return .refused(.noStore) }
            return await self.write(next, by: .assistant, source: .direct)
        }
        saving = Task { _ = await write.value }
        guard await write.value == .wrote else {
            guard let back = ResearchAssistantRevert.reverted(state.table, prior: prior, next: next) else {
                throw NotSaved(message: "The table’s change couldn’t be saved. It is still in the table and "
                    + "will be saved with the writer’s next save, so don’t send it again.")
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
        await landPendingEdits()
        while scheduledSave != nil { await landPendingEdits() }
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
        let write = Task { @MainActor [weak self] () -> WriteOutcome in
            await previous?.value
            guard let self else { return .refused(.noStore) }
            return await self.write(restored, by: .writer, restoring: version.name, source: .direct)
        }
        saving = Task { _ = await write.value }
        guard await write.value == .wrote else {
            guard state.table == restored else {
                throw NotSaved(message: "The version couldn’t be restored. What is in the table now "
                    + "will be saved with your next save.")
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

    /// The outside versions kept as conflict backups by a save that has not
    /// landed yet: a retry over the same bytes keeps no second, and the
    /// writer is told once the save lands. More than one when the file
    /// changed again between a read and its write (#138 R3): each is named.
    @ObservationIgnored private var pendingOutsideBackups: [(hash: String, file: URL)] = []
    /// The hash of the bytes this host last kept as a version: a keep of the
    /// same bytes again (a retry after a failed save) keeps nothing.
    @ObservationIgnored private var lastKeptHash: String?
    /// **What a flush last kept aside** (fix round 1): the hash of the CSV
    /// text, and its backup — nil when the backup failed and that was said.
    /// A flush of the same text keeps no second copy and says nothing again;
    /// one whose backup failed retries it silently. Cleared when a write
    /// lands or the file is read again.
    @ObservationIgnored private var keptAside: (hash: String, file: URL?)?

    /// **The one door: the version kept, the file, then its sidecar, then
    /// the cards** — what one save writes, `writer` its author. A restore
    /// (`restoring`) always keeps the state it replaces and ends the run.
    /// Says what it did: `.wrote`, or why not — and every refusal leaves the
    /// host dirty (the next edit, a flush or the close tries again) and is
    /// said once, `noStore` silently. `source` is which save this is
    /// (`SaveSource`). **A `.flush` never drops the edits** (ruling R-C, the
    /// note door's rule): a version that cannot be kept is saved over anyway;
    /// any other arm writes nothing over the file and keeps the table's CSV
    /// aside (`keepTheFlushedTable`), the host still dirty. **The file is
    /// written only if it still holds the bytes read here** (#138 R3,
    /// `FileExpectation`): bytes another program or Mac put there after the
    /// read make the door run again from its read, once (`secondRead`), so
    /// they take the outside-change branch; a second change is `saveFailed`.
    private func write(_ table: FigureTable, by writer: ResearchWriter = .writer,
                       restoring: String? = nil, source: SaveSource, secondRead: Bool = false) async -> WriteOutcome {
        // In flight from here to its end (G3). Saves are one at a time
        // (`saving`), so the flag is one write's; its second pass is inside it.
        if !secondRead {
            writeInFlight = true
            writesBegun += 1
        }
        defer { if !secondRead { writeInFlight = false } }
        func refused(_ why: WriteOutcome.Refusal) -> WriteOutcome {
            isDirty = true
            return .refused(why)
        }
        let flushing = source == .flush
        guard let store else { return refused(.noStore) }
        guard let item = store.projectStore.flatMap({ $0.findResearchItem(id: itemId, in: $0.manifest.research) }),
              let path = item.path else {
            if flushing {
                return await keepTheFlushedTable(table, couldNot: "Couldn’t save a Research table: it is no longer in Research.",
                                           anchor: backupAnchor(nil))
            }
            MaughamEvent.postNotice("A Research table’s edits couldn’t be saved: it is no longer in Research.",
                                    projectURL: projectURL)
            return refused(.itemGone)
        }
        // **Only inside a research root** (`ResearchTextRole.tablePath`),
        // asked of the manifest now: one synced since the table opened can
        // name the manuscript or a `.maugham/` file. Nothing is kept or
        // written there; the timer's edits stay unsaved, a flush's are kept
        // aside, and said.
        guard ResearchTextRole.tablePath(of: item, structure: store.projectStore?.manifest.structure ?? []) == path else {
            researchTableLog.error("\(path, privacy: .public) is not inside Research; the table door wrote nothing")
            if flushing {
                return await keepTheFlushedTable(table, couldNot: "Couldn’t save “\(item.title)”: it isn’t a table inside Research any more.",
                                           anchor: backupAnchor(path))
            }
            MaughamEvent.postNotice(
                "“\(item.title)” isn’t a table inside Research any more, so \(Self.whose(writer, restoring: restoring != nil)) saved.",
                projectURL: projectURL)
            return refused(.outsideResearch)
        }
        // A file that has gone (another Mac trashed it, and this manifest has
        // not caught up) is not made again (task 7 re-review R2-2): the timer's
        // edits wait, and it is said; a flush's are kept aside and said.
        guard await fileIsThere(at: path) else {
            if flushing {
                return await keepTheFlushedTable(table, couldNot: "Couldn’t save “\(item.title)”: it isn’t there any more.",
                                           anchor: backupAnchor(path))
            }
            MaughamEvent.postNotice(
                "“\(item.title)” isn’t there any more, so its edits weren’t saved.", projectURL: projectURL)
            return refused(.fileGone)
        }
        // A file that is there but will not read cannot be kept: nothing is written over it.
        guard let onDisk = await bytesOnDisk(at: path) else {
            if flushing {
                return await keepTheFlushedTable(
                    table, couldNot: "Couldn’t save “\(item.title)”: Maugham couldn’t read it to keep its previous version.",
                    anchor: backupAnchor(path))
            }
            MaughamEvent.postNotice(
                "Maugham couldn’t read “\(item.title)” to keep its previous version, so \(Self.whose(writer, restoring: restoring != nil)) saved over it.",
                projectURL: projectURL)
            return refused(.priorUnreadable)
        }
        let onDiskHash = ContentHash.of(onDisk)
        let overOwnBytes = onDiskHash == diskHash
        if !overOwnBytes, !pendingOutsideBackups.contains(where: { $0.hash == onDiskHash }) {
            guard let backup = keepTheOutsideVersion(onDisk, of: item, at: path, by: writer, restoring: restoring != nil,
                                                     source: source) else {
                if flushing {
                    return await keepTheFlushedTable(
                        table, couldNot: "Couldn’t save “\(item.title)”: it changed outside Maugham, and that version couldn’t be kept.",
                        anchor: backupAnchor(path))
                }
                return refused(.outsideVersionNotKept)
            }
            pendingOutsideBackups.append((onDiskHash, backup))
        }
        let at = now()
        var kept = false, savedAnyway = false
        if restoring != nil || run.keepsAVersion(by: writer, at: at, overOwnBytes: overOwnBytes), onDiskHash != lastKeptHash {
            if await keepThePriorVersion(onDisk, of: item, at: at, by: writer, restoring: restoring, source: source) {
                lastKeptHash = onDiskHash
                kept = true
                // The inspector's list reloads only when it has a version to show (M1).
                store.researchVersionsRevision += 1
            } else if flushing {
                // Saved anyway (the notes' rule, `ResearchNoteDoor.whenTheKeepFails`), said once it lands.
                savedAnyway = true
            } else {
                return refused(.versionNotKept)
            }
        }
        // Counted once the version is kept, saved or not: a retry after a
        // failed save is still the run whose start is kept. A restore ends it.
        if restoring != nil { run.end() } else { run.saved(by: writer, at: at) }
        // The names its formulas read as they are now; the ones it opened with if they will not read.
        if let fresh = try? await store.formulaNamesForUse() { names = fresh }
        let text = csvText(table)
        do {
            try await store.performFileSave(path: path, text: text, expecting: .bytesHashing(onDiskHash))
        } catch FileSaveError.changedSinceRead where !secondRead {
            // Written outside after the read above: nothing was written over
            // it. The door runs again from its read, so those bytes are kept
            // (the outside-change branch) before the table is saved.
            researchTableLog.error("\(path, privacy: .public) changed after it was read; reading it again")
            return await write(table, by: writer, restoring: restoring, source: source, secondRead: true)
        } catch {
            researchTableLog.error(
                "\(path, privacy: .public) was not saved: \(error.localizedDescription, privacy: .public)")
            let couldNot = "Couldn’t save “\(item.title)”: \(error.localizedDescription)"
            // A flush may have no later retry (⌘Q): nothing more is written over the file.
            if flushing { return await keepTheFlushedTable(table, couldNot: couldNot, anchor: backupAnchor(path)) }
            MaughamEvent.postNotice(couldNot, projectURL: projectURL)
            return refused(.saveFailed)
        }
        diskHash = ContentHash.of(Data(text.utf8))
        keptAside = nil   // the edits are on disk: a backup kept earlier simply remains
        if savedAnyway {
            MaughamEvent.postNotice("“\(item.title)”’s previous version couldn’t be kept; your edits were saved anyway.",
                                    projectURL: projectURL)
        }
        if !pendingOutsideBackups.isEmpty {
            let files = pendingOutsideBackups.map { ".maugham/conflicts/\($0.file.lastPathComponent)" }
            pendingOutsideBackups = []
            let (when, saved) = restoring != nil ? ("", "the restored version was saved")
                : writer == .writer ? (" while you were editing it", "yours was saved")
                : ("", "the assistant’s change was saved")
            let kept = files.count == 1 ? "That version is kept in \(files[0])"
                : "Those versions are kept in " + files.dropLast().joined(separator: ", ") + " and " + files[files.count - 1]
            MaughamEvent.postNotice(
                "“\(item.title)” changed outside Maugham\(when). \(kept); \(saved).",
                projectURL: projectURL)
        }
        var next = ResearchTableSidecar(
            figureId: "", contentHash: diskHash, name: "",
            caption: sidecar?.caption, table: table, formulaNames: names.cited(by: table))
        next.figureId = sidecar?.figureId
        next.name = sidecar?.name
        next.writtenBy = writer
        do {
            try writeSidecar(next)
            sidecar = next
            pendingSidecar = nil
        } catch {
            // The CSV saved, so the host stays clean (an outside change is still
            // adopted); only the sidecar is kept to write again at the next save.
            pendingSidecar = next
            researchTableLog.error(
                "\(path, privacy: .public)'s sidecar was not written: \(error.localizedDescription, privacy: .public)")
            MaughamEvent.postNotice(
                "Couldn’t save the formatting of “\(item.title)”: \(error.localizedDescription). Maugham will try again on the next save.",
                projectURL: projectURL)
        }
        store.invalidateFigureCards()
        if restoring != nil, !kept { store.researchVersionsRevision += 1 }
        Self.wroteForTesting?(text)
        return .wrote
    }

    private func writeSidecar(_ next: ResearchTableSidecar) throws {
        if let seam = Self.sidecarWriteForTesting {
            try seam(next)
        } else {
            try ResearchTableSidecar.write(next, forItem: itemId, in: projectURL)
        }
    }

    /// Writes the sidecar a failed save left, if it still describes the file
    /// on disk. A repeat failure is logged, not said again.
    private func retryPendingSidecar() {
        guard let pending = pendingSidecar else { return }
        guard pending.contentHash == diskHash else { pendingSidecar = nil; return }
        do {
            try writeSidecar(pending)
            sidecar = pending
            pendingSidecar = nil
            store?.invalidateFigureCards()
        } catch {
            researchTableLog.error(
                "\(self.itemId, privacy: .public)'s sidecar was not written again: \(error.localizedDescription, privacy: .public)")
        }
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
    /// device's versions past the retention are pruned, sparing the version
    /// just made and, for a restore, the one being restored (`restoring`, its
    /// file name). False when the
    /// version could not be kept, and said: the save stops, or a flush's is
    /// made anyway.
    private func keepThePriorVersion(_ prior: Data, of item: ResearchItem, at date: Date,
                                     by writer: ResearchWriter, restoring: String?, source: SaveSource) async -> Bool {
        let held = sidecar
        let itemId = itemId
        let versions = ResearchVersionStore(projectURL: projectURL)
        let projectURL = projectURL
        let device = DeviceIdentity.author.slug
        let kept: Error? = await Task.detached { () -> Error? in
            let described = (try? ResearchTableSidecar.read(forItem: itemId, in: projectURL)) ?? held
            let author = described?.contentHash == ContentHash.of(prior) ? described?.writtenBy : nil
            let made: ResearchVersion
            do {
                made = try versions.keep(priorBytes: prior, priorSidecar: described, writtenBy: author, replacedBy: writer,
                                         itemId: itemId, device: device, at: date)
            } catch {
                return error
            }
            versions.prune(itemId: itemId, device: device, sparing: Set([made.name] + [restoring].compactMap { $0 }))
            return nil
        }.value
        guard let kept else { return true }
        researchTableLog.error(
            "\(item.title, privacy: .public)'s previous version was not kept: \(kept.localizedDescription, privacy: .public)")
        // A flush's is said once its save lands (`write`).
        guard source != .flush else { return false }
        MaughamEvent.postNotice(
            "“\(item.title)”’s previous version couldn’t be kept, so \(Self.whose(writer, restoring: restoring != nil)) saved over it.",
            projectURL: projectURL)
        return false
    }

    /// **The file changed outside since it was read or written here**: its
    /// bytes are kept as a conflict backup before the save replaces them (the
    /// writer is told once the save lands). Nil — write nothing — when they
    /// could not be kept, and said (a flush's caller says it, with where the
    /// edits went).
    private func keepTheOutsideVersion(_ outside: Data, of item: ResearchItem, at path: String,
                                       by writer: ResearchWriter, restoring: Bool, source: SaveSource) -> URL? {
        guard let file = try? store?.resolvedProjectPath(path) else { return nil }
        let text = ProjectStore.decodeResearchTable(outside) ?? String(decoding: outside, as: UTF8.self)
        do {
            if let seam = Self.outsideBackupForTesting {
                guard let url = seam(outside) else { throw CocoaError(.fileWriteUnknown) }
                return url
            }
            return try Document.writeConflictBackup(forFileAt: file, docId: itemId, text: text, kind: "outside")
        } catch {
            researchTableLog.error(
                "\(path, privacy: .public)'s outside version was not kept: \(error.localizedDescription, privacy: .public)")
            guard source != .flush else { return nil }
            MaughamEvent.postNotice(
                "“\(item.title)” changed outside Maugham, and that version couldn’t be kept, so \(Self.whose(writer, restoring: restoring)) saved over it.",
                projectURL: projectURL)
            return nil
        }
    }

    /// **A flush that could not write keeps the edits aside** (ruling R-C,
    /// after `ResearchNoteDoor.keepTheFlushedText`): the table's CSV — the
    /// text a save would write now (its formula names read fresh), never its
    /// sidecar's formats — as a conflict backup in `.maugham/conflicts`, said
    /// with `couldNot` (a sentence) and the file's name, or that it is
    /// nowhere. **The host stays dirty** (fix round 1): the edits are still
    /// not in the file, so a later flush or the close tries the file again,
    /// an assistant write is refused until they land, and an outside change
    /// does not reload over them. What was kept is remembered (`keptAside`):
    /// a second flush of the same table on the way out keeps no second copy
    /// and says nothing; one whose backup failed retries it silently, and
    /// names the file if it lands. A later edit changes the text, so its
    /// flush keeps a new backup — intended: each holds the table as it was.
    private func keepTheFlushedTable(_ table: FigureTable, couldNot: String, anchor: URL) async -> WriteOutcome {
        isDirty = true
        if let fresh = try? await store?.formulaNamesForUse() { names = fresh }
        let text = csvText(table)
        let hash = ContentHash.of(Data(text.utf8))
        // The same text already kept — unless that backup is gone (the writer
        // deleted it, or it was pruned): then a new one is kept, and said.
        if let held = keptAside, held.hash == hash, let file = held.file,
           FileManager.default.fileExists(atPath: file.path) { return .keptAside(file) }
        do {
            let backup = try Document.writeConflictBackup(forFileAt: anchor, docId: itemId, text: text,
                                                          kind: "unsaved", at: now())
            keptAside = (hash, backup)
            MaughamEvent.postNotice(
                "\(couldNot) Your edits were kept in the project’s .maugham/conflicts folder as “\(backup.lastPathComponent)”.",
                projectURL: projectURL)
            return .keptAside(backup)
        } catch {
            researchTableLog.error(
                "\(self.itemId, privacy: .public)'s unsaved edits were not kept: \(error.localizedDescription, privacy: .public)")
            // Said unless this very failure was said already (a backup that
            // has gone and cannot be kept again is said too).
            if !(keptAside?.hash == hash && keptAside?.file == nil) {
                MaughamEvent.postNotice(
                    "\(couldNot) Your edits weren’t saved, and they couldn’t be kept anywhere else.", projectURL: projectURL)
            }
            keptAside = (hash, nil)
            return .notKept
        }
    }

    /// `table` as its file's text: its separator, line ending and BOM, its
    /// formulas read by `names`.
    private func csvText(_ table: FigureTable) -> String {
        (hasBOM ? "\u{FEFF}" : "") + TableCSV.renderResearch(
            table, locale: locale, names: names, separator: separator, lineEnding: lineEnding)
    }

    /// The file a flush's backup is named after: the item's own, when it
    /// resolves to a `.csv`; else a table in Research would be (the project
    /// root is found from it), so the backup is always `*-unsaved-*.csv`.
    private func backupAnchor(_ path: String?) -> URL {
        if let path, let file = try? store?.resolvedProjectPath(path), file.pathExtension.lowercased() == "csv" {
            return file
        }
        return projectURL.appendingPathComponent("research/table.csv") // local-path: only names the backup under .maugham/conflicts/
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
