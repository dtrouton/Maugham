import Foundation
import MaughamCore

/// **Why the author's answer to a figure note was refused** (report plan
/// 9c-1). Thrown before anything is written: no op, no state change, no ⌘Z.
/// A closed host throws `DocumentNotWritableError` and a parked figure
/// `FigureParkedRefused`, as every figure verb does.
public enum FigureNoteError: LocalizedError, Equatable {
    /// This Mac may not answer this figure's notes (the posture's
    /// `.acceptOrReject` or `.dispose` refused).
    case notPermitted
    /// No note with that id on this figure's stream.
    case unknownNote
    /// The writer deleted the note (RULING-22): an instruction with duration,
    /// so a stale row's Accept or Reject does nothing to it.
    case withdrawn
    /// Accept takes a suggested change anchored to one cell.
    case notACellSuggestion
    /// The suggestion is already accepted: its cell is written, and the way
    /// back is its accept's ⌘Z, never a second answer over it.
    case notOpen
    /// The suggestion's cell is gone — its row or column deleted (RULING-5):
    /// Maugham never guesses where an AI-proposed change belongs.
    case anchorOrphaned
    /// The cell no longer holds what it held when the suggestion was made.
    /// The surface asks, then accepts again with `confirmChanged: true`.
    case cellChangedSinceSuggestion
    /// Reopen answers a rejected, archived or stetted note, or an accepted
    /// one that wrote no cell — an accepted suggestion is taken back by
    /// undoing its accept, which puts the cell back.
    case cannotReopen
    /// A suggested change writes a cell, so it is accepted in the table, never
    /// by `acceptNote` (which writes no cell).
    case acceptInTheTable

    /// The clause a declined ⌘Z or ⇧⌘Z says after "—".
    var reason: String {
        switch self {
        case .notPermitted: "this Mac can no longer answer this figure's notes"
        case .unknownNote: "the note is no longer on this figure"
        case .withdrawn: "the note was deleted"
        case .notACellSuggestion: "the note doesn't suggest a change to one cell"
        case .notOpen: "the suggestion has already been accepted"
        case .anchorOrphaned: "the suggestion's cell has been deleted"
        case .cellChangedSinceSuggestion: "the cell has changed since the suggestion was made"
        case .cannotReopen: "the note can't be reopened"
        case .acceptInTheTable: "a suggested change is accepted in the table"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notPermitted: "This Mac may not answer notes on this figure, so the note was left as it was."
        case .unknownNote: "That note is no longer on this figure."
        case .withdrawn: "That note was deleted."
        case .notACellSuggestion: "That note doesn't suggest a change to one cell."
        case .notOpen: "That suggestion has already been accepted."
        case .anchorOrphaned: "The suggestion's cell has been deleted, so it can't be accepted."
        case .cellChangedSinceSuggestion: "The cell has changed since the suggestion was made."
        case .cannotReopen: "That note can't be reopened."
        case .acceptInTheTable: "A suggested change to a cell is accepted in the table."
        }
    }
}

// MARK: - The author answers a figure note (report plan 9c-1)
//
// A figure's notes ride its own stream (`DocumentStore.addFigureAnnotation`
// writes their creation). Every answer here is the author's, signed by this
// host's device, built by Core's `FigureAnnotationOps` and appended through
// `commitNoteOp` (minted after the newest op folded here). Each opens with
// its posture door — never `.editFigure` alone: Accept asks `.editFigure`
// (it writes the cell) and `.acceptOrReject`, Reject `.acceptOrReject`, and
// Stet, Archive and Reopen `.dispose` — then refuses in the manuscript
// accept's order: closed, parked, the permit, withdrawn (RULING-22), the
// anchor gone (RULING-5), the cell changed since. ⌘Z appends a compensating
// op (ADR 0023) and declines out loud when the note moved since.

extension FigureDocument {

