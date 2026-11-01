import Foundation
import MaughamCore

/// The rewind confirm sheet's and after-toast's single source of numbers.
///
/// RULING-28: the collateral report has two halves — the confirmation states
/// the FULL set of collateral changes before the writer commits, and the
/// post-restore report confirms what actually happened. Naming one class and
/// omitting another is worse than naming none, so `preview` mirrors every
/// class `Document.restoreToOp` acts on (the step-7 sweep, the step-8
/// stranded-accept resolution, the step-9 return journey) and `toast` renders
/// the result those steps produced. `changesAnything` is RULING-37's view
/// half: Restore is not offered when there is nothing to do. Pure — computed
/// from the modal's op snapshot, no I/O.
enum RewindImpact {

    struct Preview: Equatable {
        var wordsUndone: Int
        var paragraphsRemoved: Int
        /// Open annotations anchored to paragraphs the rewind removes — the
        /// step-7 sweep's mirror — plus accepts stranded on them (step 8).
        var annotationsToArchive: Int
        /// Sweep-archived annotations whose paragraph exists at the cursor —
        /// the step-9 reopen arm's mirror (RULING-25).
        var annotationsToReopen: Int
        /// Accepted suggestions whose accept lies past the cursor on a
        /// surviving paragraph — the step-8 revert mirror.
        var acceptsToReopen: Int
        /// Archived-from-accepted suggestions whose paragraph and accept both
        /// sit at-or-before the cursor — the step-9 accepted arm's mirror
        /// (RULING-26).
        var acceptsToRestore: Int
        var changesAnything: Bool
    }

    private static let taskKinds: Set<OpKind> = [
        .taskCreate, .taskStatusChange, .taskPriorityChange,
        .taskParentChange, .taskBodyEdit, .taskArchive
    ]

