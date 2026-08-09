import AppKit
import MaughamCore

extension Document {

    /// `restoreToOp` wrapped in a single grouped ⌘Z action that reverses the
    /// WHOLE rewind: text back to the pre-restore tip, each D3-reopened accept
    /// re-accepted (status-only, preserving each original `userResponse`), and
    /// each sweep-archived annotation reopened. Redo re-runs `restoreToOp` from
    /// scratch so it can never disagree with a fresh rewind.
    ///
    /// Choreography follows the manuscript-text-apply pattern (accept /
    /// InlineToggleUndo): a restore replaces the editor buffer, which makes any
    /// stale native typing-undo actions unsound — so `removeAllActions` clears
    /// them first, `_undoCoherentApplyPending` keeps the flag-preserved apply
    /// from wiping the fresh registration, and the registration lands after the
    /// mutation (clear → mutate → register, contiguous).
    ///
    /// The compensating restore is stamped `.undoRewind`, NOT `.rewind`, so it
    /// is invisible to `TaskDeriver`'s rewind-window matcher — an undo must not
    /// open a fresh task-rewind window (that distinction is load-bearing).
    /// When the ORIGINAL rewind opened a task window (`result.rewoundTaskOps`),
    /// the undo instead CLOSES it: it appends a `.rewind`-flavored task marker
    /// keyed on the original rewind op (`appendTaskRewindCloser`) so the
    /// deriver's window moves past the previously-excluded task ops and they
    /// fold back in. This also gives the marker-only rewind (text unchanged,
    /// task ops rewound) a real undo instead of a do-nothing registration.
    @discardableResult
    public func restoreToOpUndoable(
        opId targetOpId: String, undoManager: UndoManager?
    ) async throws -> RewindRestoreResult {
        // — capture BEFORE the restore —
        // The pre-restore tip: undoing the rewind restores forward to here.
        let preTip = currentFoldBasis
        // Pre-restore paragraphs: tells the undo whether the original restore
        // changed text at all, so it can demand a real compensating restore op
        // when one is expected (and tolerate a nil one when it isn't — the
        // marker-only task-window rewind).
        let preParagraphs = paragraphs
        // The original userResponse per accepted suggestion, keyed by its
        // creation-op id — so the undo's status-only re-accept preserves the
        // writer's recorded reply across ⌘Z.
        var acceptResponses: [String: String?] = [:]
        for op in _opLogMirror where op.kind == .claudeAccept {
            if let src = op.provenance?.sourceAnnotationId {
                acceptResponses[src] = op.provenance?.userResponse
            }
        }

        // RULING-37: an action that changes nothing costs nothing. Before the
        // destructive clear below, establish whether this restore would be a
        // genuine no-op — no text delta, no task window to move. The burst is
        // flushed first so the answer is computed against the live text
        // (restoreToOp re-flushes; flushBurstNow is idempotent), and the
        // clear→mutate→register contiguity for the REAL-change path is
        // untouched: the guard runs entirely before the clear, and a keystroke
        // landing during ITS await merely re-runs the derive inside
        // restoreToOp as before.
        try await flushBurstNow()
        var precomputedResult: RewindRestoreResult?
        if restoreWouldBeGenuineNoOp(targetOpId: targetOpId) {
            let r = try await restoreToOp(opId: targetOpId)
            if r.restoreOp == nil { return r }
            // The prediction raced a keystroke that landed inside the await
            // and turned the no-op real (branch review). Register the undo
            // below WITHOUT the stack clear — clearing now would eat the very
            // keystroke that caused the race; stale native actions above the
            // registration are the lesser harm than an unregistered restore.
            documentLog.error("restoreToOpUndoable: no-op prediction raced a keystroke — registering without the clear")
            precomputedResult = r
        }

        // D1: drop stale native typing actions BEFORE the buffer-replacing
        // restore (clear → mutate → register, contiguous — accept's ordering).
        // Skipped mid-undo/redo (NSUndoManager forbids removeAllActions there).
        if precomputedResult == nil, let um = undoManager, !um.isUndoing, !um.isRedoing {
            um.removeAllActions()
        }
        // D2: flag the apply undo-coherent so the editor's flag-preserved
        // buffer replace doesn't wipe the registration below.
        _undoCoherentApplyPending = true

        let result: RewindRestoreResult
        if let precomputedResult {
            result = precomputedResult
        } else {
            result = try await restoreToOp(opId: targetOpId)
        }
        // Nothing was appended (genuine no-op) — no state changed, so there is
        // nothing to reverse; skip the registration entirely. Note this is
        // NOT the marker-only rewind: a text-unchanged rewind past task ops
        // returns a non-nil marker restoreOp, and its undo has real work (it
        // reverses the task window below). `preTip` nil only on an empty log
        // (never here).
        guard let originalRestoreOp = result.restoreOp, let preTip else { return result }

        // The task dimension: a `.rewind`-stamped restore whose rewound range
        // contained task ops opened a `TaskDeriver` rewind window that
        // excludes them. The compensating `.undoRewind` restore is invisible
        // to TaskDeriver (correct — an undo must not open a NEW window), but
        // nothing would close the ORIGINAL one — so after ⌘Z, text and
        // annotations returned while pane-task ops rewound past the target
        // stayed excluded. The undo therefore ALSO appends a `.rewind`-
        // flavored task marker whose `sourceCheckpoint` is THIS restore op's
        // id: the deriver keys its window on that newer marker, whose target
        // position (the original rewind op) lies AFTER the previously-excluded
        // task ops, so they fold back in. Redo re-runs `restoreToOp` from
        // scratch, whose fresh `.rewind` marker re-excludes them.
        let hadTaskWindow = result.rewoundTaskOps
        let originalRewindOpId = originalRestoreOp.opId

        // — capture AFTER the restore (for the fire-time guard + the undo work) —
        let postParagraphs = paragraphs
        let restoreChangedText = preParagraphs != postParagraphs
        // Creation ids of accepts the restore reopened (status → .open) on
        // SURVIVING paragraphs: the undo re-accepts these status-only.
        let reopened = result.reopenedAnnotationOpIds
        // `archivedAnnotationOpIds` are appended `claudeArchive` OP ids; resolve
        // each back to its annotation (creation) id so the undo can reopen it.
        let sweepArchivedAnnotationIds: [String] = result.archivedAnnotationOpIds.compactMap { aid in
            _opLogMirror.first(where: { $0.opId == aid })?.provenance?.sourceAnnotationId
        }

        OpUndoRegistrar.register(
            undoManager, actionName: "Restore from History", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                // Fire-time guard: the live text must still equal the
                // post-restore state. Native typing actions above us already
                // unwound; anything else — a cross-device merge — means decline
                // (History Rewind is the tool for that tangle), never clobber.
                guard doc.paragraphs == postParagraphs else {
                    documentLog.error("restoreToOpUndoable undo: text drifted since restore — ignoring")
                    return
                }
                // Buffer swap runs mid-undo: the clear is both forbidden and
                // unnecessary here (accept's revert-from-⌘Z precedent). Flag
                // keeps the apply's fresh registration alive.
                doc._undoCoherentApplyPending = true
                // Compensating restore FORWARD to the pre-rewind tip, stamped
                // `.undoRewind` so it never opens a task-rewind window.
                //
                // Gate the lifecycle compensations on this restore SUCCEEDING
                // (inline-archive-sibling shape): a swallowed throw here used
                // to fall through to the status-only re-accepts below, leaving
                // the stranded-accept state (annotation derives `.accepted`
                // while its applied text stays rewound) on a plain I/O failure.
                let compensating: RewindRestoreResult
                do {
                    compensating = try await doc.restoreToOp(
                        opId: preTip, synthesisSource: .undoRewind)
                } catch {
                    documentLog.error("restoreToOpUndoable undo: compensating restore failed (\(error.localizedDescription, privacy: .public)) — declining before any lifecycle re-accept")
                    return
                }
                if restoreChangedText && compensating.restoreOp == nil {
                    // The original rewind changed text, so its undo MUST have
                    // appended a restore op; nil means the log/derive no longer
                    // matches the capture — decline before half-applying.
                    documentLog.error("restoreToOpUndoable undo: compensating restore appended nothing despite an expected text delta — declining before any lifecycle re-accept")
                    return
                }
                // Close the original task-rewind window (see the capture-site
                // comment): the previously-excluded task ops fold back into
                // the derive. Gated on restore success like the re-accepts —
                // a task window closed over un-restored text would be its own
                // partial compound.
                if hadTaskWindow {
                    do {
                        try await doc.appendTaskRewindCloser(
                            originalRewindOpId: originalRewindOpId)
                    } catch {
                        documentLog.error("restoreToOpUndoable undo: task-window closer append failed (\(error.localizedDescription, privacy: .public)) — pane tasks stay rewound")
                    }
                }
                // Re-accept each reopened suggestion status-only (empty changes;
                // the restore above already carries the text), preserving the
                // original userResponse. Append failures are loud (never silent
                // `try?` — a dropped re-accept leaves a reopened row whose text
                // is already re-applied).
                for src in reopened {
                    do {
                        try await doc.appendLifecycleOp(
                            kind: .claudeAccept,
                            sourceAnnotationId: src,
                            userResponse: acceptResponses[src] ?? nil,
                            synthesisSource: .undoRewind)
                    } catch {
                        documentLog.error("restoreToOpUndoable undo: status-only re-accept failed for \(src, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Reopen each sweep-archived annotation (its paragraph is back).
                for src in sweepArchivedAnnotationIds {
                    do { try await doc.reopenAnnotation(id: src) }
                    catch {
                        documentLog.error("restoreToOpUndoable undo: reopen failed for sweep-archived \(src, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            },
            redo: { [weak undoManager] doc in
                // Re-arm through the forward path, forwarding the LIVE manager
                // so ⌘Z/⇧⌘Z cycles indefinitely (never nil — the T3 dead-cycle
                // regression). A fresh restore, never a replay.
                _ = try? await doc.restoreToOpUndoable(
                    opId: targetOpId, undoManager: undoManager)
            })
        return result
    }

    /// Append the `.rewind`-flavored task marker that CLOSES the task-rewind
    /// window an earlier restore opened. `TaskDeriver` keys its window on the
    /// LAST `.rewind`-stamped `.checkpointRestore`; this marker's
    /// `sourceCheckpoint` is the ORIGINAL rewind op's id, so the new window is
    /// (original rewind op, this marker) — which contains no task ops, while
    /// everything up to and including the original rewind op (the previously-
    /// excluded task ops among it) folds back into the derive's prefix.
    ///
    /// Text-inert by construction: empty `changes`, nil `sequence` — the text
    /// `Deriver` folds nothing from it, on this device or after a cross-Mac
    /// merge. Append-only (nothing is truncated; the excluded ops were always
    /// in the log — this only moves the deriver's window).
    internal func appendTaskRewindCloser(originalRewindOpId: String) async throws {
        let marker = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .checkpointRestore,
            changes: [], sequence: nil,
            provenance: .init(
                sourceCheckpoint: originalRewindOpId,
                synthesisSource: .rewind))
        try await opStore.append(marker)
        appendToMirror(marker)
        invalidateTasksCache()
    }
}
