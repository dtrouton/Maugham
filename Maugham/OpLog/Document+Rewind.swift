import Foundation
import MaughamCore

extension Document {

    /// Restore this document to the state it had immediately after the op
    /// with id `targetOpId` was applied. Appends a `.checkpointRestore` op
    /// with `provenance.synthesisSource = .rewind` and
    /// `provenance.sourceCheckpoint = targetOpId` (the field is overloaded
    /// for rewinds — its value is a past op_id rather than a checkpoint_id
    /// when `synthesisSource == .rewind`).
    ///
    /// Flushes any pending typing burst first so a mid-typing rewind doesn't
    /// lose the in-flight characters from the forensic log. Updates the
    /// in-memory paragraph map, sequence, and displayText to match the
    /// target state. Flags an orphan-annotation sweep with cause `.rewind`
    /// for any paragraph ids that disappeared, then flushes again so the
    /// sweep emits its `.claudeArchive` ops before this method returns.
    ///
    /// Returns a `RewindRestoreResult` carrying the restore op, the archive
    /// op ids the sweep produced, and the prior/new sequence counts so
    /// callers (the rewind modal) can render an impact summary without
    /// rummaging through the op log post-hoc.
    ///
    /// `synthesisSource` stamps the restore op's provenance. It defaults to
    /// `.rewind` — the value every existing caller (the History-Rewind modal,
    /// `TaskRewindTests`) relies on and the value `TaskDeriver` keys its
    /// rewind-window matcher on. The undo of a rewind (`restoreToOpUndoable`'s
    /// compensating restore) passes `.undoRewind` so that its restore op is
    /// deliberately INVISIBLE to `TaskDeriver` — an undo must not open a fresh
    /// task-rewind window. This parameter threads onto the restore op ONLY (the
    /// `applyRestore` call and the task-marker fallback); the orphan sweep and
    /// the stranded-accept resolution keep their fixed `.rewind` semantics.
    public func restoreToOp(
        opId targetOpId: String,
        synthesisSource: SynthesisSource = .rewind
    ) async throws -> RewindRestoreResult {
        // 1. Flush any pending burst so the rewind boundary is clean.
        try await flushBurstNow()

        // 2. Derive the current and target states from the in-memory mirror.
        let currentOps = _opLogMirror
        let currentState = Deriver.derive(ops: currentOps)
        let targetState = Deriver.derive(
            ops: currentOps,
            upTo: .atOp(opId: targetOpId, at: Date()))

        let priorCount = currentState.sequence.count
        let newCount = targetState.sequence.count
        let priorIds = Set(currentState.sequence)
        let newIds = Set(targetState.sequence)
        let removedIds = Array(priorIds.subtracting(newIds))

        // Whether the range being rewound past contains task-lifecycle ops —
        // i.e. whether a `.rewind`-stamped restore will open a `TaskDeriver`
        // rewind window. Computed up front (not just in the marker branch)
        // because the RESULT reports it either way: `restoreToOpUndoable`
        // needs it to know its undo must close the window again (fix: the
        // rewind-undo task dimension).
        let taskKinds: Set<OpKind> = [
            .taskCreate, .taskStatusChange, .taskPriorityChange,
            .taskParentChange, .taskBodyEdit, .taskArchive
        ]
        let targetIdx = currentOps.firstIndex(where: { $0.opId == targetOpId })
        let hasTaskOpsAfterTarget = targetIdx.map { idx in
            currentOps.dropFirst(idx + 1).contains { taskKinds.contains($0.kind) }
        } ?? false

        // 3. Apply the restore via the shared helper. `applyRestore` handles
        //    the text-change case (paragraphs whose content differs and
        //    paragraphs present in target but not current) AND the pure-
        //    deletion case (sequence shrinks with no text delta). It returns
        //    the appended+stamped op, or nil when `target == current` both
        //    text- and sequence-wise (nothing was appended).
        let stampedOp: Op
        if let applied = try await applyRestore(
            target: targetState,
            sourceCheckpoint: targetOpId,
            synthesisSource: synthesisSource) {
            stampedOp = applied
        } else {
            // `target == current` manuscript-wise. Check whether any task-
            // lifecycle ops lie after `targetOpId`. If so, we still need to
            // append a `.checkpointRestore` marker so `TaskDeriver` can detect
            // the rewind boundary and exclude those task ops from derivation.
            // Without this marker, the task cache would continue to reflect the
            // post-boundary task ops even though the user rewound past them.
            // This marker branch is rewind-specific (it hinges on op position,
            // which `applyRestore` doesn't know about), so it mirrors the
            // helper's stamp→append→fold tail inline rather than extending it.
            guard hasTaskOpsAfterTarget else {
                // Genuine no-op: no manuscript change, no task ops to rewind.
                // `restoreOp == nil` signals "log was not extended."
                return RewindRestoreResult(
                    restoreOp: nil,
                    archivedAnnotationOpIds: [],
                    removedParagraphIds: [],
                    priorSequenceCount: priorCount,
                    newSequenceCount: newCount,
                    reopenedAnnotationOpIds: [],
                    rewoundTaskOps: false)
            }

            // Emit a task-rewind marker checkpoint_restore with empty changes,
            // stamped with the (unchanged) target sequence so `TaskDeriver` can
            // slice at this boundary.
            let markerOp = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .checkpointRestore,
                changes: [],
                sequence: targetState.sequence,
                provenance: .init(
                    sourceCheckpoint: targetOpId,
                    synthesisSource: synthesisSource))
            try await opStore.append(markerOp)
            _opLogMirror.append(markerOp)
            self.paragraphs = targetState.paragraphs
            self.sequence = targetState.sequence
            recomputeDisplayText()
            invalidateAnnotationsCache()
            invalidateTasksCache()
            autosaveScheduler.schedule(())
            stampedOp = markerOp
        }

