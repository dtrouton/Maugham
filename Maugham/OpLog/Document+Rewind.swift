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
    public func restoreToOp(opId targetOpId: String) async throws -> RewindRestoreResult {
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

        // 3. Build the restore op. `Restore.buildRestoreOp` covers the
        //    text-change case (paragraphs whose content differs and
        //    paragraphs present in target but not current). It returns nil
        //    in two situations:
        //
        //    a) target == current → genuine no-op; return early.
        //    b) target is a strict subset of current (pure deletion) →
        //       no text changes but sequence shrinks; we still need to
        //       record the restore so the sequence delta lives in the log.
        //
        //    To distinguish (a) from (b), check whether the sequences differ.
        let buildResult = Restore.buildRestoreOp(
            current: currentState,
            target: targetState,
            scope: .document,
            docId: docId,
            device: device,
            session: session,
            sourceCheckpoint: targetOpId,
            synthesisSource: .rewind)

        let baseOp: Op
        if let built = buildResult {
            baseOp = built
        } else if currentState.sequence != targetState.sequence {
            // Pure-deletion rewind: no paragraph-text change, only a
            // sequence shrink. Emit a checkpoint_restore with empty
            // `changes` so the sequence field below carries the delta.
            baseOp = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .checkpointRestore,
                changes: [],
                sequence: nil,
                provenance: .init(
                    sourceCheckpoint: targetOpId,
                    synthesisSource: .rewind))
        } else {
            // (a) Manuscript text is unchanged (target == current). Check
            // whether there are any task-lifecycle ops after `targetOpId`.
            // If so, we still need to append a `.checkpointRestore` marker so
            // `TaskDeriver` can detect the rewind boundary and exclude those
            // task ops from derivation. Without this marker, the task cache
            // would continue to reflect the post-boundary task ops even though
            // the user rewound past them.
            let taskKinds: Set<OpKind> = [
                .taskCreate, .taskStatusChange, .taskPriorityChange,
                .taskParentChange, .taskBodyEdit, .taskArchive
            ]
            let targetIdx = currentOps.firstIndex(where: { $0.opId == targetOpId })
            let hasTaskOpsAfterTarget = targetIdx.map { idx in
                currentOps.dropFirst(idx + 1).contains { taskKinds.contains($0.kind) }
            } ?? false

            guard hasTaskOpsAfterTarget else {
                // Genuine no-op: no manuscript change, no task ops to rewind.
                // `restoreOp == nil` signals "log was not extended."
                return RewindRestoreResult(
                    restoreOp: nil,
                    archivedAnnotationOpIds: [],
                    removedParagraphIds: [],
                    priorSequenceCount: priorCount,
                    newSequenceCount: newCount,
                    reopenedAnnotationOpIds: [])
            }

            // Emit a task-rewind marker checkpoint_restore with empty changes
            // and no sequence change so `TaskDeriver` can slice at this boundary.
            baseOp = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .checkpointRestore,
                changes: [],
                sequence: nil,
                provenance: .init(
                    sourceCheckpoint: targetOpId,
                    synthesisSource: .rewind))
        }

        // 4. Stamp the post-restore sequence on the op so cross-Mac merge
        //    sees the ordering change. (Deriver folds `op.sequence` whenever
        //    it's non-nil, so this is how the new ordering survives replay.)
        let stampedOp = Op(
            opId: baseOp.opId,
            docId: baseOp.docId,
            at: baseOp.at,
            device: baseOp.device,
            session: baseOp.session,
            kind: baseOp.kind,
            changes: baseOp.changes,
            sequence: targetState.sequence,
            provenance: baseOp.provenance)
        try await opStore.append(stampedOp)
        _opLogMirror.append(stampedOp)

        // 5. Update in-memory derived state to match the target.
        self.paragraphs = targetState.paragraphs
        self.sequence = targetState.sequence
        recomputeDisplayText()

        // The restore op is a manuscript mutation; annotation cache
        // staleness (priorText snapshots may no longer match) needs to
        // refresh. Setting the sticky flag isn't required — restore alone
        // doesn't create annotation ops; the sweep below does that only
        // when there are removed paragraphs with open annotations on them.
        invalidateAnnotationsCache()
        invalidateTasksCache()   // rewind changed paragraph text → re-derive inline tasks

        // 6. Schedule an autosave so the .md on disk reflects the rewind.
        autosaveScheduler.schedule(())

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
            guard lifecycleOp.kind == .claudeAccept,
                  lifecycleOp.opId > targetOpId,         // accept lies past the target (ULID order)
                  !lifecycleOp.changes.isEmpty,          // suggestion accepts only
                  let pid = lifecycleOp.changes.first?.paragraphId
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
            reopenedAnnotationOpIds: reopenedIds)
    }
}
