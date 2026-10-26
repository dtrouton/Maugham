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

/// **A figure parked in Research refuses every edit** (ruling P-5, report
/// plan 6b Task 7): its content lives in the Research working copy until it
/// is brought back, and its stream folds nothing meanwhile. Thrown before
/// anything is written.
public struct FigureParkedRefused: LocalizedError, Equatable {
    /// The refusing verb, as its guard spells it.
    public let site: String
    public let kind: FigureKind?

    public var errorDescription: String? { Self.notice(for: kind) }

    /// What the writer is told: "This table is in Research." (a picture's
    /// own word for a picture).
    static func notice(for kind: FigureKind?) -> String {
        kind == .image ? "This picture is in Research." : "This table is in Research."
    }
}

/// **A return from Research that stopped part way** (report plan 6b Task 8):
/// the resume and `applied` of `of` changes landed, then an append failed. The
/// figure was parked again (`parkedAgain`), so *Use in document* on the same
/// copy brings back what is left.
public struct FigureBringBackIncomplete: LocalizedError, Equatable {
    public let applied: Int
    public let of: Int
    public let parkedAgain: Bool

    public var errorDescription: String? {
        parkedAgain
            ? "Only part of the figure came back (\(applied) of \(of) changes), so it was put back in Research. Try Use in Document again."
            : "Only part of the figure came back (\(applied) of \(of) changes), and it could not be put back in Research."
    }
}

/// **An edit that names something the figure does not have** — a row or
/// column that is not live, a table edit on an image. Nothing is written.
public struct FigureEditInvalid: LocalizedError, Equatable {
    public let reason: String
    public var errorDescription: String? { reason }
}

/// **What a checkpoint restore did to one figure** (report plan 6c Task 2,
/// ruling Q-1) — `FigureDocument.restoreToCheckpoint`'s answer, which the
/// restore names to the writer.
public enum FigureRestoreOutcome: Equatable, Sendable {
    /// `opCount` ops were appended and the figure stands as it did then.
    case restored(opCount: Int)
    /// The figure already stood as it did then: nothing was appended.
    case unchanged
    /// The figure is parked in Research: nothing was appended ("in Research —
    /// bring it back first").
    case skippedParked
    /// The figure went to Research, or came back, since the checkpoint
    /// (controller ruling, final review I5): nothing was appended. Winding it
    /// back across a park would quietly revert what came back from Research.
    case skippedWentToResearch
    /// The checkpoint's picture (`hash`) is no longer on disk: the rest was
    /// restored (`opCount` ops), the picture left as it is.
    case skippedPicture(hash: String, opCount: Int)
    /// The restore stopped after `opCount` of its ops landed (`why`). What
    /// landed stays; restoring again is safe and does only what is left.
    case partlyRestored(opCount: Int, why: Stop)

    /// Why a restore stopped part way.
    public enum Stop: Equatable, Sendable {
        /// Another device's lines were read into the figure meanwhile: the
        /// rest was worked out against what it was before, so it stopped.
        case changedElsewhere
        /// An op could not be written to the figure's history (the error's
        /// description).
        case notRecorded(String)
    }
}

/// **The content hashes of the pictures one restore read** (final review
/// M6): a whole-project restore asks for each image figure's picture by
/// hash, and `figures/` is hashed once for all of them, not per figure. A
/// file is known by its path, size and modification date, so one the
/// restore wrote over meanwhile is hashed again.
@MainActor
final class FigurePictureHashes {
    private var known: [String: (stamp: String, hash: String?)] = [:]

    nonisolated init() {}

    /// The first of `candidates` whose bytes hash to `hash`, hashing off the
    /// main actor only the files not already known.
    func first(in candidates: [URL], matching hash: String) async -> URL? {
        var unknown: [(url: URL, stamp: String)] = []
        for url in candidates {
            let stamp = Self.stamp(of: url)
            if let seen = known[url.path], seen.stamp == stamp {
                if seen.hash == hash { return url }
            } else {
                unknown.append((url, stamp))
            }
        }
        let hashed = await Task.detached {
            unknown.map { ($0.url, $0.stamp, try? FigureImageResolver.contentHash(of: $0.url)) }
        }.value
        for (url, stamp, each) in hashed { known[url.path] = (stamp, each) }
        hashCount += hashed.count
        return hashed.first { $0.2 == hash }?.0
    }

    /// How many times this has hashed a file (test seam).
    private(set) var hashCount = 0

    private static func stamp(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
    }
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
///   never a piece's posture, which would answer for a figure of the whole
///   book too. In a piece nobody has claimed the figure's own class follows
///   the piece's text exactly, Option A and the starter's yield included
///   (Denver's ruling R-D4, `Permit.startersPiece(of:)`). A refusal
///   throws `FigureEditRefused` before anything is written.
/// - **Undo appends a compensating op** (ADR 0023) built by
///   `FigureInverse.inverse`, registered through `OpUndoRegistrar` with this
///   document as the target (`registerFigureUndo`). A row or column delete
///   records what it took (`FigureState.removedSlice`, ruling P-2), so its
///   undo revives it in its own slot with its cells, pins and width; an
///   undone insert redoes as a revive (`reviveRow`/`reviveColumn`, ruling
///   P-1). Every undo and redo is drift-guarded: when another
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

    /// **Each device's own stream in append order**, by op id
    /// (`OpLogStore.loadDiagnosedStreams`), this host's commits added as they
    /// are made: what a park records it had read (`parkedFrontier`: each
    /// stream's last op), and what a return reads that against.
    @ObservationIgnored private(set) var streams: [String: [String]]

    /// The newest op id this host has folded: every op it mints sorts after
    /// it (`commit`), so a local edit never sorts before one already here.
    @ObservationIgnored private var newestOpId: String?

    /// The window's posture door, where a window holds this figure (ruling
    /// R-6a-8): the figure's piece owner and starter yields and *Edit Anyway*
    /// come from it. Nil for a figure no window holds, which asks Core's
    /// `PostureDoor` directly (`RulingPerformer`'s windowless precedent).
    @ObservationIgnored public weak var documentStore: DocumentStore?

    /// Test seam: the async hop of the last undo/redo (`Document`'s mirror).
    @ObservationIgnored internal var _lastUndoWorkTask: Task<Void, Never>?

    /// **This host's own ops no read has shown it yet** — committed (or
    /// committing) here, by op id. A reload whose read began before one of
    /// them reached the stream would otherwise drop it from `state` until
    /// the echo's reload ~300 ms later, and the next edit's `prior` and a
    /// ⌘Z's drift guard would read the regressed table (final review I-5).
    /// `reload` carries every one its read lacks; one is forgotten once a
    /// read has SEEN it in the stream — applied, held or refused — or when
    /// its append fails (residual N-1).
    @ObservationIgnored private var unconfirmedLocalOpIds: Set<String> = []

    /// **The unconfirmed ops whose append has returned** — each is in the
    /// stream, so any read that BEGINS after it is added has seen it, whatever
    /// that read made of it. A read that held or refused one does not list it
    /// among its applied ops, so "the read contains it" alone would carry it
    /// over the derivation until close (final re-review N-1).
    @ObservationIgnored private var appendedLocalOpIds: Set<String> = []

    /// Bumped by every `reload`: a read that a later reload overtook does not
    /// land over the later one's answer.
    @ObservationIgnored private var reloadGeneration = 0