    /// **The figure's notes as its stream says**, judged as the load judged
    /// them (`annotationAmendments`) and resolved against the table this host
    /// shows: every status, withdrawn notes left out.
    public func annotations() -> [Annotation] {
        AnnotationAggregation.allAnnotations(
            ops: _ops, paragraphs: [:], amendments: annotationAmendments, figureTable: state.table)
    }

    /// The note `id` as it stands, or why it cannot be answered: withdrawn
    /// (asked first — a withdrawn note is absent from the projection) or
    /// unknown.
    private func note(_ id: String) throws -> Annotation {
        if AnnotationDeriver.isWithdrawn(annotationId: id, in: _ops, amendments: annotationAmendments) {
            documentLog.error("figure \(self.figureId, privacy: .public): note \(id, privacy: .public) was withdrawn — refusing to answer a deleted note")
            throw FigureNoteError.withdrawn
        }
        guard let note = annotations().first(where: { $0.id == id }) else { throw FigureNoteError.unknownNote }
        return note
    }

    /// The note, refused only when it is an accepted SUGGESTION: its cell is
    /// written, so rejecting it would leave the table and the note
    /// disagreeing (its accept's ⌘Z is the way back). Reject's question; stet
    /// and archive take every status, as the manuscript's do (latest wins).
    private func notAnAcceptedSuggestion(_ id: String) throws -> Annotation {
        let note = try note(id)
        if note.status == .accepted, note.kind == .suggestedChange { throw FigureNoteError.notOpen }
        return note
    }

    /// The note's status now (nil when it is gone) — every undo's re-check.
    func noteStatus(_ id: String) -> AnnotationStatus? {
        annotations().first { $0.id == id }?.status
    }

    /// The figure's cached line and the window's cards are dropped, and the
    /// notes announced once for the figure.
    private func notesChanged() {
        documentStore?.figureCache.invalidate(figureId: figureId)
        documentStore?.invalidateFigureCards()
        MaughamEvent.postAnnotationsChanged(docId: figureId, projectURL: projectURL)
    }

    // MARK: - Accept

