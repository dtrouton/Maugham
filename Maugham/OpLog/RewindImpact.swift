import Foundation
import MaughamCore

/// The rewind confirm sheet's and after-toast's single source of numbers.
///
/// RULING-28: the collateral report has two halves — the confirmation states
/// the FULL set of collateral changes before the writer commits, and the
/// post-restore report confirms what actually happened. Naming one class and
/// omitting another is worse than naming none, so `preview` mirrors every
/// class `Document.restoreToOp` acts on (the step-7 sweep, the step-8
/// stranded-accept resolution and its returning sibling, the step-9 return
/// journey) and `toast` renders
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
        /// (RULING-26) — plus reverted accepts whose text the return writes
        /// back (`returningAccepts`, RULING-57).
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
        let travel = travelStatusChanges(in: ops, target: cursorOpId, amendments: amendments)
        for stranded in strandedAccepts(travel) where !stranded.isWithdrawn {
            if targetSet.contains(stranded.paragraphId) {
                p.acceptsToReopen += 1
            } else {
                p.annotationsToArchive += 1
            }
        }

        // Step 8's sibling, asked of the rule it runs: a suggestion whose
        // accepted text this return writes back returns to accepted, named
        // with the return journey's re-accepts as the toast names them.
        p.acceptsToRestore += returningAccepts(
            travel, writing: paragraphsWritten(from: now, to: target))
            .filter { !$0.isWithdrawn }.count

        let textChanges = now.paragraphs != target.paragraphs
            || now.sequence != target.sequence
        let cursorIdx = ops.firstIndex { $0.opId == cursorOpId }
        let taskOpsAfter = cursorIdx.map { idx in
            ops.dropFirst(idx + 1).contains { taskKinds.contains($0.kind) }
        } ?? false
        p.changesAnything = textChanges || taskOpsAfter
        return p
    }

    /// **A suggestion whose status a return to a moment contradicts** — the
    /// note's status now against its status at the target, for the one thing
    /// travel changes underneath it: whether its accepted change is in the
    /// text. Two classes, one walk (`travelStatusChanges`):
    ///
    /// - `.stranded` — accepted now, its change applied past the target, so
    ///   the return takes the text out (step 8; RULING-28, #128 item 3).
    /// - `.returning` — open now, accepted at the target with its change
    ///   applied, the change since taken out by a revert (the writer's
    ///   Revert, RULING-57; a travel's own status-only revert or return-
    ///   journey reopen, RULING-26), so a return that writes its paragraph
    ///   puts the text back and the note returns to accepted.
    struct TravelStatusChange: Equatable {
        enum Class: Equatable { case stranded, returning }
        let annotationId: String
        let `class`: Class
        /// `.stranded`: the paragraph its newest changes-carrying accept
        /// wrote. `.returning`: the paragraph of the accept the target held.
        let paragraphId: String
        /// `.returning`: that accept's reply, which the re-accept carries.
        let userResponse: String?
        /// Deleted by the writer: still answered in the log, never counted.
        let isWithdrawn: Bool
    }

    /// **The notes a return to `targetOpId` answers.** Per note, one walk
    /// finds the latest HONOURED lifecycle op (`AnnotationDeriver
    /// .isHonouredLifecycleOp`, so a Stet, reject, archive or reopen the
    /// writer put over an accept is their answer and stands — #128 item 3),
    /// the same at the target, and the newest changes-carrying accept overall
    /// and at the target.
    ///
    /// Stranded: the latest op is ANY accept — a status-only re-accept (the
    /// rewind-undo's, a put-back ⌘Z) stands in for the text-applying accept
    /// it re-instated, so strandedness is judged against the newest
    /// CHANGES-CARRYING accept (M4-RW-031) — and that accept is past the
    /// target, and the note was NOT accepted with its text at the target
    /// (accept → checkpoint → Revert → accept again keeps its change there;
    /// M4-RW-042).
    ///
    /// Returning: at the target the latest op is an accept with a
    /// changes-carrying accept at or before it; now the latest op is the one
    /// that took the change out — a `claudeAcceptRevert` (the writer's
    /// Revert carries the text; travel's own is status only) or a
    /// `.rewind`-stamped reopen (the return journey's before-accept arm). A
    /// writer's later Stet, reject or archive is latest instead and stands.
    /// Whether the return writes the paragraph is the caller's half
    /// (`returningAccepts`): RULING-57 applies only where the travel itself
    /// puts the text back.
    ///
    /// "At the target" means at the END of the moment the target names
    /// (`momentEnd`): a tick on a restore op includes the lines that restore
    /// wrote behind it.
    ///
    /// Sorted by annotation id. Each caller walks ONCE — `restoreToOp`,
    /// `preview`, `PartialRestorePicker.revertPlan` — and hands the result to
    /// the filters below; step 8 and its sibling act on those lists and the
    /// preview and the revert sheet count them, so promise and act cannot
    /// disagree. O(ops): the preview runs it on every scrub.
    static func travelStatusChanges(
        in ops: [Op], target targetOpId: String,
        amendments: AnnotationAmendments
    ) -> [TravelStatusChange] {
        // The moment a tick names: a restore op and the status lines that
        // same restore wrote behind it are ONE moment (`momentEnd`).
        let cut = momentEnd(of: targetOpId, in: ops)
        var latest: [String: Op] = [:], latestAtTarget: [String: Op] = [:]
        var textAccept: [String: Op] = [:], textAcceptAtTarget: [String: Op] = [:]
        func newer(_ op: Op, than held: Op?, ties: Bool) -> Bool {
            held.map { ties ? $0.opId <= op.opId : $0.opId < op.opId } ?? true
        }
        for op in ops {
            guard let src = op.provenance?.sourceAnnotationId else { continue }
            let atTarget = op.opId <= cut                   // ULID order
            if op.kind == .claudeAccept, !op.changes.isEmpty {
                if newer(op, than: textAccept[src], ties: false) { textAccept[src] = op }
                if atTarget, newer(op, than: textAcceptAtTarget[src], ties: false) {
                    textAcceptAtTarget[src] = op
                }
            }
            if AnnotationDeriver.isHonouredLifecycleOp(op, amendments: amendments) {
                if newer(op, than: latest[src], ties: true) { latest[src] = op }
                if atTarget, newer(op, than: latestAtTarget[src], ties: true) {
                    latestAtTarget[src] = op
                }
            }
        }
        let changes = latest.keys.sorted().compactMap { src -> TravelStatusChange? in
            guard let now = latest[src] else { return nil }
            // Accepted with its text at the target: the return keeps the
            // change, so there is nothing to strand — however many Reverts
            // and re-accepts came since.
            let acceptedAtTarget = latestAtTarget[src]?.kind == .claudeAccept
                && textAcceptAtTarget[src] != nil
            if now.kind == .claudeAccept, !acceptedAtTarget,
               let accept = textAccept[src], accept.opId > cut,
               let pid = accept.changes.first?.paragraphId {
                return .init(annotationId: src, class: .stranded, paragraphId: pid,
                             userResponse: nil, isWithdrawn: false)
            }
            let tookTheChangeOut = now.kind == .claudeAcceptRevert
                || (now.kind == .annotationReopen && now.provenance?.synthesisSource == .rewind)
            if tookTheChangeOut, now.opId > cut, acceptedAtTarget,
               let accept = textAcceptAtTarget[src],
               let pid = accept.changes.first?.paragraphId {
                return .init(annotationId: src, class: .returning, paragraphId: pid,
                             userResponse: accept.provenance?.userResponse, isWithdrawn: false)
            }
            return nil
        }
        guard !changes.isEmpty else { return [] }
        // The deriver's withdrawn walk, once for the whole log.
        let withdrawn = Set(AnnotationDeriver.deriveWithdrawn(
            ops: ops, amendments: amendments).map(\.id))
        return changes.map {
            .init(annotationId: $0.annotationId, class: $0.class, paragraphId: $0.paragraphId,
                  userResponse: $0.userResponse, isWithdrawn: withdrawn.contains($0.annotationId))
        }
    }

    /// **The last op of the moment `targetOpId` names.** A restore appends
    /// its restore op first and the status lines that answer it after:
    /// `restoreToOp`'s sweep archives (step 7), reopens (step 8), re-accepts
    /// (8b, 9), an undo's compensations, a checkpoint revert's
    /// `Restore.travelStatusLines`. The restore op's text already reflects
    /// the travel, so a tick on it (rewound ticks are selectable) means the
    /// moment AFTER those lines; a cut at the restore op alone reads the
    /// statuses from before the travel over text from after it.
    ///
    /// So when the target is a restore op, or one of its trailing lines, the
    /// cut extends over the run of lines that restore wrote — same device and
    /// session; another hand's op merged between is skipped. A trailing line
    /// is changes-free, of a lifecycle kind, and stamped as that restore's: `.rewind`/`.undoRewind` behind a rewind or its undo,
    /// the restore op's own `sourceCheckpoint` behind a checkpoint revert.
    /// Inside an undo's run (an `.undoRewind` restore) the task-window closer
    /// — a changes-free `.rewind` restore op with no sequence — is part of it; anywhere else a
    /// restore op starts a new moment. Decided by kind and stamp, never by
    /// text. Any other target is its own moment.
    static func momentEnd(of targetOpId: String, in ops: [Op]) -> String {
        guard let t = ops.firstIndex(where: { $0.opId == targetOpId }),
              let start = ops[...t].lastIndex(where: { $0.kind == .checkpointRestore })
        else { return targetOpId }
        let restore = ops[start]
        // Written by that same restore's hand. Another device's or session's
        // op merged into the run is skipped, never read as its end.
        func mine(_ op: Op) -> Bool {
            op.device == restore.device && op.session == restore.session
        }
        func trails(_ op: Op) -> Bool {
            guard op.changes.isEmpty else { return false }
            let source = op.provenance?.synthesisSource
            if op.kind == .checkpointRestore {
                // Only an undo's task-window closer: `.rewind`, no sequence
                // (`appendTaskRewindCloser`). A fresh marker-only rewind
                // carries its target's sequence and is its own moment.
                return source == .rewind && op.sequence == nil
                    && restore.provenance?.synthesisSource == .undoRewind
            }
            guard Document.isLifecycleOpKind(op.kind) else { return false }
            if source == .rewind || source == .undoRewind {
                return restore.provenance?.synthesisSource != nil
            }
            guard restore.provenance?.synthesisSource == nil,
                  let stamp = restore.provenance?.sourceCheckpoint else { return false }
            return op.provenance?.sourceCheckpoint == stamp
        }
        // The target is the restore op or one of its own trailing lines, with
        // nothing of its own hand between that is not; otherwise its own moment.
        // (Behind an undo's task-window closer the nearest restore op is the
        // closer, whose run is the rest of the undo's — the same end.)
        guard start == t || (mine(ops[t])
                && ops[(start + 1)...t].allSatisfy({ !mine($0) || trails($0) }))
        else { return targetOpId }
        var end = t
        for j in ops.indices.dropFirst(t + 1) where mine(ops[j]) {
            guard trails(ops[j]) else { break }
            end = j
        }
        return ops[end].opId
    }

    /// **The accepts a return strands** (RULING-28): the stranded class of
    /// one `travelStatusChanges` walk. `restoreToOp`'s step 8 acts on this
    /// list and `preview` counts it.
    static func strandedAccepts(
        _ changes: [TravelStatusChange]
    ) -> [TravelStatusChange] {
        changes.filter { $0.class == .stranded }
    }

    /// **The accepts a checkpoint revert strands** (#128 item 2): the list
    /// above, kept to the paragraphs `restoreOp` writes. A revert never
    /// removes a paragraph — it rewrites the ones whose text differs at the
    /// checkpoint and leaves the rest — so an accept on a paragraph it does
    /// not write keeps its text and stays accepted, and each one it strands is
    /// reopened, never archived. `PartialRestorePicker`'s confirm line counts
    /// this and its restore acts on it.
    static func strandedAccepts(
        _ changes: [TravelStatusChange], revertedBy restoreOp: Op
    ) -> [TravelStatusChange] {
        let written = Set(restoreOp.changes.map(\.paragraphId))
        return strandedAccepts(changes).filter { written.contains($0.paragraphId) }
    }

    /// **The suggestions a return puts back to accepted** (RULING-57,
    /// RULING-26): the returning class of one `travelStatusChanges` walk,
    /// kept to the paragraphs the return writes — `written` is
    /// `paragraphsWritten(from:to:)` for a full rewind, the restore op's
    /// changes for a checkpoint revert. `restoreToOp` acts on it beside step
    /// 8, `preview` counts it, and the partial restore does both.
    static func returningAccepts(
        _ changes: [TravelStatusChange], writing written: Set<String>
    ) -> [TravelStatusChange] {
        changes.filter { $0.class == .returning && written.contains($0.paragraphId) }
    }

    /// The paragraphs a return from `current` to `target` writes: those the
    /// target holds whose text differs now — `Restore.buildRestoreOp`'s own
    /// test, so a full rewind and a checkpoint revert ask the same question.
    static func paragraphsWritten(
        from current: Deriver.DerivedState, to target: Deriver.DerivedState
    ) -> Set<String> {
        Set(target.paragraphs.compactMap { pid, text in
            current.paragraphs[pid] == text ? nil : pid
        })
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
                + r.returnedAcceptAnnotationIds.count
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