    /// Test seam: runs in `reload` after the read and before it lands — where
    /// a local commit racing the read is put. Nil in production.
    static var afterReloadReadForTesting: (@MainActor (FigureDocument) async -> Void)?

    /// Test seam: thrown from just before `commit`'s append, to prove what a
    /// failed append leaves behind. Nil in production.
    static var beforeCommitAppendForTesting: ((Op) throws -> Void)?

    /// Where `setImage` keeps the pictures its ⌘Z and redo put back — the
    /// one replaced and the one that replaced it, by content hash — for this
    /// open document only: a temporary folder, never `.maugham/` (nothing
    /// syncs it), removed at `close()`.
    @ObservationIgnored private var imageUndoFolder: URL?

    private init(
        figureId: String, projectURL: URL, actor: DeviceActor, session: String,
        opStore: OpLogStore, ops: [Op], streams: [String: [String]], provenance: OpLogProvenance?
    ) {
        self.figureId = figureId
        self.projectURL = projectURL
        self.actor = actor
        self.session = session
        self.opStore = opStore
        self.device = Document.loadIdentities[actor].deviceId
        self._ops = ops
        self.streams = streams
        self.newestOpId = ops.map(\.opId).max()
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
        let (ops, streams, provenance) = try await readHistory(
            figureId: figureId, projectURL: projectURL, opStore: opStore)
        let doc = FigureDocument(
            figureId: figureId, projectURL: projectURL, actor: actor,
            session: session, opStore: opStore, ops: ops, streams: streams, provenance: provenance)
        doc.documentStore = documentStore
        return doc
    }

    /// Re-read the stream after another device's lines changed it (the
    /// presenter's figure arm, `DocumentStore.applyPendingFigureChanges`).
    /// The same read as the load; writes nothing.
    ///
    /// **A local op that commits during the read is kept**: the read cannot
    /// contain an op appended after it began, so every op of this host's own
    /// that the read lacks (`unconfirmedLocalOpIds`) is carried after it, in
    /// the order it was committed — what the incremental fold already shows.
    ///
    /// **A local op the read has seen is not carried**, applied or not: one
    /// whose append returned before the read began is in the stream the read
    /// walked, so if the read held or refused it, `state` agrees with that
    /// verdict rather than keeping the op until close (residual N-1).
    public func reload() async throws {
        guard !isClosed else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        let inTheStreamBeforeTheRead = appendedLocalOpIds
        let (ops, read, provenance) = try await Self.readHistory(
            figureId: figureId, projectURL: projectURL, opStore: opStore)
        if let hook = Self.afterReloadReadForTesting { await hook(self) }
        guard !isClosed, generation == reloadGeneration else { return }
        let seen = Set(ops.map(\.opId)).union(inTheStreamBeforeTheRead)
        unconfirmedLocalOpIds.subtract(seen)
        appendedLocalOpIds.subtract(seen)
        let carried = _ops.filter { unconfirmedLocalOpIds.contains($0.opId) }
        _ops = ops + carried
        var streams = read
        for op in carried { streams[op.device, default: []].append(op.opId) }
        self.streams = streams
        newestOpId = max(newestOpId ?? "", ops.map(\.opId).max() ?? "")
        self.provenance = provenance
        state = Self.derive(_ops)
    }