    /// `amendments` is the document's own judgement (`Document
    /// .annotationAmendments`), so the preview reads the statuses the pane
    /// shows and skips a reopen the deriver does not honour (ruling P). A
    /// closed piece passes the table a load would build
    /// (`Document.closedPieceHistory`, P3 plan 3 Task 5); the default is for
    /// callers with no book behind them.
    static func preview(
        ops: [Op], cursorOpId: String?,
        amendments: AnnotationAmendments = .honourEverything
    ) -> Preview {
        var p = Preview(wordsUndone: 0, paragraphsRemoved: 0,
                        annotationsToArchive: 0, annotationsToReopen: 0,
                        acceptsToReopen: 0, acceptsToRestore: 0,
                        changesAnything: false)
        guard let cursorOpId else { return p }
        let now = Deriver.deriveWithSequenceFallback(ops: ops)
        let target = Deriver.derive(ops: ops, upTo: .atOp(opId: cursorOpId, at: Date()))
        let nowSet = Set(now.sequence)
        let targetSet = Set(target.sequence)
        let removed = nowSet.subtracting(targetSet)

        p.paragraphsRemoved = removed.count
        p.wordsUndone = removed.compactMap { now.paragraphs[$0] }
            .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
            .reduce(0, +)

        let annotations = AnnotationDeriver.derive(
            ops: ops, paragraphs: now.paragraphs, amendments: amendments)
        var lifecycleBySource: [String: [Op]] = [:]
        // The deriver's own lifecycle rule, asked for rather than restated —
        // this set and `restoreToOp`'s each carried a literal copy until M3 P2,
        // and a stet missing from one of them reads a settled note's history as
        // if the settlement had never happened.
        // Honoured ops only (ruling P) — `restoreToOp`'s own filter.
        for op in ops where AnnotationDeriver.isHonouredLifecycleOp(op, amendments: amendments) {
            if let src = op.provenance?.sourceAnnotationId {
                lifecycleBySource[src, default: []].append(op)
            }
        }

        for ann in annotations {
            guard let pid = ann.paragraphId else { continue }
            switch ann.status {
            case .open:
                if ann.kind != .craftNote, removed.contains(pid) {
                    p.annotationsToArchive += 1
                }
            case .archived:
                guard targetSet.contains(pid) else { break }
                let lifecycle = (lifecycleBySource[ann.id] ?? []).sorted { $0.opId < $1.opId }
                guard let last = lifecycle.last, last.kind == .claudeArchive,
                      last.provenance?.synthesisSource == .rewind else { break }
                let before = lifecycle.dropLast().last
                let wasOpen = before == nil
                    || before?.kind == .claudeAcceptRevert
                    || before?.kind == .annotationReopen
                if wasOpen {
                    p.annotationsToReopen += 1
                } else if before?.kind == .claudeAccept,
                          let textAccept = lifecycle.last(where: {
                              $0.kind == .claudeAccept && !$0.changes.isEmpty }) {
                    if cursorOpId >= textAccept.opId {
                        p.acceptsToRestore += 1
                    } else {
                        // Step 9's else-arm: a target before the accept
                        // reopens to .open — the class the branch review
                        // caught this preview omitting.
                        p.annotationsToReopen += 1
                    }
                }
            case .accepted:
                break   // step 8's mirror, below: `strandedAccepts`
            case .rejected, .stetted:
                // Neither moved any text, so a restore past one restores no
                // text either, and neither is a class the rewind reopens: the
                // return journey (step 9) acts on notes MAUGHAM archived
                // during a rewind, not on resolutions the writer made. A stet
                // still has to be in `lifecycleOpKinds` above, because it is
                // part of the HISTORY the archived arm reads. (Task 2's
                // answer to the question Task 1 left in this arm.)
                break
            }
        }

        // Step 8's mirror, asked of the rule step 8 itself runs. A surviving
        // paragraph's accept is reverted; a removed one's is archived, which
        // the toast counts with the sweep's archives. A deleted note is not
        // promised, as step 8 does not report it.
        for stranded in strandedAccepts(in: ops, pastTarget: cursorOpId, amendments: amendments)
        where !stranded.isWithdrawn {
            if targetSet.contains(stranded.paragraphId) {
                p.acceptsToReopen += 1
            } else {
                p.annotationsToArchive += 1
            }
        }

        let textChanges = now.paragraphs != target.paragraphs
            || now.sequence != target.sequence
        let cursorIdx = ops.firstIndex { $0.opId == cursorOpId }
        let taskOpsAfter = cursorIdx.map { idx in
            ops.dropFirst(idx + 1).contains { taskKinds.contains($0.kind) }
        } ?? false
        p.changesAnything = textChanges || taskOpsAfter
        return p
    }

    /// An accepted suggestion a return to the target strands.
    struct StrandedAccept: Equatable {
        let annotationId: String
        /// The paragraph its newest changes-carrying accept wrote.
        let paragraphId: String
        /// Deleted by the writer: still resolved in the log, never counted.
        let isWithdrawn: Bool
    }