        // 7. Flag a sweep with cause = .rewind for removed paragraphs and
        //    flush again so the sweep runs synchronously inside this call.
        //    The sweep only emits claude_archive ops for OPEN annotations
        //    anchored to ids in `removedIds`; annotations on surviving
        //    paragraphs are untouched. Capture the op count before/after
        //    so the returned `archivedAnnotationOpIds` reflects exactly
        //    what this restore caused (and nothing the merging path
        //    accumulated incidentally).
        //
        //    Gate on `_hasAnyAnnotationOps`: when the doc has never had
        //    an annotation, `flushBurstNow` skips the entire annotation
        //    block (including the `_pendingSweep = nil` reset), so any
        //    `_pendingSweep` we'd set here would linger until the user's
        //    first annotation triggered the gate — at which point the
        //    sweep would archive against a stale removed-set captured
        //    from a long-past restore. ULID collisions are astronomically
        //    unlikely but the leak is structural. Don't flag what
        //    `flushBurstNow` won't drain.
        if !removedIds.isEmpty, _hasAnyAnnotationOps,
           let reason = SweepReason.rewind(removed: Set(removedIds)) {
            flagSweep(reason)
        }
        let beforeFlushCount = _opLogMirror.count
        try await flushBurstNow()
        let newlyAppended = _opLogMirror.dropFirst(beforeFlushCount)
        var archivedIds = newlyAppended
            .filter { op in
                op.kind == .claudeArchive
                    && op.provenance?.synthesisSource == .rewind
            }
            .map(\.opId)

