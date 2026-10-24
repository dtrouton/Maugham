import Foundation
import AppKit
import MaughamCore

/// **A figure refused at its own door** (report plan 6a Task 6): this Mac may
/// not change this table's or image's content — an author of another piece, a
/// reviewer, the assistant or the translator. Thrown BEFORE anything is
/// written: no op, no state change, no ⌘Z registered. `what` is the refusal
/// noun the read side uses for the same line (`RefusedWhat.figure`), so the
/// door and the partition name one thing.
public struct FigureEditRefused: LocalizedError, Equatable {
    public let what: RefusedWhat
    /// The refusing verb, as its guard spells it.
    public let site: String

    public init(site: String, what: RefusedWhat = .figure) {
        self.site = site
        self.what = what
    }

    public var errorDescription: String? {
        "this Mac may not change this figure, so the table was left as it was"
    }
}

/// **An edit that names something the figure does not have** — a row or
/// column that is not live, a table edit on an image. Nothing is written.
public struct FigureEditInvalid: LocalizedError, Equatable {
    public let reason: String
    public var errorDescription: String? { reason }
}

/// **The open figure on the Mac** (report plan 6a, ruling D-d): a table's or
/// an image's own op-logged document, a sibling of `Document` and never one.
///
/// - **The stream is the truth** for content and lifecycle (ruling D-e);
///   `state` is `FigureDeriver`'s fold of it. Name, kind, piece and path are
///   the manifest registry's (`FigureRecord`).
/// - **The load emits nothing** — no bootstrap, no recovery fold, no anchors.
///   A figure is born from an explicit `figureCreate` (`ProjectStore.createFigure`),
///   so `Permit.isALoadEmission` is false for every figure kind and there is
///   nothing here for `authorEmissionDevice` to redirect.
/// - **Every mutator asks the FIGURE's posture** (`Posture.Verb.editFigure`,
///   the class carrying the manifest's `FigureRecord.piece`) behind its
///   `requireWritable("…")` guard — the window's door where a window holds
///   the figure, so the piece's yields and *Edit Anyway* apply (R-6a-8);
///   never a piece's posture, which answers yes under Option A. A refusal
///   throws `FigureEditRefused` before anything is written.
/// - **Undo appends a compensating op** (ADR 0023) built by
///   `FigureInverse.inverse`, registered through `OpUndoRegistrar` with this
///   document as the target (`registerFigureUndo`). A delete registers none
///   (6a cannot revive a tombstone); an undone insert declines its redo
///   (ruling R-6a-5). Every undo and redo is drift-guarded: when another
///   device has since changed what the op wrote, it declines out loud rather
///   than clobber (`InlineToggleUndo`'s rule).
@MainActor
@Observable
public final class FigureDocument {

    public let figureId: String
    public let projectURL: URL
    public let actor: DeviceActor
    public let session: String

    /// The figure as its stream says it is.
    public private(set) var state: FigureState

    /// What the load's files were made of (verified, held, set aside).
    public private(set) var provenance: OpLogProvenance?

    /// Closed: abandoned by contract; every mutator refuses.
    public private(set) var isClosed = false

    /// The device string this document's own ops are signed under — the
    /// loading actor's key, from the same `LocalIdentities` the store chains
    /// with (`Document.loadIdentities`).
    let device: String
    let opStore: OpLogStore
    /// Every op this document has read or written, in fold order — what
    /// `state` is re-derived from when an append fails.
    @ObservationIgnored private(set) var _ops: [Op]

    /// The window's posture door, where a window holds this figure (ruling
    /// R-6a-8): the figure's piece owner and starter yields and *Edit Anyway*
    /// come from it. Nil for a figure no window holds, which asks Core's
    /// `PostureDoor` directly (`RulingPerformer`'s windowless precedent).
    @ObservationIgnored public weak var documentStore: DocumentStore?

    /// Test seam: the async hop of the last undo/redo (`Document`'s mirror).
    @ObservationIgnored internal var _lastUndoWorkTask: Task<Void, Never>?

    /// Where `setImage` keeps the pictures its ⌘Z and redo put back — the
    /// one replaced and the one that replaced it, by content hash — for this
    /// open document only: a temporary folder, never `.maugham/` (nothing
    /// syncs it), removed at `close()`.
    @ObservationIgnored private var imageUndoFolder: URL?