    /// **The accepts a return to `targetOpId` strands** (RULING-28): each note
    /// whose latest HONOURED lifecycle op is an accept, and whose newest
    /// changes-carrying accept lies past the target. The latest op is asked
    /// of the deriver's own rule (`AnnotationDeriver.isHonouredLifecycleOp`),
    /// so a Stet, reject, archive or reopen the writer put over the accept is
    /// their answer and stands — the walk once hand-listed four kinds without
    /// Stet and reopen, and reverted a Stet over an accept (#128 item 3).
    ///
    /// The latest op may be ANY accept — changes-carrying or STATUS-ONLY. A
    /// status-only accept is a re-accept (the rewind-undo's `.undoRewind`, a
    /// put-back ⌘Z) standing in for the text-applying accept it re-instated,
    /// so strandedness is judged against the newest CHANGES-CARRYING accept;
    /// otherwise a rewind after an undo would disagree with a fresh one
    /// (M4-RW-031). Sorted by annotation id. `restoreToOp`'s step 8 acts on
    /// this list and `preview` counts it, so the two cannot disagree.
    static func strandedAccepts(
        in ops: [Op], pastTarget targetOpId: String,
        amendments: AnnotationAmendments
    ) -> [StrandedAccept] {
        // One walk: per note, the latest honoured lifecycle op and the newest
        // changes-carrying accept. The preview runs this on every cursor
        // scrub (`RewindWindow`), so it stays O(ops), not O(notes × ops).
        var latest: [String: Op] = [:]
        var textAccept: [String: Op] = [:]
        for op in ops {
            guard let src = op.provenance?.sourceAnnotationId else { continue }
            if op.kind == .claudeAccept, !op.changes.isEmpty,
               textAccept[src].map({ op.opId > $0.opId }) ?? true {
                textAccept[src] = op
            }
            if AnnotationDeriver.isHonouredLifecycleOp(op, amendments: amendments),
               latest[src].map({ $0.opId <= op.opId }) ?? true {
                latest[src] = op
            }
        }
        let stranded = latest.keys.sorted().compactMap { src -> (String, String)? in
            guard latest[src]?.kind == .claudeAccept,
                  let accept = textAccept[src],
                  accept.opId > targetOpId,          // past the target (ULID order)
                  let pid = accept.changes.first?.paragraphId
            else { return nil }
            return (src, pid)
        }
        guard !stranded.isEmpty else { return [] }
        // The deriver's withdrawn walk, once for the whole log.
        let withdrawn = Set(AnnotationDeriver.deriveWithdrawn(
            ops: ops, amendments: amendments).map(\.id))
        return stranded.map {
            StrandedAccept(annotationId: $0.0, paragraphId: $0.1,
                           isWithdrawn: withdrawn.contains($0.0))
        }
    }

    /// The confirm-sheet sentence: every non-zero class named, zero classes
    /// omitted entirely.
    static func confirmSummary(_ p: Preview) -> String {
        var parts: [String] = []
        parts.append("Restoring would undo \(p.wordsUndone) words / "
                     + "\(p.paragraphsRemoved) paragraph\(p.paragraphsRemoved == 1 ? "" : "s") "
                     + "written after this point.")
        if p.annotationsToArchive > 0 {
            parts.append("\(p.annotationsToArchive) note\(p.annotationsToArchive == 1 ? "" : "s") will be archived.")
        }
        if p.annotationsToReopen > 0 {
            parts.append("\(p.annotationsToReopen) note\(p.annotationsToReopen == 1 ? "" : "s") will be reopened.")
        }
        if p.acceptsToReopen > 0 {
            parts.append("\(p.acceptsToReopen) accepted suggestion\(p.acceptsToReopen == 1 ? "" : "s") reopened.")
        }
        if p.acceptsToRestore > 0 {
            parts.append("\(p.acceptsToRestore) suggestion\(p.acceptsToRestore == 1 ? "" : "s") restored to accepted.")
        }
        return parts.joined(separator: " ")
    }

    /// The after-toast: what the restore actually did, or nil when a genuine
    /// no-op left nothing worth saying. A `.nearest` resolution is ALWAYS
    /// worth saying (RULING-27: the substitution is named), even when the
    /// nearest moment turned out to be the present.
    static func toast(for r: RewindRestoreResult) -> String? {
        var parts: [String] = []
        if case .nearest = r.targetResolution {
            parts.append("That exact moment is gone — restored to the nearest surviving one.")
        }
        if r.restoreOp != nil || !parts.isEmpty {
            var body = "Restored."
            let archived = r.archivedAnnotationOpIds.count
            let reopened = r.travelReopenedAnnotationIds.count
            let reaccepted = r.travelReacceptedAnnotationIds.count
            let acceptsReopened = r.reopenedAnnotationOpIds.count
            if archived > 0 { body += " \(archived) note\(archived == 1 ? "" : "s") auto-archived." }
            if reopened > 0 { body += " \(reopened) note\(reopened == 1 ? "" : "s") reopened." }
            if acceptsReopened > 0 { body += " \(acceptsReopened) accepted suggestion\(acceptsReopened == 1 ? "" : "s") reopened." }
            if reaccepted > 0 { body += " \(reaccepted) suggestion\(reaccepted == 1 ? "" : "s") restored to accepted." }
            parts.append(body)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