        // 8. Resolve accepts stranded past the rewind target. The restore
        //    derived from the log PREFIX, so text applied by any claudeAccept
        //    AFTER `targetOpId` is already reverted — but the accept op itself
        //    survives (append-only), so the annotation would still derive
        //    `.accepted` while its change no longer exists. For each
        //    annotation whose LATEST lifecycle op is such a post-target,
        //    changes-carrying accept:
        //
        //    - paragraph SURVIVES the rewind → append a changes-free
        //      claudeAcceptRevert (status-only reopen: the restore op already
        //      carries the text) so the suggestion is actionable again.
        //    - paragraph was REMOVED by the rewind → append a claudeArchive
        //      instead (the removed-paragraph convention the step-7 sweep
        //      establishes — reopening would leave an open annotation on a
        //      nonexistent paragraph that the next sweep would archive
        //      anyway). The sweep itself can't cover this: it only archives
        //      OPEN annotations, and this one derives `.accepted`.
        var reopenedIds: [String] = []
        var strandedAcceptResolved = false
        var latestLifecycleBySource: [String: Op] = [:]
        for op in currentOps
        where [.claudeAccept, .claudeReject, .claudeArchive,
               .claudeAcceptRevert].contains(op.kind) {
            guard let src = op.provenance?.sourceAnnotationId else { continue }
            if let prior = latestLifecycleBySource[src], prior.opId > op.opId { continue }
            latestLifecycleBySource[src] = op
        }
        for (src, lifecycleOp) in latestLifecycleBySource.sorted(by: { $0.key < $1.key }) {
            // Strandedness = the latest lifecycle op is ANY `.claudeAccept` —
            // changes-carrying or STATUS-ONLY (empty changes). A status-only
            // accept exists as the undo-of-rewind's re-accept
            // (`restoreToOpUndoable`, `.undoRewind`); it stands in for the
            // text-applying accept it re-instated, so strandedness is judged
            // against the latest CHANGES-CARRYING accept for the same
            // annotation. Without this, a rewind that FOLLOWS an undo (⇧⌘Z
            // redo, or a second manual Restore to the same target) would leave
            // the annotation `.accepted` while its applied text was rewound
            // away — disagreeing with what a fresh rewind produces. For a
            // plain accept the two clauses collapse to one op (the old
            // condition exactly); accept→revert chains skip at the first
            // guard (latest isn't an accept); the removed-paragraph archive
            // branch below is untouched.
            guard lifecycleOp.kind == .claudeAccept else { continue }
            guard let textAccept = currentOps
                      .filter({ $0.kind == .claudeAccept
                                    && $0.provenance?.sourceAnnotationId == src
                                    && !$0.changes.isEmpty })
                      .max(by: { $0.opId < $1.opId }),
                  textAccept.opId > targetOpId,          // accept lies past the target (ULID order)
                  let pid = textAccept.changes.first?.paragraphId
            else { continue }
            let paragraphSurvives = newIds.contains(pid)
            let resolutionOp = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: paragraphSurvives ? .claudeAcceptRevert : .claudeArchive,
                changes: [],
                sequence: nil,
                provenance: Op.Provenance(
                    sessionId: session,
                    synthesisSource: .rewind,
                    sourceAnnotationId: src))
            try await opStore.append(resolutionOp)
            _opLogMirror.append(resolutionOp)
            strandedAcceptResolved = true
            if paragraphSurvives {
                reopenedIds.append(src)
            } else {
                archivedIds.append(resolutionOp.opId)
            }
        }
        if strandedAcceptResolved {
            _hasAnyAnnotationOps = true
            invalidateAnnotationsCache()
        }

        return RewindRestoreResult(
            restoreOp: stampedOp,
            archivedAnnotationOpIds: archivedIds,
            removedParagraphIds: removedIds,
            priorSequenceCount: priorCount,
            newSequenceCount: newCount,
            reopenedAnnotationOpIds: reopenedIds,
            rewoundTaskOps: hasTaskOpsAfterTarget)
    }

    /// Fold the document to `target` by appending a `.checkpointRestore` op
    /// and updating the in-memory derived state — the shared append/fold core
    /// of `restoreToOp`, reused by compound undos that must rebuild document
    /// state (e.g. inline-task archive undo restoring the spliced paragraph).
    ///
    /// Builds the restore op via `Restore.buildRestoreOp` (which correctly
    /// re-inserts paragraphs present in `target` but absent from the current
    /// derived state — the deleted-paragraph case), with a pure-deletion
    /// fallback when only the sequence shrank. Stamps the op with
    /// `target.sequence` so cross-Mac merge sees the ordering change, appends
    /// it to the store + mirror, folds `paragraphs`/`sequence`, recomputes
    /// `displayText`, and invalidates the annotation + task caches.
    ///
    /// Returns the stamped op, or `nil` when `target` matches the current
    /// derived state both text- and sequence-wise (nothing appended, no state
    /// change) — the caller decides whether that case still warrants a marker.
    ///
    /// Derives the current state from `_opLogMirror` on each call (cheap at
    /// user-action frequency); callers must have flushed any pending burst so
    /// the mirror reflects the live paragraph text.
    internal func applyRestore(
        target: Deriver.DerivedState,
        sourceCheckpoint: String,
        synthesisSource: SynthesisSource
    ) async throws -> Op? {
        let currentState = Deriver.derive(ops: _opLogMirror)

        let buildResult = Restore.buildRestoreOp(
            current: currentState,
            target: target,
            scope: .document,
            docId: docId,
            device: device,
            session: session,
            sourceCheckpoint: sourceCheckpoint,
            synthesisSource: synthesisSource)

        let baseOp: Op
        if let built = buildResult {
            baseOp = built
        } else if currentState.sequence != target.sequence {
            // Pure-deletion restore: no paragraph-text change, only a sequence
            // shrink. Emit a checkpoint_restore with empty `changes` so the
            // stamped `sequence` below carries the delta.
            baseOp = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .checkpointRestore,
                changes: [],
                sequence: nil,
                provenance: .init(
                    sourceCheckpoint: sourceCheckpoint,
                    synthesisSource: synthesisSource))
        } else {
            // Target matches current both text- and sequence-wise: nothing to
            // append. Signal "log was not extended."
            return nil
        }

        // Stamp the post-restore sequence on the op so cross-Mac merge sees the
        // ordering change. (Deriver folds `op.sequence` whenever it's non-nil.)
        let stampedOp = Op(
            opId: baseOp.opId,
            docId: baseOp.docId,
            at: baseOp.at,
            device: baseOp.device,
            session: baseOp.session,
            kind: baseOp.kind,
            changes: baseOp.changes,
            sequence: target.sequence,
            provenance: baseOp.provenance)
        try await opStore.append(stampedOp)
        _opLogMirror.append(stampedOp)

        // Update in-memory derived state to match the target.
        self.paragraphs = target.paragraphs
        self.sequence = target.sequence
        recomputeDisplayText()

        // The restore op is a manuscript mutation; refresh the annotation cache
        // (priorText snapshots may no longer match) and the task cache (inline
        // tasks are derived from paragraph text).
        invalidateAnnotationsCache()
        invalidateTasksCache()

        // Schedule an autosave so the .md on disk reflects the restore.
        autosaveScheduler.schedule(())

        return stampedOp
    }
}