    private init(
        figureId: String, projectURL: URL, actor: DeviceActor, session: String,
        opStore: OpLogStore, ops: [Op], provenance: OpLogProvenance?
    ) {
        self.figureId = figureId
        self.projectURL = projectURL
        self.actor = actor
        self.session = session
        self.opStore = opStore
        self.device = Document.loadIdentities[actor].deviceId
        self._ops = ops
        self.provenance = provenance
        self.state = Self.derive(ops)
    }

    // MARK: - Load

    /// **The one door a figure opens through.** It keeps `Document.load`'s
    /// read guarantees and none of its writes:
    /// - an ops directory that exists but cannot be listed throws (RULING-54);
    /// - the history is read by `OpLogStore.loadDiagnosed` — trust, the permit
    ///   partition (which resolves this stream's class to `.figure` from the
    ///   registry) and the foreign-stream watch — over a store built by
    ///   `Document.makeLoadOpStore`, so the two loaders share one identity;
    /// - undecodable lines are recorded by `IntegrityQuarantine`, best-effort;
    /// - nothing is appended. A figure has no "bootstrap from file" case, and
    ///   `figures/<name>.csv` is never read (tripwire 20).
    ///
    /// `actor`, never a device string (tripwire 38).
    ///
    /// `documentStore` is **required**: a window passes its own store
    /// (`DocumentStore.openFigure` is the door a window opens a figure
    /// through), so the figure asks the window's posture and renders its CSV;
    /// only a caller with no window passes an explicit nil — it asks Core's
    /// door directly, and renders nothing.
    public static func load(
        figureId: String, projectURL: URL, actor: DeviceActor,
        session: String, presenter: NSFilePresenter?,
        documentStore: DocumentStore?
    ) async throws -> FigureDocument {
        let opStore = Document.makeLoadOpStore(projectURL: projectURL, presenter: presenter)
        let (ops, provenance) = try await readHistory(
            figureId: figureId, projectURL: projectURL, opStore: opStore)
        let doc = FigureDocument(
            figureId: figureId, projectURL: projectURL, actor: actor,
            session: session, opStore: opStore, ops: ops, provenance: provenance)
        doc.documentStore = documentStore
        return doc
    }

    /// Re-read the stream after another device's lines changed it (the
    /// presenter's figure arm, `DocumentStore.applyPendingFigureChanges`).
    /// The same read as the load; writes nothing.
    public func reload() async throws {
        guard !isClosed else { return }
        let (ops, provenance) = try await Self.readHistory(
            figureId: figureId, projectURL: projectURL, opStore: opStore)
        _ops = ops
        self.provenance = provenance
        state = Self.derive(ops)
    }