    /// **Accept a suggested change to one cell**: ONE `claudeAccept` that
    /// writes the suggested cell (`Op.figure`: `next` over the cell it
    /// replaces) and resolves the note, signed by this host's device — the
    /// author's — with the note's id as its `sourceAnnotationId`, while the
    /// suggester stays on the note's own creation line.
    ///
    /// Refuses, before anything is written: a closed host, a parked figure,
    /// a Mac that may not change the figure or answer its notes, a withdrawn
    /// note (RULING-22), a note that is not an open one-cell suggestion, a
    /// cell whose row or column is gone (RULING-5), and — unless
    /// `confirmChanged` — a cell that no longer holds what it held when the
    /// suggestion was made (`cellChangedSinceSuggestion`). A cell that already
    /// holds the suggestion has nothing to lose, and is not asked about.
    ///
    /// ⌘Z appends the `claudeAcceptRevert` that puts the cell back and
    /// reopens the note — one step, and inside an open grid visit the visit's
    /// own undo compensates both (`FigureVisit`); declined when the cell or
    /// the note moved since. ⇧⌘Z accepts again.
    public func acceptSuggestion(
        id: String, confirmChanged: Bool = false, undoManager: UndoManager? = nil
    ) async throws {
        try await requireWritable("acceptSuggestion")
        try await requireNoteDisposition("acceptSuggestion", .acceptOrReject)
        try requireTable()
        let note = try note(id)
        guard note.kind == .suggestedChange, let anchor = note.figureAnchor,
              (anchor.rowEnd ?? anchor.row) == anchor.row,
              (anchor.columnEnd ?? anchor.column) == anchor.column,
              let creation = _ops.first(where: { $0.opId == id })
        else { throw FigureNoteError.notACellSuggestion }
        guard note.status != .accepted else { throw FigureNoteError.notOpen }
        let key = CellKey(row: anchor.row, column: anchor.column)
        guard isLive(key) else {
            documentLog.error("figure \(self.figureId, privacy: .public): suggestion \(id, privacy: .public)'s cell is gone — refused (RULING-5)")
            throw FigureNoteError.anchorOrphaned
        }
        let replaced = state.table[key]
        // The suggested CONTENT over the cell's current format and alignment:
        // a format the author set since is kept, and a format-only change is
        // no change since the suggestion.
        let suggested = note.suggestedCell.map {
            Cell(content: $0.content, format: replaced?.format ?? $0.format,
                 alignment: replaced?.alignment ?? $0.alignment)
        }
        let content = replaced?.content
        if !confirmChanged, content != creation.figure?.prior?.content, content != suggested?.content {
            throw FigureNoteError.cellChangedSinceSuggestion
        }
        // A formula reading Research takes its pins as `setCell`'s does, in
        // the same ⌘Z; the read awaited, so the doors, the note and the cell
        // are asked again.
        var entryPins: [PinWrite] = []
        if let pins = await researchEntryPins(writing: suggested, at: key) {
            entryPins = pins
            try await requireWritable("acceptSuggestion")
            try await requireNoteDisposition("acceptSuggestion", .acceptOrReject)
            guard try self.note(id).status != .accepted else { throw FigureNoteError.notOpen }
            guard isLive(key), state.table[key] == replaced else {
                throw FigureEditInvalid(reason: "the cell changed while its Research sources were read")
            }
        }
        let op = try await commitNoteOp(
            FigureAnnotationOps.accept(
                annotationId: id, cell: key, next: suggested, prior: replaced, stamp: noteStamp),
            render: entryPins.isEmpty)
        let (pinOps, pinFailure) = await appendEntryPins(entryPins)
        let pinned = pinOps.compactMap { op in op.figure.flatMap { p in p.cell.flatMap { c in p.pin.map { (c, $0) } } } }
        registerFigureUndo(
            undoManager, actionName: "Accept Suggestion", forward: op, alongside: pinOps,
            stillAsWritten: { d in
                d.isLive(key) && d.state.table[key] == suggested && d.noteStatus(id) == .accepted
                    && pinned.allSatisfy { d.state.pins[$0.0]?.contains($0.1) == true }
            },
            redo: { [weak undoManager] d in
                guard d.isLive(key), d.state.table[key] == replaced, d.noteStatus(id) != .accepted else {
                    return d.decline(.drifted)
                }
                await d.redoing {
                    try await d.acceptSuggestion(id: id, confirmChanged: true, undoManager: undoManager)
                }
            })
        notesChanged()
        if let pinFailure { throw pinFailure }
    }

    // MARK: - A note that writes no cell

