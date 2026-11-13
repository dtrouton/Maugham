import Foundation
import MaughamCore

// MARK: - Checkpoint restore (report plan 6c Task 2, rulings Q-1, Q-2)

/// **A figure's checkpoint restore**, owned by its `FigureDocument` and run
/// through `FigureDocument.restoreToCheckpoint` (hardening 11-11 Task 1: the
/// restore split out of the host, no behaviour change). It reaches the host
/// only through the host's own verbs — the door (`requireWritable`,
/// `mayHere`), `commit`, the open-cell-note hold, `reloadGeneration`, the
/// figure as it stands (`state`, `_ops`, `annotationAmendments`), and the
/// picture verbs it shares with a return (`placeReturningPicture`,
/// `imageUndoFolder`, `sameImageFormat`) — and leaves the note walk to
/// Core's `FigureRestoreNotePlan`.
@MainActor
final class FigureCheckpointRestore {

    /// The figure this restore winds back. It owns this restore.
    private unowned let host: FigureDocument

    init(host: FigureDocument) { self.host = host }

    /// **The notes the last `run` answered** (RULING-28's AFTER half,
    /// RULING-57): the accepted suggestions it reopened (cell and note put
    /// back together), those it put back to accepted (their accepted value
    /// written back, cell and note together) and those it archived (their
    /// cell is gone then), by id — what the restore sheet names beside its
    /// outcome. Emptied as `run` begins (a run that skips, refuses or throws
    /// answered none) and filled as each op lands, so after a part-way stop
    /// it names only what landed.
    private(set) var lastNotes = FigureRestoreNotes()