    private static func readHistory(
        figureId: String, projectURL: URL, opStore: OpLogStore
    ) async throws -> ([Op], [String: [String]], OpLogProvenance) {
        try OpLogStore.verifyOpsDirectoryListable(in: projectURL)
        let loaded = try await opStore.loadDiagnosedStreams(docId: figureId)
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
        return (loaded.ops, loaded.streams, loaded.provenance)
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
    /// a piece's (in a piece nobody has claimed it answers as the piece's text
    /// does, ruling R-D4). Asked fresh at every
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
    /// `DocumentNotWritableError`; a figure parked in Research throws
    /// `FigureParkedRefused` (ruling P-5), asked again after the posture's
    /// await; a posture that refuses throws `FigureEditRefused`
    /// (`RefusedWhat.figure`).
    func requireWritable(_ site: StaticString) async throws {
        if isClosed {
            documentLog.error(
                "\(site, privacy: .public) called on a closed FigureDocument \(self.figureId, privacy: .public); no-op")
            throw DocumentNotWritableError(site: "\(site)")
        }
        try refuseIfParked(site)
        guard await mayEditHere() else {
            documentLog.error(
                "\(site, privacy: .public) refused on \(self.figureId, privacy: .public): this device may not change this figure")
            throw FigureEditRefused(site: "\(site)")
        }
        // A park that landed during the posture's await closes the door too.
        try refuseIfParked(site)
    }

    /// **The one verb that runs on a parked figure**: its return
    /// (`resumeFromResearch`), whose own guard asks that it IS parked.
    private static let mayRunWhileParked: Set<String> = ["resumeFromResearch"]

    private func refuseIfParked(_ site: StaticString) throws {
        guard state.parked != nil, !Self.mayRunWhileParked.contains("\(site)") else { return }
        documentLog.error(
            "\(site, privacy: .public) refused on \(self.figureId, privacy: .public): the figure is parked in Research")
        throw FigureParkedRefused(site: "\(site)", kind: state.kind)
    }

    // MARK: - Mutators

    /// Set (or clear, with nil) one cell. `prior` is the cell it replaces.
    ///
    /// **A formula reading a Research table takes its pins** (spec §4.3):
    /// each source cell it reads that this cell holds no pin on is pinned
    /// here — the figure's own pin on it where another cell holds one, else
    /// the value read now (`FigurePins.entry`). They join the edit's ⌘Z: its
    /// undo clears them with the cell, its redo takes them again. A source
    /// that will not read takes none; the ref shows `#REF!` until a refresh.
    /// A pin whose append fails throws after the render, the edit and the
    /// pins that landed still undoable.
    public func setCell(_ cell: Cell?, at key: CellKey, undoManager: UndoManager? = nil) async throws {
        try await requireWritable("setCell")
        try requireTable()
        guard isLive(key) else { throw FigureEditInvalid(reason: "that cell's row or column is gone") }
        let prior = state.table[key]
        guard prior != cell else { return }
        var entryPins: [PinWrite] = []
        // The cheap gate is syntactic (`FigurePins.readsResearch`): it needs
        // no parked set or book; the entry itself reads the real ones.
        if case .formula(let f)? = cell?.content, FigurePins.readsResearch(f), let documentStore {
            var probe = state
            probe.table.setCell(cell, at: key)
            do {
                entryPins = try await documentStore.entryPins(for: probe, cells: [key])
            } catch {
                documentLog.error(
                    "figure \(self.figureId, privacy: .public): a formula's Research sources did not read, so it takes no pins: \(error.localizedDescription, privacy: .public)")
            }
            // The read awaited: the door and the cell are asked again.
            try await requireWritable("setCell")
            guard isLive(key), state.table[key] == prior else {
                throw FigureEditInvalid(reason: "the cell changed while its Research sources were read")
            }
        }
        let op = try await commit(
            .figureCellSet, FigureOpPayload(cell: key, next: cell, prior: prior), render: entryPins.isEmpty)
        var pinOps: [Op] = []
        var pinFailure: Error?
        if !entryPins.isEmpty {
            do {
                for w in entryPins {
                    pinOps.append(try await commit(.figurePinSet, FigureOpPayload(cell: w.cell, pin: w.pin), render: false))
                }
            } catch {
                documentLog.error(
                    "figure \(self.figureId, privacy: .public): a formula's pins were not all written: \(error.localizedDescription, privacy: .public)")
                pinFailure = error
            }
            await documentStore?.figureHostAppended(figureId)
        }
        let pinned = pinOps.compactMap { op in op.figure.flatMap { p in p.cell.flatMap { c in p.pin.map { (c, $0) } } } }
        registerFigureUndo(
            undoManager, actionName: "Edit Cell", forward: op, alongside: pinOps,
            stillAsWritten: { d in
                d.isLive(key) && d.state.table[key] == cell
                    && pinned.allSatisfy { d.state.pins[$0.0]?.contains($0.1) == true }
            },
            redo: { [weak undoManager] d in
                guard d.isLive(key), d.state.table[key] == prior else { return d.decline(.drifted) }
                await d.redoing { try await d.setCell(cell, at: key, undoManager: undoManager) }
            })
        if let pinFailure { throw pinFailure }
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
            redo: { [weak undoManager] d in
                guard d.rowIsDeleted(id) else { return d.decline(.drifted) }
                await d.redoing {
                    try await d.reviveRow(id, removed: FigureRemovedSlice(), undoManager: undoManager)
                }
            })
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
            redo: { [weak undoManager] d in
                guard d.columnIsDeleted(id) else { return d.decline(.drifted) }
                await d.redoing {
                    try await d.reviveColumn(id, removed: FigureRemovedSlice(), undoManager: undoManager)
                }
            })
        return id
    }

    /// Delete a row. The op carries what the row held (ruling P-2), so ⌘Z
    /// revives it in its own slot with its cells and pins — declined once
    /// another device has revived it since; the redo declines once the
    /// revived row holds anything the undo did not put back.
    public func deleteRow(_ id: RowID, undoManager: UndoManager? = nil) async throws {
        try await requireWritable("deleteRow")
        try requireTable()
        guard state.table.rowIndex(of: id) != nil else { throw FigureEditInvalid(reason: "that row is gone") }
        let slice = state.removedSlice(row: id)
        let op = try await commit(.figureStructure, FigureOpPayload(structure: .deleteRow(id), removed: slice))
        registerFigureUndo(
            undoManager, actionName: "Delete Row", forward: op,
            stillAsWritten: { d in d.rowIsDeleted(id) },
            redo: { [weak undoManager] d in
                // Only while the row holds exactly what the undo put back: a
                // cell another device typed into it since is not deleted again.
                guard d.state.table.rowIndex(of: id) != nil, d.state.removedSlice(row: id) == slice else {
                    return d.decline(.drifted)
                }
                await d.redoing { try await d.deleteRow(id, undoManager: undoManager) }
            })
    }

    /// Delete a column; the column's twin of `deleteRow`, its width carried too.
    public func deleteColumn(_ id: ColumnID, undoManager: UndoManager? = nil) async throws {
        try await requireWritable("deleteColumn")
        try requireTable()
        guard state.table.columnIndex(of: id) != nil else { throw FigureEditInvalid(reason: "that column is gone") }
        let slice = state.removedSlice(column: id)
        let op = try await commit(.figureStructure, FigureOpPayload(structure: .deleteColumn(id), removed: slice))
        registerFigureUndo(
            undoManager, actionName: "Delete Column", forward: op,
            stillAsWritten: { d in d.columnIsDeleted(id) },
            redo: { [weak undoManager] d in
                guard d.state.table.columnIndex(of: id) != nil, d.state.removedSlice(column: id) == slice else {
                    return d.decline(.drifted)
                }
                await d.redoing { try await d.deleteColumn(id, undoManager: undoManager) }
            })
    }

    /// **Bring a deleted row back in its own slot** with `removed` (ruling
    /// P-1) — an undone insert's redo, with an empty slice. Its own undo
    /// deletes it again, and only while the row still holds exactly what
    /// the revive put back (for an empty slice: R-6a-13's untouched row).
    func reviveRow(
        _ id: RowID, removed: FigureRemovedSlice, undoManager: UndoManager?
    ) async throws {
        try await requireWritable("reviveRow")
        try requireTable()
        guard rowIsDeleted(id) else { throw FigureEditInvalid(reason: "that row is not removed") }
        let op = try await commit(.figureStructure, FigureOpPayload(structure: .reviveRow(id), removed: removed))
        let restored = state.removedSlice(row: id)
        registerFigureUndo(
            undoManager, actionName: "Insert Row", forward: op,
            stillAsWritten: { d in d.state.table.rowIndex(of: id) != nil && d.state.removedSlice(row: id) == restored },
            redo: { [weak undoManager] d in
                guard d.rowIsDeleted(id) else { return d.decline(.drifted) }
                await d.redoing {
                    try await d.reviveRow(id, removed: removed, undoManager: undoManager)
                }
            })
    }

    /// The column's twin of `reviveRow`; a width counts as content too.
    func reviveColumn(
        _ id: ColumnID, removed: FigureRemovedSlice, undoManager: UndoManager?
    ) async throws {
        try await requireWritable("reviveColumn")
        try requireTable()
        guard columnIsDeleted(id) else { throw FigureEditInvalid(reason: "that column is not removed") }
        let op = try await commit(.figureStructure, FigureOpPayload(structure: .reviveColumn(id), removed: removed))
        let restored = state.removedSlice(column: id)
        registerFigureUndo(
            undoManager, actionName: "Insert Column", forward: op,
            stillAsWritten: { d in
                d.state.table.columnIndex(of: id) != nil && d.state.removedSlice(column: id) == restored
            },
            redo: { [weak undoManager] d in
                guard d.columnIsDeleted(id) else { return d.decline(.drifted) }
                await d.redoing {
                    try await d.reviveColumn(id, removed: removed, undoManager: undoManager)
                }
            })
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

    // MARK: - Batch verbs (report plan 7c Task 1)

    /// **Set (or clear, with nil) many cells as one visit** — a format over a
    /// selection, ⌫ over a range, Σ. One door check, one op per cell that
    /// changes (in table order), one render, and **one ⌘Z** that restores
    /// every cell (`registerFigureUndo`'s visit).
    ///
    /// - Every key must be live, or nothing is written (`FigureEditInvalid`).
    /// - **Every Research-reading formula takes its entry pins through one
    ///   read** (`DocumentStore.entryPins(for:cells:)`), as `setCell` does for
    ///   one: the door and every cell are asked again after it.
    /// - The drift guard covers every cell and pin it wrote; the redo re-runs
    ///   the batch while every cell still holds what it replaced.
    /// - An append that fails part way renders what landed, registers its
    ///   ⌘Z, and throws.
    public func setCells(
        _ edits: [CellKey: Cell?], actionName: String, undoManager: UndoManager? = nil
    ) async throws {
        try await requireWritable("setCells")
        try requireTable()
        guard edits.keys.allSatisfy(isLive) else {
            throw FigureEditInvalid(reason: "a cell's row or column is gone")
        }
        let table = state.table
        let changes: [(key: CellKey, next: Cell?, prior: Cell?)] = edits
            .compactMap { key, next in table[key] == next ? nil : (key, next, table[key]) }
            .sorted { a, b in
                let ra = table.rowIndex(of: a.key.row)!, rb = table.rowIndex(of: b.key.row)!
                return ra != rb ? ra < rb : table.columnIndex(of: a.key.column)! < table.columnIndex(of: b.key.column)!
            }
        guard !changes.isEmpty else { return }
        let stillPrior: (FigureDocument) -> Bool = { d in
            changes.allSatisfy { d.isLive($0.key) && d.state.table[$0.key] == $0.prior }
        }
        var entryPins: [PinWrite] = []
        let formulaKeys = Set(changes.compactMap { c -> CellKey? in
            guard case .formula(let f)? = c.next?.content, FigurePins.readsResearch(f) else { return nil }
            return c.key
        })
        if !formulaKeys.isEmpty, let documentStore {
            var probe = state
            for c in changes { probe.table.setCell(c.next, at: c.key) }
            do {
                entryPins = try await documentStore.entryPins(for: probe, cells: formulaKeys)
            } catch {
                documentLog.error(
                    "figure \(self.figureId, privacy: .public): a batch's Research sources did not read, so it takes no pins: \(error.localizedDescription, privacy: .public)")
            }
            // The read awaited: the door and every cell are asked again.
            try await requireWritable("setCells")
            guard stillPrior(self) else {
                throw FigureEditInvalid(reason: "a cell changed while its Research sources were read")
            }
        }
        var written: [Op] = []
        var failure: Error?
        do {
            for c in changes {
                written.append(try await commit(
                    .figureCellSet, FigureOpPayload(cell: c.key, next: c.next, prior: c.prior), render: false))
            }
            for w in entryPins {
                written.append(try await commit(.figurePinSet, FigureOpPayload(cell: w.cell, pin: w.pin), render: false))
            }
        } catch {
            documentLog.error(
                "figure \(self.figureId, privacy: .public): a batch was not all written: \(error.localizedDescription, privacy: .public)")
            failure = error
        }
        guard let first = written.first else { throw failure ?? FigureEditInvalid(reason: "nothing was written") }
        await documentStore?.figureHostAppended(figureId)
        let landed = written.compactMap(\.figure)
        let cells = landed.filter { $0.pin == nil }.compactMap { p in p.cell.map { ($0, p.next) } }
        let pins = landed.compactMap { p in p.pin.flatMap { pin in p.cell.map { ($0, pin) } } }
        let redoEdits = Dictionary(uniqueKeysWithValues: changes.prefix(cells.count).map { ($0.key, $0.next) })
        let redoPriors = Array(changes.prefix(cells.count))
        registerFigureUndo(
            undoManager, actionName: actionName, forward: first, alongside: Array(written.dropFirst()),
            stillAsWritten: { d in
                cells.allSatisfy { d.isLive($0.0) && d.state.table[$0.0] == $0.1 }
                    && pins.allSatisfy { d.state.pins[$0.0]?.contains($0.1) == true }
            },
            redo: { [weak undoManager] d in
                guard redoPriors.allSatisfy({ d.isLive($0.key) && d.state.table[$0.key] == $0.prior }) else {
                    return d.decline(.drifted)
                }
                await d.redoing {
                    try await d.setCells(redoEdits, actionName: actionName, undoManager: undoManager)
                }
            })
        if let failure { throw failure }
    }

    /// **Sort the body rows by one column, as one visit** (ruling R7c-7):
    /// `FigureSort.order` over `values` — each cell's computed value, which the
    /// caller holds — turned into row moves, so each row keeps its cells and
    /// every formula keeps reading by id. Header and total rows stay put.
    /// One door check, one render, **one ⌘Z** back to the old order, declined
    /// once the order has changed since; the redo sorts by the values this
    /// sort read. An order already sorted writes nothing.
    public func sortRows(
        by column: ColumnID, ascending: Bool, values: (CellKey) -> CellValue,
        actionName: String, undoManager: UndoManager? = nil
    ) async throws {
        try await requireWritable("sortRows")
        try requireTable()
        guard state.table.columnIndex(of: column) != nil else { throw FigureEditInvalid(reason: "that column is gone") }
        let before = state.table.rows
        let order = FigureSort.order(table: state.table, values: values, column: column, ascending: ascending)
        guard order != before else { return }
        // Each row of `order` in turn goes just after the one before it,
        // unless it already follows it; a scratch copy says which do.
        var scratch = state.table
        var moves: [(row: RowID, after: RowID?)] = []
        for (i, row) in order.enumerated() {
            let after = i == 0 ? nil : order[i - 1]
            let live = scratch.rows
            guard let at = live.firstIndex(of: row) else { continue }
            if at == 0 ? after == nil : live[at - 1] == after { continue }
            scratch.moveRow(row, after: after)
            moves.append((row, after))
        }
        var written: [Op] = []
        var failure: Error?
        do {
            for m in moves {
                let priorAfter = rowPredecessor(m.row) ?? nil
                written.append(try await commit(.figureStructure, FigureOpPayload(
                    structure: .moveRow(m.row, after: m.after, priorAfter: priorAfter)), render: false))
            }
        } catch {
            documentLog.error(
                "figure \(self.figureId, privacy: .public): a sort was not all written: \(error.localizedDescription, privacy: .public)")
            failure = error
        }
        guard let first = written.first else { throw failure ?? FigureEditInvalid(reason: "nothing was written") }
        await documentStore?.figureHostAppended(figureId)
        let landed = Array(moves.prefix(written.count))
        let sorted = state.table.rows
        // What this sort read, so its redo sorts the same rows the same way.
        let read = Dictionary(uniqueKeysWithValues: before.map { ($0, values(CellKey(row: $0, column: column))) })
        registerFigureUndo(
            undoManager, actionName: actionName, forward: first, alongside: Array(written.dropFirst()),
            stillAsWritten: { d in
                d.state.table.rows == sorted && landed.allSatisfy { d.rowPredecessor($0.row) == .some($0.after) }
            },
            redo: { [weak undoManager] d in
                guard d.state.table.rows == before else { return d.decline(.drifted) }
                await d.redoing {
                    try await d.sortRows(
                        by: column, ascending: ascending, values: { read[$0.row] ?? .empty },
                        actionName: actionName, undoManager: undoManager)
                }
            })
        if let failure { throw failure }
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
        // The name came from the op log or a synced record: written to only
        // when it is one plain file inside `figures/`, and `figures/` itself
        // is inside the book on disk (`SafeRelativePath.resolveFile`).
        let destination: URL
        do {
            destination = try SafeRelativePath.resolveFile(
                named: filename, in: ProjectStore.figuresFolder, under: projectURL)
        } catch {
            throw FigureEditInvalid(reason: "this figure's file name is not a file in figures/")
        }
        let hash = try await Task.detached { try FigureImageResolver.contentHash(of: copyable.url) }.value
        guard hash != prior?.contentHash else { return }

        // Both pictures kept before anything changes, so ⌘Z and redo can put
        // either back; the prior one only if it is still on disk.
        let keptPrior = prior.flatMap { try? keepForUndo(destination, hash: $0.contentHash) }
        let keptNext = try keepForUndo(copyable.url, hash: hash)
        try await documentStore.replaceFigureImage(at: destination, withCopyOf: copyable.url)

        let next = FigureImageRef(filename: filename, contentHash: hash)
        let op: Op
        do {
            op = try await commit(.figureImageSet, FigureOpPayload(image: next, priorImage: prior))
        } catch {
            // The op never landed, so the file goes back to the picture the
            // op log still names: the publisher stages what the file holds.
            // A first picture has none to go back to.
            if let keptPrior {
                do { try await documentStore.replaceFigureImage(at: destination, withCopyOf: keptPrior) } catch {
                    documentLog.error(
                        "figure \(self.figureId, privacy: .public): the picture could not be put back after a failed append: \(error.localizedDescription, privacy: .public)")
                }
            }
            throw error
        }
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
            unrestoring: { d in
                try await d.documentStore?.replaceFigureImage(at: destination, withCopyOf: keptNext)
            },
            redo: { [weak undoManager] d in
                guard d.state.image == prior else { return d.decline(.drifted) }
                await d.redoing { try await d.setImage(fromURL: keptNext, undoManager: undoManager) }
            })
    }

    /// **An image figure's picture takes a new file name** — its rename's
    /// half (`ProjectStore.renameFigure`, ruling P-3): the file under
    /// `figures/` is moved through the window's typed mover, then one
    /// `figureImageSet` is appended carrying the same hash and the new name,
    /// so the next `setImage` writes the new file. The op failing moves the
    /// file back. A figure with no picture yet has no file to move: nothing
    /// is written. Not registered for ⌘Z: a rename is undone by renaming.
    func renameImageFile(to filename: String) async throws {
        try await requireWritable("renameImageFile")
        guard state.kind == .image else {
            throw FigureEditInvalid(reason: "this figure is not an image")
        }
        guard let documentStore else {
            throw FigureEditInvalid(reason: "a picture is renamed only in a window that holds the figure")
        }
        guard let prior = state.image, prior.filename != filename else { return }
        // Both names are checked as one plain file inside `figures/`: the old
        // came from the op log, the new from a synced record's name.
        let from: URL
        let to: URL
        do {
            from = try SafeRelativePath.resolveFile(
                named: prior.filename, in: ProjectStore.figuresFolder, under: projectURL)
            to = try SafeRelativePath.resolveFile(
                named: filename, in: ProjectStore.figuresFolder, under: projectURL)
        } catch {
            throw FigureEditInvalid(reason: "this figure's file name is not a file in figures/")
        }
        try await documentStore.moveFigureFile(from: from, to: to)
        do {
            try await commit(.figureImageSet, FigureOpPayload(
                image: FigureImageRef(filename: filename, contentHash: prior.contentHash),
                priorImage: prior))
        } catch {
            // The op never landed: the file goes back to the name the op log
            // still says.
            do { try await documentStore.moveFigureFile(from: to, to: from) } catch {
                documentLog.error(
                    "figure \(self.figureId, privacy: .public): the picture could not be moved back after a failed append: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    /// **Park this figure in Research** (spec §4.2, ruling P-5) — *Send to
    /// Research*'s op (`ProjectStore.sendToResearch`): one `figureParked`
    /// carrying the working copy's path, content hash and Research item.
    ///
    /// - **Refused when the figure changed since the copy was made**
    ///   (`expecting`, the state the caller wrote the copy from): the copy
    ///   must hold exactly what is parked, so nothing is appended and
    ///   `FigureEditInvalid` says so.
    /// - **`alongside` runs synchronously, after every check and before the
    ///   op folds**, so nothing can land between them — the send removes the
    ///   figure's line from its manuscript there. It throwing appends nothing.
    /// - **The op sorts after every op this host has read** (`commit`'s
    ///   `after:`), so an edit the copy holds, from a device whose clock ran
    ///   ahead, still folds before the park rather than being dropped by it.
    /// - **It records what this host had read** (`parkedFrontier`: per device,
    ///   the last op of its own stream in append order), so the return can tell the state
    ///   the copy was written from from an edit that sorts before the park but
    ///   arrived after it (`FigureReturnDiff.base(of:streams:frontier:)`).
    /// - Not registered for ⌘Z (ruling P-8): a park is undone by bringing the
    ///   figure back. From here on every mutator refuses
    ///   (`FigureParkedRefused`).
    func parkInResearch(
        path: String, hash: String, itemId: String, expecting: FigureState,
        alongside: @MainActor () throws -> Void
    ) async throws {
        try await requireWritable("parkInResearch")
        guard state == expecting else {
            throw FigureEditInvalid(reason: "the figure changed while it was being sent to Research")
        }
        try alongside()
        try await commit(
            .figureParked,
            FigureOpPayload(parkedPath: path, parkedHash: hash, parkedItemId: itemId,
                            parkedFrontier: streams.compactMapValues(\.last)))
    }

    // MARK: - Research pins (report plan 6b Task 9, spec §4.3, R-D2)

    /// **Where each source this figure's pins read stands** — every Research
    /// table its formulas name, and every figure they read that is parked in
    /// Research (`FigurePins.status`). For plans 7–9's markers and publish
    /// notes. Empty with no window, or when the sources will not read (logged).
    ///
    /// **Never from a view body or per frame**: it assembles the book, resolves
    /// trust and reads every source file. A surface caches the answer on the
    /// host and asks again after `figureHostAppended` or a presenter change.
    public func pinStatus() async -> [String: PinStatus] {
        guard let sources = await readPinSources() else { return [:] }
        return FigurePins.status(of: state, sources: sources)
    }

    /// **Compare**: each position this figure reads through a pin whose value
    /// a refresh would change, old beside new (`FigurePins.compare`). Empty
    /// with no window, or when the sources will not read (logged).
    public func comparePins() async -> [PinComparison] {
        guard let sources = await readPinSources() else { return [] }
        return FigurePins.compare(state: state, sources: sources)
    }

    private func readPinSources() async -> PinSources? {
        guard let documentStore else { return nil }
        do { return try await documentStore.pinSources(for: state) } catch {
            documentLog.error(
                "figure \(self.figureId, privacy: .public): its Research sources did not read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// **Refresh** (spec §4.3, Denver's ruling R-D2): re-read every source
    /// this figure's pins read — a Research table at each pinned position, a
    /// parked figure's working copy at the cell's position in its parked
    /// table — and write the pins that moved, into THIS figure only, as
    /// `figurePinSet` ops each carrying the pin it replaces (`priorPin`).
    ///
    /// - **This figure's door** (`.editFigure`, through `requireWritable`),
    ///   asked before the read and again after it; nothing is read for a Mac
    ///   that may not write it. Needs the window's store to read the sources.
    /// - A source that is gone keeps its values; nothing is written for it.
    /// - **One ⌘Z** (ruling P-8) for the whole refresh, through
    ///   `registerFigureUndo`'s visit: the inverses, last first, declined when
    ///   another device has since changed a pin it wrote. Redo refreshes again.
    public func refreshPins(undoManager: UndoManager? = nil) async throws {
        try await requireWritable("refreshPins")
        try requireTable()
        guard let documentStore else {
            throw FigureEditInvalid(reason: "Research can only be read from the book's window")
        }
        let sources = try await documentStore.pinSources(for: state)
        // The read awaited: the door is asked again before anything is written.
        try await requireWritable("refreshPins")
        let writes = FigurePins.refresh(state: state, sources: sources, at: Date())
        guard !writes.isEmpty else { return }
        var written: [Op] = []
        var failure: Error?
        do {
            for w in writes {
                written.append(try await commit(
                    .figurePinSet, FigureOpPayload(cell: w.cell, pin: w.pin, priorPin: w.prior), render: false))
            }
        } catch {
            failure = error
        }
        await documentStore.figureHostAppended(figureId)
        // One ⌘Z for what landed: the drift guard asks every pin it wrote is
        // still on its cell; redo refreshes again.
        if let first = written.first {
            let pins = writes.prefix(written.count).map { ($0.cell, $0.pin) }
            registerFigureUndo(
                undoManager, actionName: "Refresh from Research", forward: first, alongside: Array(written.dropFirst()),
                stillAsWritten: { d in pins.allSatisfy { d.state.pins[$0.0]?.contains($0.1) == true } },
                redo: { [weak undoManager] d in
                    await d.redoing { try await d.refreshPins(undoManager: undoManager) }
                })
        }
        if let failure { throw failure }
    }

    /// **Bring this figure back from Research** (spec §4.2 "Coming back",
    /// ruling P-7) — `ProjectStore.bringBack`'s op: a `figureResumed`, then
    /// `changes` (`FigureReturnDiff`'s, for a table whose copy changed), then,
    /// for a picture whose copy changed, the copy in place of its file and one
    /// `figureImageSet`.
    ///
    /// - **The resume comes first**: content ordered between the park and the
    ///   resume folds nothing (ruling P-5); `commit` mints every op after the
    ///   newest this host has folded, so a park minted ahead of this Mac's
    ///   clock still sorts before the resume, and each change after it.
    /// - **Signed by whoever brings it back** (this host's actor) and carrying
    ///   `SynthesisSource.broughtBackFromResearch`, every one.
    /// - **Refused unless the figure is parked and still `expecting`**, the
    ///   state the changes were made against: nothing is appended.
    /// - **Every change is checked to apply before anything is appended**
    ///   (`FigureReturnDiff.everyChangeApplies`). An append that still fails after the
    ///   resume parks the figure again exactly as it was — the changes that
    ///   landed stay, and count as written from at the retry
    ///   (`FigureReturnDiff.base`) — and throws `FigureBringBackIncomplete`.
    /// - The picture is replaced before anything is appended and put back if
    ///   the resume or its op fails.
    /// - Not registered for ⌘Z (ruling P-8): a return is undone by sending the
    ///   figure to Research again. The render follows once, at the end.
    func resumeFromResearch(
        changes: [FigureReturnDiff.Change], picture: (url: URL, hash: String)?, expecting: FigureState
    ) async throws {
        try await requireWritable("resumeFromResearch")
        guard state.parked != nil else {
            throw FigureEditInvalid(reason: "this figure is not in Research")
        }
        guard state == expecting else {
            throw FigureEditInvalid(reason: "the figure changed while it was being brought back")
        }
        let reason = Op.Provenance(synthesisSource: .broughtBackFromResearch)
        guard let parking = state.parked else { throw FigureEditInvalid(reason: "this figure is not in Research") }
        guard FigureReturnDiff.everyChangeApplies(changes, onto: state) else {
            throw FigureEditInvalid(reason: "the copy's changes don't fit the figure")
        }
        var newImage: FigureOpPayload?
        var putPictureBack: (() async -> Void)?
        if let picture {
            (newImage, putPictureBack) = try await placeReturningPicture(picture)
        }
        var applied = 0
        var resumed = false
        do {
            // It names the park it resumes: a copy of an earlier park,
            // brought back after the figure was sent again, folds nothing.
            let resume = try await commit(
                .figureResumed, FigureOpPayload(parkedItemId: parking.itemId), provenance: reason, render: false)
            resumed = true
            // Each names its resume (`returnOf`, final review M-2): a return
            // whose resume another Mac's beat folds none of its ops.
            for change in changes {
                var payload = change.payload
                payload.returnOf = resume.opId
                try await commit(change.kind, payload, provenance: reason, render: false)
                applied += 1
            }
            if var newImage {
                newImage.returnOf = resume.opId
                try await commit(.figureImageSet, newImage, provenance: reason, render: false)
            }
        } catch {
            // The picture op is the last: unless it landed, the file goes back
            // to the picture the op log still names.
            if let newImage, state.image != newImage.image { await putPictureBack?() }
            guard resumed else {
                await documentStore?.figureHostAppended(figureId)
                throw error
            }
            // Part way: parked again exactly as it was, so the copy still
            // routes back here and a retry brings back what is left.
            var parkedAgain = true
            do {
                try await commit(.figureParked, FigureOpPayload(
                    parkedPath: parking.path, parkedHash: parking.hash, parkedItemId: parking.itemId,
                    parkedFrontier: parking.frontier), render: false)
            } catch {
                parkedAgain = false
                documentLog.error(
                    "figure \(self.figureId, privacy: .public): a return stopped part way and could not be parked again: \(error.localizedDescription, privacy: .public)")
            }
            await documentStore?.figureHostAppended(figureId)
            throw FigureBringBackIncomplete(
                applied: applied, of: changes.count + (newImage == nil ? 0 : 1), parkedAgain: parkedAgain)
        }
        await documentStore?.figureHostAppended(figureId)
    }

    // MARK: - Checkpoint restore (report plan 6c Task 2, rulings Q-1, Q-2)

    /// **Wind this figure back to a checkpoint** — to the figure at its op
    /// `pointer` (`FigureRestoreDiff.target` over this host's ops). The changes
    /// that bring the figure as it stands now to it (`FigureRestoreDiff.changes`)
    /// are appended as ordinary figure ops, each carrying
    /// `provenance.sourceCheckpoint = checkpointId` and signed by this host's
    /// actor; the render follows once, after the last.
    ///
    /// - **This figure's door** (`.editFigure`, through `requireWritable`),
    ///   asked again after the pin sources' read; a refusal throws
    ///   `FigureEditRefused` before any op. A figure parked in Research is
    ///   skipped (`.skippedParked`) with nothing appended: its content lives in
    ///   the working copy until it comes back. One parked or resumed after the
    ///   pointer is skipped too (`.skippedWentToResearch`, final review I5).
    /// - **A pin live now is never replaced by one inert now**: the current
    ///   park cycle of every figure the pins name, now or then, goes to the
    ///   diff (`DocumentStore.parkCycles`). With no window there are none to
    ///   read, and every pin counts.
    /// - **Every change is checked to apply before anything is appended**
    ///   (`FigureReturnDiff.everyChangeApplies`).
    /// - **A picture comes back only when its bytes still exist** — a file in
    ///   `figures/` or in this open host's undo folder with the checkpoint's
    ///   content hash, of the figure's own format — written under the
    ///   figure's current file name through the window's door; `pictureHashes`
    ///   hashes each file in `figures/` once per restore (final review M6).
    ///   Otherwise the
    ///   rest is restored and the outcome names the picture
    ///   (`.skippedPicture`, with what did restore). A checkpoint with no
    ///   picture takes none away.
    /// - **It stops part way rather than write against a fold that moved**:
    ///   another device's lines read in meanwhile (a `reload`) stop it before
    ///   the next op, and an op that will not write stops it too; either way
    ///   what landed stays and the answer is `.partlyRestored` with the count.
    ///   **Restoring again is safe**: the diff is worked out afresh from the
    ///   figure as it then stands, so it does only what is left. An op that
    ///   fails before any landed throws.
    /// - Not registered for ⌘Z (ruling Q-2), like the text's partial restore.
    func restoreToCheckpoint(
        _ checkpointId: String, through pointer: String,
        pictureHashes: FigurePictureHashes = FigurePictureHashes()
    ) async throws -> FigureRestoreOutcome {
        do { try await requireWritable("restoreToCheckpoint") } catch is FigureParkedRefused { return .skippedParked }
        if FigureRestoreDiff.wentToResearch(since: pointer, in: _ops) { return .skippedWentToResearch }
        let first = FigureRestoreDiff.target(of: _ops, through: pointer)
        let parks = try await currentParks(reading: first)
        let wanted = first.image.flatMap { $0.contentHash == state.image?.contentHash ? nil : $0 }
        let picture = await keptPicture(wanted, hashes: pictureHashes)
        // The reads awaited: the door is asked again before anything is written.
        do { try await requireWritable("restoreToCheckpoint") } catch is FigureParkedRefused { return .skippedParked }
        if FigureRestoreDiff.wentToResearch(since: pointer, in: _ops) { return .skippedWentToResearch }
        let target = FigureRestoreDiff.target(of: _ops, through: pointer)

        let changes = FigureRestoreDiff.changes(from: state, to: target, parks: parks)
        let tableChanges = changes.filter { $0.kind != .figureImageSet }
        guard FigureReturnDiff.everyChangeApplies(tableChanges, onto: state) else {
            throw FigureEditInvalid(reason: "the checkpoint's changes don't fit the figure")
        }
        let pictureChange = changes.first { $0.kind == .figureImageSet }?.payload.image
        let restoresPicture = pictureChange != nil && pictureChange?.contentHash == picture?.hash
        let reason = Op.Provenance(sourceCheckpoint: checkpointId)
        // Every change was worked out against this fold: a reload replaces it.
        let generation = reloadGeneration
        var appended = 0
        var stop: FigureRestoreOutcome.Stop?
        do {
            for change in tableChanges {
                if appended > 0, let hook = Self.betweenRestoreOpsForTesting { await hook(self) }
                guard reloadGeneration == generation else { stop = .changedElsewhere; break }
                try await commit(change.kind, change.payload, provenance: reason, render: false)
                appended += 1
            }
            if stop == nil, restoresPicture, let picture {
                if appended > 0, let hook = Self.betweenRestoreOpsForTesting { await hook(self) }
                if reloadGeneration != generation {
                    stop = .changedElsewhere
                } else {
                    let (payload, putBack) = try await placeReturningPicture(picture)
                    do {
                        try await commit(.figureImageSet, payload, provenance: reason, render: false)
                    } catch {
                        await putBack()
                        throw error
                    }
                    appended += 1
                }
            }
        } catch {
            guard appended > 0 else { throw error }
            stop = .notRecorded(error.localizedDescription)
        }
        if appended > 0 { await documentStore?.figureHostAppended(figureId) }
        if let stop { return .partlyRestored(opCount: appended, why: stop) }
        if let pictureChange, !restoresPicture {
            return .skippedPicture(hash: pictureChange.contentHash, opCount: appended)
        }
        return appended == 0 ? .unchanged : .restored(opCount: appended)
    }

    /// Test seam: runs in `restoreToCheckpoint` between one landed op and the
    /// next — where another device's reload is put. Nil in production.
    static var betweenRestoreOpsForTesting: (@MainActor (FigureDocument) async -> Void)?

    /// The current park cycle of each figure this figure's pins name, now or
    /// in `target` — whether or not a formula reads it
    /// (`DocumentStore.parkCycles`, one assembly). Empty with no window, or
    /// when neither holds a pin. Throws when the registry will not read:
    /// nothing has been written yet.
    private func currentParks(reading target: FigureState) async throws -> [String: String] {
        let sources = Set([state.pins, target.pins].flatMap { $0.values.joined() }.map(\.research))
        guard let documentStore, !sources.isEmpty else { return [:] }
        return try await documentStore.parkCycles(of: sources)
    }

    /// A file holding picture `wanted`'s bytes that may go in place of this
    /// figure's file: one in this host's undo folder (kept by content hash) or
    /// in `figures/`, of the figure's own format. Nil when there is none, no
    /// picture is wanted, the figure has no file to write over, or no window
    /// holds it to write through.
    private func keptPicture(
        _ wanted: FigureImageRef?, hashes: FigurePictureHashes
    ) async -> (url: URL, hash: String)? {
        guard let wanted, state.kind == .image, let current = state.image, documentStore != nil else { return nil }
        let ext = (current.filename as NSString).pathExtension.lowercased()
        let fm = FileManager.default
        if let imageUndoFolder,
           let kept = try? fm.contentsOfDirectory(at: imageUndoFolder, includingPropertiesForKeys: nil)
            .first(where: { $0.deletingPathExtension().lastPathComponent == wanted.contentHash
                && Self.sameImageFormat($0.pathExtension.lowercased(), ext) }) {
            return (kept, wanted.contentHash)
        }
        let folder = projectURL.appendingPathComponent(ProjectStore.figuresFolder, isDirectory: true) // local-path: the app's own folder name
        let candidates = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !DotfileScan.isDotfile($0) && Self.sameImageFormat($0.pathExtension.lowercased(), ext) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let found = await hashes.first(in: candidates, matching: wanted.contentHash)
        return found.map { ($0, wanted.contentHash) }
    }

    /// A returning picture's copy in place of this figure's file, kept name
    /// and all, and its `figureImageSet` payload — with how to put the old
    /// picture back. Through the window's coordinated door.
    private func placeReturningPicture(
        _ picture: (url: URL, hash: String)
    ) async throws -> (FigureOpPayload, () async -> Void) {
        guard state.kind == .image, let prior = state.image else {
            throw FigureEditInvalid(reason: "this figure has no picture to bring back over")
        }
        guard let documentStore else {
            throw FigureEditInvalid(reason: "a picture is brought back only in a window that holds the figure")
        }
        let current = (prior.filename as NSString).pathExtension.lowercased()
        let ext = picture.url.pathExtension.lowercased()
        guard Self.sameImageFormat(current, ext) else {
            throw FigureEditInvalid(
                reason: "this figure's picture is a .\(current) file; a .\(ext) picture can't replace it")
        }
        let destination: URL
        do {
            destination = try SafeRelativePath.resolveFile(
                named: prior.filename, in: ProjectStore.figuresFolder, under: projectURL)
        } catch {
            throw FigureEditInvalid(reason: "this figure's file name is not a file in figures/")
        }
        let kept = try? keepForUndo(destination, hash: prior.contentHash)
        try await documentStore.replaceFigureImage(at: destination, withCopyOf: picture.url)
        let figureId = self.figureId
        return (
            FigureOpPayload(image: FigureImageRef(filename: prior.filename, contentHash: picture.hash),
                            priorImage: prior),
            { [weak documentStore] in
                guard let kept, let documentStore else { return }
                do { try await documentStore.replaceFigureImage(at: destination, withCopyOf: kept) } catch {
                    documentLog.error(
                        "figure \(figureId, privacy: .public): the picture could not be put back after a failed return: \(error.localizedDescription, privacy: .public)")
                }
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
        /// The picture an undo would put back is no longer kept.
        case pictureNotKept
        /// The undo or redo could not be written to the figure's history.
        case notRecorded
        /// The redo no longer fits the figure (`FigureEditInvalid`'s reason:
        /// a row or column gone, a picture no longer kept) — said as that,
        /// never as a failed save (residual N-4).
        case cannotRedo(String)
        /// The figure is parked in Research (ruling P-5); its notice.
        case parked(FigureKind?)

        var sentence: String {
            switch self {
            case .drifted:
                "Couldn't undo the change to the figure — it changed on another device."
            case .notPermitted:
                "Couldn't change the table — this Mac can no longer change this figure."
            case .pictureNotKept:
                "Couldn't put the picture back — the one it replaced is no longer kept."
            case .notRecorded:
                "Couldn't change the figure — the change could not be saved."
            case .cannotRedo(let reason):
                "Couldn't redo the change to the figure — \(reason)."
            case .parked(let kind):
                FigureParkedRefused.notice(for: kind)
            }
        }
    }

    private func decline(_ why: FigureUndoDecline) {
        documentLog.error("figure undo declined on \(self.figureId, privacy: .public): \(String(describing: why), privacy: .public)")
        MaughamEvent.postNotice(why.sentence, projectURL: projectURL)
    }

    /// A redo re-enters the forward mutator; a refusal there is said as one,
    /// and an edit that no longer fits as that — only a failed write is
    /// "could not be saved".
    private func redoing(_ body: () async throws -> Void) async {
        do { try await body() } catch is FigureEditRefused {
            decline(.notPermitted)
        } catch let parked as FigureParkedRefused {
            decline(.parked(parked.kind))
        } catch let invalid as FigureEditInvalid {
            decline(.cannotRedo(invalid.reason))
        } catch {
            documentLog.error("figure redo failed on \(self.figureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            decline(.notRecorded)
        }
    }

    /// **The one ⌘Z registration for a figure op** — the mechanism
    /// `OpKindUndoExhaustivenessTests` names. The inverse is
    /// `FigureInverse.inverse` of the forward op's payload — a delete's is a
    /// revive carrying the slice it took; where it answers nil (a first
    /// image, a delete that recorded no slice) nothing is registered.
    /// `alongside` makes it one visit (`FigureInverse.compensating`, all or
    /// nothing): a formula's entry pins with its cell edit, a pin refresh's
    /// sets. The undo:
    /// 1. **the door** — this Mac must still be allowed to change the figure
    ///    (the window's posture, yields included);
    /// 2. **drift guard** — `stillAsWritten` must hold (the cell still holds
    ///    the op's `next`, the row is still where the move put it, …), or it
    ///    declines rather than clobber another device's write;
    /// 3. `restoring`, where the op's content lives outside the stream (an
    ///    image's file): put back first, and a failure there appends nothing;
    /// 4. appends the compensating op, registering nothing further (the
    ///    registrar has already put `redo` on the redo stack). A failed append
    ///    runs `unrestoring` (the file back to what the op log names) and
    ///    says so (`.notRecorded`).
    func registerFigureUndo(
        _ undoManager: UndoManager?, actionName: String, forward: Op, alongside: [Op] = [],
        stillAsWritten: @escaping @MainActor (FigureDocument) -> Bool,
        restoring: (@MainActor (FigureDocument) async throws -> Void)? = nil,
        unrestoring: (@MainActor (FigureDocument) async throws -> Void)? = nil,
        redo: @escaping @MainActor (FigureDocument) async -> Void
    ) {
        let visit = ([forward] + alongside).compactMap { op in op.figure.map { (op.kind, $0) } }
        let inverses = FigureInverse.compensating(visit: visit)
        guard visit.count == alongside.count + 1, !inverses.isEmpty else { return }
        OpUndoRegistrar.register(
            undoManager, actionName: actionName, target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { d in
                guard !d.isClosed else { return }
                guard await d.mayEditHere() else { return d.decline(.notPermitted) }
                // After the door's await, so nothing lands between the check
                // and the append. A parked figure folds nothing (ruling P-5).
                guard d.state.parked == nil else { return d.decline(.parked(d.state.kind)) }
                guard stillAsWritten(d) else { return d.decline(.drifted) }
                do { try await restoring?(d) } catch {
                    documentLog.error("figure undo could not restore \(d.figureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return d.decline(.pictureNotKept)
                }
                do {
                    // A visit renders once, after its last inverse.
                    for (i, (kind, inverse)) in inverses.enumerated() {
                        try await d.commit(kind, inverse, render: i == inverses.count - 1)
                    }
                } catch {
                    if inverses.count > 1 { await d.documentStore?.figureHostAppended(d.figureId) }
                    documentLog.error("figure undo append failed on \(d.figureId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    // What `restoring` put back goes back to what the op
                    // log still names, so the file and the history agree.
                    do { try await unrestoring?(d) } catch {
                        documentLog.error("figure undo could not re-place \(d.figureId, privacy: .public) after a failed append: \(error.localizedDescription, privacy: .public)")
                    }
                    // Said, not only logged: the ⌘Z was consumed and the
                    // figure is as it was.
                    d.decline(.notRecorded)
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
    /// The op's id sorts strictly after the newest op this host has folded, and
    /// after `after`, even when this Mac's clock is behind the device that
    /// wrote it (`ULID.generate(atMillis:)`).
    ///
    /// `provenance` rides the op (a return's reason, ruling P-7). With
    /// `render: false` the caller renders once itself, after a run of ops.
    @discardableResult
    private func commit(
        _ kind: OpKind, _ payload: FigureOpPayload, after floor: String? = nil,
        provenance: Op.Provenance? = nil, render: Bool = true
    ) async throws -> Op {
        guard !isClosed else { throw DocumentNotWritableError(site: "commit") }
        var opId = ULID.generate()
        // After the newest op this host has folded, and after `floor`: a
        // device whose clock ran ahead never puts this Mac's next edit behind
        // what it already shows.
        let floor = max(floor ?? "", newestOpId ?? "")
        if !floor.isEmpty, opId <= floor, let millis = ULID.timestampMillis(of: floor) {
            opId = ULID.generate(atMillis: millis + 1)
        }
        let op = Op(
            opId: opId, docId: figureId, at: Date(), device: device,
            session: session, kind: kind, changes: [], provenance: provenance, figure: payload)
        _ops.append(op)
        streams[device, default: []].append(op.opId)
        newestOpId = op.opId
        unconfirmedLocalOpIds.insert(op.opId)
        FigureDeriver.fold(op, into: &state)
        do {
            try Self.beforeCommitAppendForTesting?(op)
            try await opStore.append(op)
            // Only while unconfirmed: a read that already contained it has
            // forgotten it, and must not leave this id behind.
            if unconfirmedLocalOpIds.contains(op.opId) { appendedLocalOpIds.insert(op.opId) }
        } catch {
            unconfirmedLocalOpIds.remove(op.opId)
            _ops.removeAll { $0.opId == op.opId }
            streams[device]?.removeAll { $0 == op.opId }
            state = Self.derive(_ops)
            throw error
        }
        // The render follows every op this host appends (report plan 6a
        // Task 7): `figures/<name>.csv` and every table reading this one.
        // Windowless, there is no coordinated door to write through.
        if render { await documentStore?.figureHostAppended(figureId) }
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
    /// while it is live, holds no cell and no pin: the inverse is a delete
    /// with an empty slice, so its redo would bring the row back empty — a row
    /// another device has typed into since is left standing (Review Focus 5).
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

    /// Is `id` a tombstone — held once, deleted now? What a revive needs.
    func rowIsDeleted(_ id: RowID) -> Bool {
        state.table.rowSlotIndex(of: id) != nil && state.table.rowIndex(of: id) == nil
    }

    func columnIsDeleted(_ id: ColumnID) -> Bool {
        state.table.columnSlotIndex(of: id) != nil && state.table.columnIndex(of: id) == nil
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