    private static func readHistory(
        figureId: String, projectURL: URL, opStore: OpLogStore
    ) async throws -> ([Op], OpLogProvenance) {
        try OpLogStore.verifyOpsDirectoryListable(in: projectURL)
        let loaded = try await opStore.loadDiagnosed(docId: figureId)
        if !loaded.diagnostics.skipped.isEmpty {
            // Forensics, never a gate: the figure still opens.
            let stamp = ISO8601DateFormatter.quarantineStamp(from: Date())
            do {
                _ = try IntegrityQuarantine.record(
                    skipped: loaded.diagnostics.skipped,
                    forDocId: figureId, in: projectURL, stamp: stamp)
            } catch {
                documentLog.error(
                    "figure quarantine-record write failed for \(figureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return (loaded.ops, loaded.provenance)
    }

    /// The figure's own ops only: a note anchored on a cell rides the same
    /// stream and is the annotation layer's, not the table's.
    private static func derive(_ ops: [Op]) -> FigureState {
        FigureDeriver.derive(ops.filter { FigureOpPayload.kinds.contains($0.kind) })
    }

    /// Seal this device's tail and refuse every later write.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        if let imageUndoFolder { try? FileManager.default.removeItem(at: imageUndoFolder) }
        imageUndoFolder = nil
        do { _ = try await opStore.sealChain(docId: figureId) } catch {
            documentLog.error(
                "figure seal at close failed for \(self.figureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - The door

    /// **May this device's own hand change this figure?** The FIGURE's
    /// posture — its class is `.figure(id:, piece:)` from the registry — never
    /// a piece's (Option A widens a piece, not a figure). Asked fresh at every
    /// press, so a demotion that landed since the load closes the door.
    ///
    /// **The window's door where a window holds it** (ruling R-6a-8): figure
    /// edits follow the same window posture as the piece's text, so the
    /// piece owner's and starter's yields and *Edit Anyway* apply —
    /// `DocumentStore.settledPosture`, the acting accessor. With no window,
    /// Core's `PostureDoor` directly. A `.settling` answer refuses.
    func mayEditHere() async -> Bool {
        guard !isClosed else { return false }
        let posture: Posture
        if let documentStore {
            posture = await documentStore.settledPosture(forDocId: figureId, as: actor)
        } else {
            posture = PostureDoor.posture(
                forDocId: figureId, in: projectURL, as: actor, using: opStore)
        }
        guard !isClosed, !posture.isSettling else { return false }
        return posture.allows(.editFigure)
    }

    /// The guard every mutator opens with — the spelling tripwire 52's
    /// population is derived from. A closed document throws
    /// `DocumentNotWritableError`; a posture that refuses throws
    /// `FigureEditRefused` (`RefusedWhat.figure`).
    func requireWritable(_ site: StaticString) async throws {
        if isClosed {
            documentLog.error(
                "\(site, privacy: .public) called on a closed FigureDocument \(self.figureId, privacy: .public); no-op")
            throw DocumentNotWritableError(site: "\(site)")
        }
        guard await mayEditHere() else {
            documentLog.error(
                "\(site, privacy: .public) refused on \(self.figureId, privacy: .public): this device may not change this figure")
            throw FigureEditRefused(site: "\(site)")
        }
    }

    // MARK: - Mutators

    /// Set (or clear, with nil) one cell. `prior` is the cell it replaces.
    public func setCell(_ cell: Cell?, at key: CellKey, undoManager: UndoManager? = nil) async throws {
        try await requireWritable("setCell")
        try requireTable()
        guard isLive(key) else { throw FigureEditInvalid(reason: "that cell's row or column is gone") }
        let prior = state.table[key]
        guard prior != cell else { return }
        let op = try await commit(.figureCellSet, FigureOpPayload(cell: key, next: cell, prior: prior))
        registerFigureUndo(
            undoManager, actionName: "Edit Cell", forward: op,
            stillAsWritten: { d in d.isLive(key) && d.state.table[key] == cell },
            redo: { [weak undoManager] d in
                guard d.isLive(key), d.state.table[key] == prior else { return d.decline(.drifted) }
                await d.redoing { try await d.setCell(cell, at: key, undoManager: undoManager) }
            })
    }

    /// Insert a row after `after` (nil = first). Answers its minted id.
    @discardableResult
    public func insertRow(after: RowID?, undoManager: UndoManager? = nil) async throws -> RowID {
        try await requireWritable("insertRow")
        try requireTable()
        if let after, state.table.rowSlotIndex(of: after) == nil {
            throw FigureEditInvalid(reason: "no such row to insert after")
        }
        let id = RowID(TableID.mint(excluding: usedIDs))
        let op = try await commit(.figureStructure, FigureOpPayload(structure: .insertRow(id, after: after)))
        registerFigureUndo(
            undoManager, actionName: "Insert Row", forward: op,
            stillAsWritten: { d in d.rowIsUntouched(id) },
            redo: { d in d.decline(.insertNotRedoable) })
        return id
    }

    /// Insert a column after `after` (nil = first). Answers its minted id.
    @discardableResult
    public func insertColumn(after: ColumnID?, undoManager: UndoManager? = nil) async throws -> ColumnID {
        try await requireWritable("insertColumn")
        try requireTable()
        if let after, state.table.columnSlotIndex(of: after) == nil {
            throw FigureEditInvalid(reason: "no such column to insert after")
        }
        let id = ColumnID(TableID.mint(excluding: usedIDs))
        let op = try await commit(.figureStructure, FigureOpPayload(structure: .insertColumn(id, after: after)))
        registerFigureUndo(
            undoManager, actionName: "Insert Column", forward: op,
            stillAsWritten: { d in d.columnIsUntouched(id) },
            redo: { d in d.decline(.insertNotRedoable) })
        return id
    }

    /// Delete a row. **No ⌘Z in 6a**: reviving a tombstone is plan 6b's.
    public func deleteRow(_ id: RowID) async throws {
        try await requireWritable("deleteRow")
        try requireTable()
        guard state.table.rowIndex(of: id) != nil else { throw FigureEditInvalid(reason: "that row is gone") }
        try await commit(.figureStructure, FigureOpPayload(structure: .deleteRow(id)))
    }

    /// Delete a column. **No ⌘Z in 6a**: reviving a tombstone is plan 6b's.
    public func deleteColumn(_ id: ColumnID) async throws {
        try await requireWritable("deleteColumn")
        try requireTable()
        guard state.table.columnIndex(of: id) != nil else { throw FigureEditInvalid(reason: "that column is gone") }
        try await commit(.figureStructure, FigureOpPayload(structure: .deleteColumn(id)))
    }

    /// Move a row to just after `after` (nil = first).
    public func moveRow(_ id: RowID, after: RowID?, undoManager: UndoManager? = nil) async throws {
        try await requireWritable("moveRow")
        try requireTable()
        guard state.table.rowIndex(of: id) != nil, after != id else { throw FigureEditInvalid(reason: "that row cannot move there") }
        if let after, state.table.rowSlotIndex(of: after) == nil {
            throw FigureEditInvalid(reason: "no such row to move after")
        }
        let priorAfter = rowPredecessor(id) ?? nil
        guard priorAfter != after else { return }
        let op = try await commit(.figureStructure, FigureOpPayload(
            structure: .moveRow(id, after: after, priorAfter: priorAfter)))
        registerFigureUndo(
            undoManager, actionName: "Move Row", forward: op,
            stillAsWritten: { d in d.state.table.rowIndex(of: id) != nil && d.rowPredecessor(id) == .some(after) },
            redo: { [weak undoManager] d in
                guard d.state.table.rowIndex(of: id) != nil, d.rowPredecessor(id) == .some(priorAfter) else {
                    return d.decline(.drifted)
                }
                await d.redoing { try await d.moveRow(id, after: after, undoManager: undoManager) }
            })
    }

    /// Move a column to just after `after` (nil = first).
    public func moveColumn(_ id: ColumnID, after: ColumnID?, undoManager: UndoManager? = nil) async throws {
        try await requireWritable("moveColumn")
        try requireTable()
        guard state.table.columnIndex(of: id) != nil, after != id else { throw FigureEditInvalid(reason: "that column cannot move there") }
        if let after, state.table.columnSlotIndex(of: after) == nil {
            throw FigureEditInvalid(reason: "no such column to move after")
        }
        let priorAfter = columnPredecessor(id) ?? nil
        guard priorAfter != after else { return }
        let op = try await commit(.figureStructure, FigureOpPayload(
            structure: .moveColumn(id, after: after, priorAfter: priorAfter)))
        registerFigureUndo(
            undoManager, actionName: "Move Column", forward: op,
            stillAsWritten: { d in d.state.table.columnIndex(of: id) != nil && d.columnPredecessor(id) == .some(after) },
            redo: { [weak undoManager] d in
                guard d.state.table.columnIndex(of: id) != nil, d.columnPredecessor(id) == .some(priorAfter) else {
                    return d.decline(.drifted)
                }
                await d.redoing { try await d.moveColumn(id, after: after, undoManager: undoManager) }
            })
    }

    /// Header rows: 0 or 1 (`FigureTable` clamps; so does this, so the op
    /// says what the table will hold).
    public func setHeaderRows(_ rows: Int, undoManager: UndoManager? = nil) async throws {
        try await requireWritable("setHeaderRows")
        try requireTable()
        let rows = min(max(rows, 0), 1)
        let prior = state.table.headerRows
        guard prior != rows else { return }
        let op = try await commit(.figureSettings, FigureOpPayload(settings: .headerRows(rows, prior: prior)))
        registerFigureUndo(
            undoManager, actionName: "Header Row", forward: op,
            stillAsWritten: { d in d.state.table.headerRows == rows },
            redo: { [weak undoManager] d in
                guard d.state.table.headerRows == prior else { return d.decline(.drifted) }
                await d.redoing { try await d.setHeaderRows(rows, undoManager: undoManager) }
            })
    }

    /// Whether the last row is a total row.
    public func setTotalRow(_ total: Bool, undoManager: UndoManager? = nil) async throws {
        try await requireWritable("setTotalRow")
        try requireTable()
        let prior = state.table.hasTotalRow
        guard prior != total else { return }
        let op = try await commit(.figureSettings, FigureOpPayload(settings: .totalRow(total, prior: prior)))
        registerFigureUndo(
            undoManager, actionName: "Total Row", forward: op,
            stillAsWritten: { d in d.state.table.hasTotalRow == total },
            redo: { [weak undoManager] d in
                guard d.state.table.hasTotalRow == prior else { return d.decline(.drifted) }
                await d.redoing { try await d.setTotalRow(total, undoManager: undoManager) }
            })
    }

    /// A column's width; nil is the automatic width.
    public func setColumnWidth(_ column: ColumnID, _ width: Double?, undoManager: UndoManager? = nil) async throws {
        try await requireWritable("setColumnWidth")
        try requireTable()
        guard state.table.columnIndex(of: column) != nil else { throw FigureEditInvalid(reason: "that column is gone") }
        let prior = state.table.columnWidths[column]
        guard prior != width else { return }
        let op = try await commit(.figureSettings, FigureOpPayload(
            settings: .columnWidth(column, width, prior: prior)))
        registerFigureUndo(
            undoManager, actionName: "Column Width", forward: op,
            stillAsWritten: { d in
                d.state.table.columnIndex(of: column) != nil && d.state.table.columnWidths[column] == width
            },
            redo: { [weak undoManager] d in
                guard d.state.table.columnIndex(of: column) != nil,
                      d.state.table.columnWidths[column] == prior else { return d.decline(.drifted) }
                await d.redoing { try await d.setColumnWidth(column, width, undoManager: undoManager) }
            })
    }

    /// **Replace an image figure's picture** (report plan 6a Task 9): the
    /// file under `figures/` is replaced through the window's coordinated
    /// door (`DocumentStore.replaceFigureImage`), then one `figureImageSet`
    /// is appended carrying the new file's name and hash and the picture it
    /// replaced (`priorImage`) — a recorded, attributed change.
    ///
    /// - The file keeps its name, so every figure line pointing at it keeps
    ///   resolving: a picture in another format than the figure's file is
    ///   refused (`FigureEditInvalid`), after HEIC and the like are re-encoded
    ///   as PNG (`FigureIngest.copyableFile`). The same picture again writes
    ///   nothing.
    /// - **⌘Z puts the old picture back**, bytes and op: both pictures are
    ///   kept for this open document (`imageUndoFolder`), and the undo
    ///   restores the file before it appends the inverse. A figure's FIRST
    ///   picture has no inverse (`FigureInverse` answers nil), so nothing is
    ///   registered; its record's path gains the extension
    ///   (`ProjectStore.recordFigureImagePath`).
    ///
    /// Needs the window that holds the figure (`documentStore`): the file is
    /// written through its coordinated door.
    public func setImage(fromURL source: URL, undoManager: UndoManager? = nil) async throws {
        try await requireWritable("setImage")
        guard state.kind == .image else {
            throw FigureEditInvalid(reason: "this figure is not an image")
        }
        guard let documentStore else {
            throw FigureEditInvalid(reason: "a picture is replaced only in a window that holds the figure")
        }
        let copyable = try await Task.detached { try FigureIngest.copyableFile(for: source) }.value
        defer { if copyable.isTemporary { FigureIngest.removeTemporary(copyable.url) } }
        let ext = copyable.url.pathExtension.lowercased()
        let prior = state.image
        let filename: String
        if let prior {
            filename = prior.filename
            let current = (prior.filename as NSString).pathExtension.lowercased()
            guard Self.sameImageFormat(current, ext) else {
                throw FigureEditInvalid(
                    reason: "this figure's picture is a .\(current) file; a .\(ext) picture can't replace it")
            }
        } else {
            guard let record = documentStore.projectStore?.manifest.figures?
                .first(where: { $0.id == figureId }) else {
                throw FigureEditInvalid(reason: "this figure is not in the book's list of figures")
            }
            filename = (record.path as NSString).lastPathComponent + "." + ext
        }
        let hash = try await Task.detached { try FigureImageResolver.contentHash(of: copyable.url) }.value
        guard hash != prior?.contentHash else { return }

        let destination = projectURL
            .appendingPathComponent(ProjectStore.figuresFolder, isDirectory: true)
            .appendingPathComponent(filename)
        // Both pictures kept before anything changes, so ⌘Z and redo can put
        // either back; the prior one only if it is still on disk.
        let keptPrior = prior.flatMap { try? keepForUndo(destination, hash: $0.contentHash) }
        let keptNext = try keepForUndo(copyable.url, hash: hash)
        try await documentStore.replaceFigureImage(at: destination, withCopyOf: copyable.url)

        let next = FigureImageRef(filename: filename, contentHash: hash)
        let op = try await commit(.figureImageSet, FigureOpPayload(image: next, priorImage: prior))
        if prior == nil {
            try await documentStore.projectStore?.recordFigureImagePath(
                figureId: figureId, path: "\(ProjectStore.figuresFolder)/\(filename)")
        }
        registerFigureUndo(
            undoManager, actionName: "Replace Picture", forward: op,
            stillAsWritten: { d in d.state.image == next },
            restoring: { d in
                guard let keptPrior, let store = d.documentStore else {
                    throw FigureEditInvalid(reason: "the replaced picture is no longer kept")
                }
                try await store.replaceFigureImage(at: destination, withCopyOf: keptPrior)
            },
            redo: { [weak undoManager] d in
                guard d.state.image == prior else { return d.decline(.drifted) }
                await d.redoing { try await d.setImage(fromURL: keptNext, undoManager: undoManager) }
            })
    }

    /// `jpg` and `jpeg` are one format; every other extension is its own.
    private static func sameImageFormat(_ a: String, _ b: String) -> Bool {
        let jpeg: Set<String> = ["jpg", "jpeg"]
        return a == b || (jpeg.contains(a) && jpeg.contains(b))
    }

    /// A copy of `file` in `imageUndoFolder`, named by its hash; the copy
    /// already there when the same picture was kept before.
    private func keepForUndo(_ file: URL, hash: String) throws -> URL {
        let fm = FileManager.default
        let folder: URL
        if let imageUndoFolder {
            folder = imageUndoFolder
        } else {
            folder = fm.temporaryDirectory.appendingPathComponent(
                "maugham-figure-undo-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            imageUndoFolder = folder
        }
        let kept = folder.appendingPathComponent(hash).appendingPathExtension(file.pathExtension)
        if !fm.fileExists(atPath: kept.path) { try fm.copyItem(at: file, to: kept) }
        return kept
    }

    // MARK: - Undo

    /// Why an undo or redo did not happen — said, never swallowed.
    enum FigureUndoDecline: Equatable {
        /// Another device changed what the op wrote since.
        case drifted
        /// This Mac may no longer change this figure.
        case notPermitted
        /// An undone insert is not redoable until plan 6b's revive (R-6a-5).
        case insertNotRedoable
        /// The picture an undo would put back is no longer kept.
        case pictureNotKept

        var sentence: String {
            switch self {
            case .drifted:
                "Couldn't undo the change to the figure — it changed on another device."
            case .notPermitted:
                "Couldn't change the table — this Mac can no longer change this figure."
            case .insertNotRedoable:
                "Couldn't put the row or column back — a removed row or column can't return yet."
            case .pictureNotKept:
                "Couldn't put the picture back — the one it replaced is no longer kept."
            }
        }
    }

    private func decline(_ why: FigureUndoDecline) {
        documentLog.error("figure undo declined on \(self.figureId, privacy: .public): \(String(describing: why), privacy: .public)")
        MaughamEvent.postNotice(why.sentence, projectURL: projectURL)
    }

    /// A redo re-enters the forward mutator; a refusal there is said as one.
    private func redoing(_ body: () async throws -> Void) async {
        do { try await body() } catch is FigureEditRefused {
            decline(.notPermitted)
        } catch {
            documentLog.error("figure redo failed on \(self.figureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// **The one ⌘Z registration for a figure op** — the mechanism
    /// `OpKindUndoExhaustivenessTests` names. The inverse is
    /// `FigureInverse.inverse` of the forward op's payload; where it answers
    /// nil (a delete, a first image) nothing is registered. The undo:
    /// 1. **the door** — this Mac must still be allowed to change the figure
    ///    (the window's posture, yields included);
    /// 2. **drift guard** — `stillAsWritten` must hold (the cell still holds
    ///    the op's `next`, the row is still where the move put it, …), or it
    ///    declines rather than clobber another device's write;
    /// 3. `restoring`, where the op's content lives outside the stream (an
    ///    image's file): put back first, and a failure there appends nothing;
    /// 4. appends the compensating op, registering nothing further (the
    ///    registrar has already put `redo` on the redo stack).
    func registerFigureUndo(
        _ undoManager: UndoManager?, actionName: String, forward: Op,
        stillAsWritten: @escaping @MainActor (FigureDocument) -> Bool,
        restoring: (@MainActor (FigureDocument) async throws -> Void)? = nil,
        redo: @escaping @MainActor (FigureDocument) async -> Void
    ) {
        guard let payload = forward.figure,
              let (kind, inverse) = FigureInverse.inverse(of: payload, kind: forward.kind)
        else { return }
        OpUndoRegistrar.register(
            undoManager, actionName: actionName, target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { d in
                guard !d.isClosed else { return }
                guard await d.mayEditHere() else { return d.decline(.notPermitted) }
                // After the door's await, so nothing lands between the check
                // and the append.
                guard stillAsWritten(d) else { return d.decline(.drifted) }
                do { try await restoring?(d) } catch {
                    documentLog.error("figure undo could not restore \(d.figureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return d.decline(.pictureNotKept)
                }
                do { try await d.commit(kind, inverse) } catch {
                    documentLog.error("figure undo append failed on \(d.figureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            },
            redo: redo)
    }

    /// Test seam: await the last undo/redo's async hop.
    func awaitPendingUndoWork() async {
        await _lastUndoWorkTask?.value
    }

    // MARK: - Writing

    /// Fold the op into `state` first (so a second press in the same turn
    /// reads the new state), then append; a failed append takes it back out.
    @discardableResult
    private func commit(_ kind: OpKind, _ payload: FigureOpPayload) async throws -> Op {
        guard !isClosed else { throw DocumentNotWritableError(site: "commit") }
        let op = Op(
            opId: ULID.generate(), docId: figureId, at: Date(), device: device,
            session: session, kind: kind, changes: [], figure: payload)
        _ops.append(op)
        FigureDeriver.fold(op, into: &state)
        do {
            try await opStore.append(op)
        } catch {
            _ops.removeAll { $0.opId == op.opId }
            state = Self.derive(_ops)
            throw error
        }
        // The render follows every op this host appends (report plan 6a
        // Task 7): `figures/<name>.csv` and every table reading this one.
        // Windowless, there is no coordinated door to write through.
        await documentStore?.figureHostAppended(figureId)
        return op
    }

    // MARK: - Reading the table

    private func requireTable() throws {
        guard state.kind == .table else {
            throw FigureEditInvalid(reason: "this figure is not a table")
        }
    }

    private func isLive(_ key: CellKey) -> Bool {
        state.table.rowIndex(of: key.row) != nil && state.table.columnIndex(of: key.column) != nil
    }

    /// **May an insert's undo take this row back?** (ruling R-6a-13) Only
    /// while it is live, holds no cell and no pin: the inverse is a delete,
    /// which takes everything in it and which 6a cannot undo, so a row another
    /// device has typed into since is left standing (Review Focus 5).
    func rowIsUntouched(_ id: RowID) -> Bool {
        state.table.rowIndex(of: id) != nil
            && !state.table.cells.keys.contains { $0.row == id }
            && !state.pins.keys.contains { $0.row == id }
    }

    /// The column's twin of `rowIsUntouched`; a width set on it counts too.
    func columnIsUntouched(_ id: ColumnID) -> Bool {
        state.table.columnIndex(of: id) != nil
            && state.table.columnWidths[id] == nil
            && !state.table.cells.keys.contains { $0.column == id }
            && !state.pins.keys.contains { $0.column == id }
    }

    /// Every row and column id this table has ever held, tombstones too: a
    /// fresh id must not collide with a deleted one.
    private var usedIDs: Set<String> {
        Set(state.table.rowSlots.map(\.id.raw)).union(state.table.columnSlots.map(\.id.raw))
    }

    /// The slot just before `id` (`.some(nil)` = it is first), or nil when
    /// `id` has no slot — what a move's `priorAfter` records.
    private func rowPredecessor(_ id: RowID) -> RowID?? {
        guard let i = state.table.rowSlotIndex(of: id) else { return nil }
        return .some(i == 0 ? nil : state.table.rowSlots[i - 1].id)
    }

    private func columnPredecessor(_ id: ColumnID) -> ColumnID?? {
        guard let i = state.table.columnSlotIndex(of: id) else { return nil }
        return .some(i == 0 ? nil : state.table.columnSlots[i - 1].id)
    }
}