    /// Test seam: runs in `run` between one landed op and the next — where
    /// another device's reload is put. Nil in production.
    static var betweenOpsForTesting: (@MainActor (FigureDocument) async -> Void)?

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
    /// - **A restore changes a suggestion only where it rewrites that
    ///   suggestion's cell** (RULING-28, RULING-57, ruling R-A): the notes it
    ///   answers are `FigureRestoreNotePlan`'s three classes — stranded
    ///   (reverted), returning (accepted again), gone (archived).
    /// - **It stops part way rather than write against a fold that moved**:
    ///   another device's lines read in meanwhile (a `reload`) stop it before
    ///   the next op, and an op that will not write stops it too; either way
    ///   what landed stays and the answer is `.partlyRestored` with the count.
    ///   **Restoring again is safe**: the diff is worked out afresh from the
    ///   figure as it then stands, so it does only what is left. An op that
    ///   fails before any landed throws.
    /// - Not registered for ⌘Z (ruling Q-2), like the text's partial restore.
    func run(
        _ checkpointId: String, through pointer: String,
        pictureHashes: FigurePictureHashes
    ) async throws -> FigureRestoreOutcome {
        // First, before anything can skip, refuse or throw: the report is
        // this run's, never an earlier restore's (final review F3).
        lastNotes = FigureRestoreNotes()
        let prepared: Prepared
        let preparation: Preparation
        do {
            preparation = try await prepare(through: pointer, pictureHashes: pictureHashes)
        } catch is NotesRefused {
            // Logged here, not in `prepare`: the sheet's count runs the same
            // preparation and attempts nothing.
            documentLog.error(
                "restoreToCheckpoint refused on \(self.host.figureId, privacy: .public): it would answer a note this device may not answer")
            throw FigureEditRefused(site: "restoreToCheckpoint")
        }
        switch preparation {
        case .skipped(let outcome): return outcome
        case .ready(let ready): prepared = ready
        }
        let plan = prepared.plan
        let restoreChanges = plan.changes
        let noteLines = plan.statusLines
        let pictureChange = prepared.pictureChange
        let picture = prepared.picture
        let restoresPicture = pictureChange != nil && pictureChange?.contentHash == picture?.hash
        let reason = Op.Provenance(sourceCheckpoint: checkpointId)
        // Every change was worked out against this fold: a reload replaces it.
        let generation = host.reloadGeneration
        var appended = 0
        var stop: FigureRestoreOutcome.Stop?
        host.holdOpenCellNotes()
        defer { host.releaseOpenCellNotes() }
        do {
            for change in restoreChanges {
                if appended > 0, let hook = Self.betweenOpsForTesting { await hook(host) }
                guard host.reloadGeneration == generation else { stop = .changedElsewhere; break }
                let provenance = change.sourceAnnotationId.map {
                    FigureAnnotationOps.lifecycleProvenance(
                        annotationId: $0, sourceCheckpoint: checkpointId, stamp: host.noteStamp)
                } ?? reason
                try await host.commit(change.kind, change.payload, provenance: provenance, render: false)
                appended += 1
                if let id = change.sourceAnnotationId {
                    if change.kind == .claudeAccept { lastNotes.reaccepted.append(id) } else { lastNotes.reopened.append(id) }
                }
            }
            // A note no cell change carries, status only: a returning one on
            // a revived cell accepted again, a stranded one reverted (its
            // cell written for another note, or revived) or archived (its
            // cell is gone then).
            for line in noteLines where stop == nil {
                guard host.reloadGeneration == generation else { stop = .changedElsewhere; break }
                try await host.commit(line.kind, nil, provenance: FigureAnnotationOps.lifecycleProvenance(
                    annotationId: line.annotationId, sourceCheckpoint: checkpointId, stamp: host.noteStamp),
                    render: false)
                appended += 1
                switch line.kind {
                case .claudeArchive: lastNotes.archived.append(line.annotationId)
                case .claudeAccept: lastNotes.reaccepted.append(line.annotationId)
                default: lastNotes.reopened.append(line.annotationId)
                }
            }
            if stop == nil, restoresPicture, let picture {
                if appended > 0, let hook = Self.betweenOpsForTesting { await hook(host) }
                if host.reloadGeneration != generation {
                    stop = .changedElsewhere
                } else {
                    let (payload, putBack) = try await host.placeReturningPicture(picture)
                    do {
                        try await host.commit(.figureImageSet, payload, provenance: reason, render: false)
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
        if appended > 0 { await host.documentStore?.figureHostAppended(host.figureId) }
        if plan.answersANote, appended > 0 {
            MaughamEvent.postAnnotationsChanged(docId: host.figureId, projectURL: host.projectURL)
        }
        if let stop { return .partlyRestored(opCount: appended, why: stop) }
        if let pictureChange, !restoresPicture {
            return .skippedPicture(hash: pictureChange.contentHash, opCount: appended)
        }
        return appended == 0 ? .unchanged : .restored(opCount: appended)
    }

    /// **What `run` would do to this figure's notes, writing nothing**
    /// (RULING-28's BEFORE half, #136 W3): the same preparation `run` makes
    /// — the door, the two skips, the park reads, the diff, every change
    /// checked to apply, both note answers, `FigureRestoreNotePlan` — and
    /// its plan's notes. Nil where `run` would skip the figure
    /// (`.skippedParked`, `.skippedWentToResearch`), refuse it
    /// (`FigureEditRefused`, the door's or a note's) or throw before its
    /// first op. No op, no event, and `lastNotes` is left as it was. It is
    /// what a WHOLE restore would answer; a restore stopped part way
    /// answers less (`lastNotes`).
    func notesPreview(through pointer: String) async -> FigureRestoreNotes? {
        guard case .ready(let prepared)? = try? await prepare(through: pointer, pictureHashes: nil)
        else { return nil }
        return prepared.plan.notes
    }

    /// Everything `run` works out before its first op.
    private struct Prepared {
        /// The table changes with the notes they answer, and the status-only
        /// note lines (`FigureRestoreNotePlan`).
        let plan: FigureRestoreNotePlan
        /// The checkpoint's picture, where the diff puts one back.
        let pictureChange: FigureImageRef?
        /// A file holding its bytes, when one was looked for and found.
        let picture: (url: URL, hash: String)?
    }

    /// `prepare`'s refusal of a plan that answers a note this hand may not
    /// answer, unlogged: `run` logs it and throws `FigureEditRefused`; the
    /// preview answers nil.
    private struct NotesRefused: Error {}

    private enum Preparation {
        /// The restore leaves this figure as it is, appending nothing.
        case skipped(FigureRestoreOutcome)
        case ready(Prepared)
    }

    /// **The one preparation `run` and `notesPreview` share**: the door
    /// (`.editFigure`, through `requireWritable`) and the two skips, the pin
    /// sources' park reads, the door and the skips again once the reads are
    /// awaited, the diff, `everyChangeApplies`, both note answers (`mayHere`)
    /// and the note plan; a plan that answers a note this hand may not
    /// answer is refused here (`NotesRefused`). Writes nothing, and logs
    /// nothing of its own. With `pictureHashes` the
    /// checkpoint's picture is looked for among the kept bytes, between the
    /// two door asks; without (the preview) it is not looked for.
    private func prepare(
        through pointer: String, pictureHashes: FigurePictureHashes?
    ) async throws -> Preparation {
        do { try await host.requireWritable("restoreToCheckpoint") } catch is FigureParkedRefused { return .skipped(.skippedParked) }
        if FigureRestoreDiff.wentToResearch(since: pointer, in: host._ops) { return .skipped(.skippedWentToResearch) }
        let first = FigureRestoreDiff.target(of: host._ops, through: pointer)
        let parks = try await currentParks(reading: first)
        var picture: (url: URL, hash: String)?
        if let pictureHashes {
            let wanted = first.image.flatMap { $0.contentHash == host.state.image?.contentHash ? nil : $0 }
            picture = await keptPicture(wanted, hashes: pictureHashes)
        }
        // The note lines a restore may write answer a note, so each asks the
        // verb it IS (final review M2): a revert that reopens one, or an
        // accept that returns one, asks `.acceptOrReject` (as
        // `appendCompensation` does), an archive
        // `.dispose`. Asked before the door's last await, so nothing lands
        // between the answer and the writes.
        let mayAnswerNotes = await host.mayHere(.acceptOrReject)
        let mayDisposeNotes = await host.mayHere(.dispose)
        // The reads awaited: the door is asked again before anything is written.
        do { try await host.requireWritable("restoreToCheckpoint") } catch is FigureParkedRefused { return .skipped(.skippedParked) }
        if FigureRestoreDiff.wentToResearch(since: pointer, in: host._ops) { return .skipped(.skippedWentToResearch) }
        let target = FigureRestoreDiff.target(of: host._ops, through: pointer)

        let changes = FigureRestoreDiff.changes(from: host.state, to: target, parks: parks)
        let tableChanges = changes.filter { $0.kind != .figureImageSet }
        guard FigureReturnDiff.everyChangeApplies(tableChanges, onto: host.state) else {
            throw FigureEditInvalid(reason: "the checkpoint's changes don't fit the figure")
        }
        // Where this hand may not dispose of a note, a stranded accept whose
        // cell is gone is reopened instead of archived (status only): open
        // over a deleted cell is honest, and the author can archive it.
        let plan = FigureRestoreNotePlan.plan(
            changes: tableChanges, ops: host._ops, amendments: host.annotationAmendments,
            table: host.state.table, target: target, above: pointer, mayDispose: mayDisposeNotes)
        if !mayAnswerNotes, plan.answersANote { throw NotesRefused() }
        return .ready(Prepared(
            plan: plan,
            pictureChange: changes.first { $0.kind == .figureImageSet }?.payload.image,
            picture: picture))
    }

    /// The current park cycle of each figure this figure's pins name, now or
    /// in `target` — whether or not a formula reads it
    /// (`DocumentStore.parkCycles`, one assembly). Empty with no window, or
    /// when neither holds a pin. Throws when the registry will not read:
    /// nothing has been written yet.
    private func currentParks(reading target: FigureState) async throws -> [String: String] {
        let sources = Set([host.state.pins, target.pins].flatMap { $0.values.joined() }.map(\.research))
        guard let documentStore = host.documentStore, !sources.isEmpty else { return [:] }
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
        guard let wanted, host.state.kind == .image, let current = host.state.image, host.documentStore != nil
        else { return nil }
        let ext = (current.filename as NSString).pathExtension.lowercased()
        let fm = FileManager.default
        if let imageUndoFolder = host.imageUndoFolder,
           let kept = try? fm.contentsOfDirectory(at: imageUndoFolder, includingPropertiesForKeys: nil)
            .first(where: { $0.deletingPathExtension().lastPathComponent == wanted.contentHash
                && FigureDocument.sameImageFormat($0.pathExtension.lowercased(), ext) }) {
            return (kept, wanted.contentHash)
        }
        let folder = host.projectURL.appendingPathComponent(ProjectStore.figuresFolder, isDirectory: true) // local-path: the app's own folder name
        let candidates = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !DotfileScan.isDotfile($0) && FigureDocument.sameImageFormat($0.pathExtension.lowercased(), ext) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let found = await hashes.first(in: candidates, matching: wanted.contentHash)
        return found.map { ($0, wanted.contentHash) }
    }
}