    /// **Accept a note that writes no cell** — a comment's *Got it*, a craft
    /// note's Accept, a query's Reply (`userResponse` keeps the writer's
    /// words). One status-only `claudeAccept`, the author's, behind
    /// `requireNoteDisposition` (`.acceptOrReject`, as the manuscript's
    /// accept of a textless note). A suggested change is refused
    /// (`acceptInTheTable`): it writes a cell, so it is accepted by
    /// `acceptSuggestion`, in the grid. Answers follow answers, as the
    /// manuscript's do (latest wins). ⌘Z reopens the note and puts back the
    /// answer it displaced; ⇧⌘Z accepts again.
    public func acceptNote(id: String, userResponse: String? = nil, undoManager: UndoManager? = nil) async throws {
        try await requireNoteDisposition("acceptNote", .acceptOrReject)
        let prior = try note(id)
        guard prior.kind != .suggestedChange else { throw FigureNoteError.acceptInTheTable }
        try await commitNoteOp(
            FigureAnnotationOps.statusOnlyAccept(annotationId: id, userResponse: userResponse, stamp: noteStamp),
            render: false)
        notesChanged()
        let priorStatus = prior.status, priorReason = prior.userResponse
        OpUndoRegistrar.register(
            undoManager, actionName: "Accept Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { d in
                guard d.noteStatus(id) == .accepted else { return d.decline(.drifted) }
                var reopened = false
                await d.redoing {
                    try await d.unacceptNote(id: id)
                    reopened = true
                }
                guard reopened, priorStatus != .open else { return }
                do {
                    try await d.settle(id, as: priorStatus, reason: priorReason, undoManager: nil)
                } catch {
                    documentLog.error("figure \(d.figureId, privacy: .public): note \(id, privacy: .public) reopened but its earlier answer was not put back: \(error.localizedDescription, privacy: .public)")
                    d.decline(.notePutBack)
                }
            },
            redo: { [weak undoManager] d in
                await d.redoing { try await d.acceptNote(id: id, userResponse: userResponse, undoManager: undoManager) }
            })
    }

    /// **`acceptNote`'s ⌘Z**: a status-only `claudeAcceptRevert`, the note
    /// open again and no cell moved. Never over a suggestion (its accept's
    /// revert puts the cell back, `FigureInverse`).
    private func unacceptNote(id: String) async throws {
        try await requireNoteDisposition("unacceptNote", .acceptOrReject)
        let note = try note(id)
        guard note.kind != .suggestedChange else { throw FigureNoteError.acceptInTheTable }
        try await commitNoteOp(FigureAnnotationOps.statusOnlyRevert(annotationId: id, stamp: noteStamp), render: false)
        notesChanged()
    }

    // MARK: - Reject, stet, archive

    /// **Reject a note**, keeping `reason` as its reply (RULING-31: a
    /// reopened note keeps it as history). No cell moves. Refused over an
    /// accepted suggestion (`notOpen`). ⌘Z puts back what it displaced.
    public func rejectAnnotation(id: String, reason: String? = nil, undoManager: UndoManager? = nil) async throws {
        try await requireNoteDisposition("rejectAnnotation", .acceptOrReject)
        let prior = try notAnAcceptedSuggestion(id)
        try await commitNoteOp(FigureAnnotationOps.reject(annotationId: id, reason: reason, stamp: noteStamp), render: false)
        notesChanged()
        registerSettlingUndo(
            undoManager, actionName: "Reject Annotation", id: id, settled: .rejected, reason: reason,
            prior: prior.status, priorReason: prior.userResponse)
    }

    /// **Stet a note**: read, considered, and the table stands — over a
    /// resolution too, as the manuscript's. ⌘Z puts back what it displaced.
    public func stetAnnotation(id: String, undoManager: UndoManager? = nil) async throws {
        try await requireNoteDisposition("stetAnnotation", .dispose)
        let prior = try note(id)
        try await commitNoteOp(FigureAnnotationOps.stet(annotationId: id, stamp: noteStamp), render: false)
        notesChanged()
        registerSettlingUndo(
            undoManager, actionName: "Stet Annotation", id: id, settled: .stetted,
            prior: prior.status, priorReason: prior.userResponse)
    }

    /// **Archive a note**: set aside — over a resolution too. ⌘Z puts back
    /// what it displaced.
    public func archiveAnnotation(id: String, undoManager: UndoManager? = nil) async throws {
        try await requireNoteDisposition("archiveAnnotation", .dispose)
        let prior = try note(id)
        try await commitNoteOp(FigureAnnotationOps.archive(annotationId: id, stamp: noteStamp), render: false)
        notesChanged()
        registerSettlingUndo(
            undoManager, actionName: "Archive Annotation", id: id, settled: .archived,
            prior: prior.status, priorReason: prior.userResponse)
    }

    /// Reject's, stet's and archive's ⌘Z — ONE decision undone (the
    /// manuscript stet's #41 A2 obligation, for all three): while the note
    /// still shows what this action left (else decline out loud, RULING-22),
    /// reopen it, then put back the resolution it displaced (`prior`, a
    /// rejection with its reason, an accept status only). ⇧⌘Z settles it
    /// again (`settle`) with the live undo manager.
    private func registerSettlingUndo(
        _ undoManager: UndoManager?, actionName: String, id: String, settled: AnnotationStatus,
        reason: String? = nil, prior: AnnotationStatus, priorReason: String?
    ) {
        OpUndoRegistrar.register(
            undoManager, actionName: actionName, target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { d in
                guard d.noteStatus(id) == settled else { return d.decline(.drifted) }
                var reopened = false
                await d.redoing {
                    try await d.reopenAnnotation(id: id)
                    reopened = true
                }
                guard reopened, prior != .open else { return }
                // The reopen landed: a put-back that fails now leaves the note
                // open, and says THAT (the manuscript's `.stetRestore`), never
                // a refusal it was not.
                do {
                    try await d.settle(id, as: prior, reason: priorReason, undoManager: nil)
                } catch {
                    documentLog.error("figure \(d.figureId, privacy: .public): note \(id, privacy: .public) reopened but its earlier answer was not put back: \(error.localizedDescription, privacy: .public)")
                    d.decline(.notePutBack)
                }
            },
            redo: { [weak undoManager] d in
                await d.redoing { try await d.settle(id, as: settled, reason: reason, undoManager: undoManager) }
            })
    }

    /// Settle the note `id` as `status` again — a ⇧⌘Z, or Reopen's ⌘Z.
    private func settle(
        _ id: String, as status: AnnotationStatus, reason: String?, undoManager: UndoManager?
    ) async throws {
        switch status {
        case .rejected: try await rejectAnnotation(id: id, reason: reason, undoManager: undoManager)
        case .archived: try await archiveAnnotation(id: id, undoManager: undoManager)
        case .stetted: try await stetAnnotation(id: id, undoManager: undoManager)
        case .accepted: try await reacceptAnnotation(id: id, userResponse: reason)
        case .open: throw FigureNoteError.cannotReopen
        }
    }

    /// **The note back to accepted, status only** — what a stet's or
    /// archive's ⌘Z puts back over an accepted note, whose cell was never
    /// taken back (`FigureAnnotationOps.statusOnlyAccept`; writes no cell),
    /// and a reply's ⌘Z over an earlier reply: `userResponse` is the answer
    /// it displaced, kept.
    private func reacceptAnnotation(id: String, userResponse: String? = nil) async throws {
        try await requireNoteDisposition("reacceptAnnotation", .acceptOrReject)
        _ = try note(id)
        try await commitNoteOp(
            FigureAnnotationOps.statusOnlyAccept(annotationId: id, userResponse: userResponse, stamp: noteStamp),
            render: false)
        notesChanged()
    }

    // MARK: - Reopen

    /// **Reopen a rejected, archived or stetted note — or an accepted note
    /// that wrote no cell** (a *Got it*, a Reply; Task 7), by a status-only
    /// revert, as the manuscript reopens a textless accept. An accepted
    /// suggestion is not reopened here — its accept's ⌘Z puts the cell back
    /// as it reopens. ⌘Z settles the note again as it was (a rejection or a
    /// reply with its words), while it is still open.
    public func reopenAnnotation(id: String, undoManager: UndoManager? = nil) async throws {
        try await requireNoteDisposition("reopenAnnotation", .dispose)
        let note = try note(id)
        let prior = note.status, priorReason = note.userResponse
        let built: Op
        do {
            built = try FigureAnnotationOps.reopen(for: note, docId: figureId, stamp: noteStamp)
        } catch {
            throw FigureNoteError.cannotReopen
        }
        try await commitNoteOp(built, render: false)
        notesChanged()
        OpUndoRegistrar.register(
            undoManager, actionName: "Reopen Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { d in
                guard d.noteStatus(id) == .open else { return d.decline(.drifted) }
                await d.redoing { try await d.settle(id, as: prior, reason: priorReason, undoManager: nil) }
            },
            redo: { [weak undoManager] d in
                await d.redoing { try await d.reopenAnnotation(id: id, undoManager: undoManager) }
            })
    }
}
