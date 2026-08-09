import Foundation
import MaughamCore

extension Document {

    /// Whether a paragraph-text delta touches inline-task markup. Used to
    /// gate the tasks-cache invalidation fast path so non-checkbox typing
    /// stays off the observable-write hot loop (annotation cache + sweep
    /// pay the same observation cost and are intentionally deferred to
    /// burst flush — see setFullText note for the AttributeGraph cycle /
    /// reentrant-layout history).
    ///
    /// True when either prior or next text contains a checkbox/todo
    /// marker — covers add, remove, and toggle equally. Detection is
    /// sourced from the shared `TaskMarkup.lineContainsTaskMarker`
    /// predicate (MaughamCore) — the single source of truth for what
    /// counts as task markup, so this site can't independently drift
    /// from `TaskAnchorAlignment` or `TasksPane` again.
    internal static func changeTouchesTaskMarkup(
        prior: String?, next: String?
    ) -> Bool {
        if let p = prior, TaskMarkup.lineContainsTaskMarker(p) { return true }
        if let n = next, TaskMarkup.lineContainsTaskMarker(n) { return true }
        return false
    }

    // MARK: - Task read API

    /// Project the current op log + paragraph map into the filtered task
    /// list. Same caching pattern as `annotations(filter:)`. Inline-task
    /// status is text-is-state (read from paragraph contents); pane-created
    /// task lifecycle rides the op log. See spec §6.
    public func tasks(filter: TaskFilter) -> [WriterTask] {
        if !_tasksCacheValid { rebuildTasksCache() }
        return _tasksCache.filter { task in
            guard filter.statuses.contains(task.status) else { return false }
            switch filter.scope {
            case .document(let scopeDocId):
                return task.anchor?.docId == scopeDocId
            case .project:
                return true
            }
        }
    }

    internal func invalidateTasksCache() {
        _tasksCacheValid = false
        tasksVersion &+= 1
    }

    private func rebuildTasksCache() {
        guard !_isRebuildingTasks else {
            // Re-entrancy guard: rebalance op append triggers
            // invalidateTasksCache, AND so does the .taskCreate op emitted
            // per minted anchor in this same rebuild. Both arrive during
            // an in-flight derive whose result is mathematically idempotent
            // for the next call (rebalance has well-spaced priorities, mints
            // have anchored bodies that the deriver leaves alone). Returning
            // early here is the correct outcome — the freshly invalidated
            // cache will lazily rebuild on the next external `tasks(filter:)`
            // call.
            return
        }
        _isRebuildingTasks = true
        defer { _isRebuildingTasks = false }

        let (tasks, rebalanceOps, mintedAnchors) = TaskDeriver.derive(
            ops: _opLogMirror, paragraphs: paragraphs, docId: docId)
        _tasksCache = tasks
        _tasksCacheValid = true

        // Persist minted anchors back into paragraph text so autosave writes
        // the anchored .md on the next 750ms cycle. The mutation to
        // `paragraphs` is silent: we don't invalidate the tasks cache (we
        // already have the derive result — and the next derive against the
        // newly anchored paragraphs would produce zero new mints). The
        // .taskCreate ops we emit per mint give cross-Mac merge an
        // authoritative creation timestamp + session id; appendTaskOpInternal
        // does invalidate the cache but the re-entrancy guard catches that
        // and short-circuits, which is exactly the intended behavior.
        if !mintedAnchors.isEmpty {
            applyMintedAnchors(mintedAnchors)
            for mint in mintedAnchors {
                let synth = "inline:\(docId):\(mint.anchorId)"
                let op = Op(
                    opId: ULID.generate(),
                    docId: docId, at: Date(),
                    device: device, session: session,
                    kind: .taskCreate,
                    changes: [], sequence: nil,
                    provenance: Op.Provenance(
                        sessionId: session,
                        taskId: synth,
                        taskBody: mint.body,
                        taskKind: mint.kind.rawValue))
                appendTaskOpInternal(op)
            }
            autosaveScheduler.schedule(())
        }

        // TaskDeriver returns rebalance ops with placeholder ids
        // ("rebalance_<task_id>") for determinism inside the pure projection.
        // Rewrite each to a freshly-minted ULID and append via the standard
        // path. The rebalance is mathematically idempotent (next derive
        // emits zero rebalance ops since priorities are now well-spaced),
        // so the re-invalidation triggered by the appends is harmless.
        for op in rebalanceOps {
            let standardized = op.withReplacedOpId(ULID.generate())
            appendTaskOpInternal(standardized)
        }
    }

    /// Splice freshly-minted task anchors back into paragraph text. Each
    /// `MintedAnchor` carries the paragraph id, line index, and (for
    /// Fountain inline tasks) an intra-line UTF-16 offset for the anchor
    /// span insertion point. Markdown line-style tasks get the anchor
    /// appended at end-of-line with a separating space.
    ///
    /// Mutates `paragraphs` directly and records the new text in the
    /// pending buffer so the next `typingBurst` op captures the anchored
    /// form — without this, the .md on disk would carry anchors but the
    /// op log would replay the un-anchored prior text and clobber them
    /// on reload (Deriver folds typing_burst into the paragraph map,
    /// taking precedence over disk parse). Does NOT invalidate the tasks
    /// cache; the caller — `rebuildTasksCache` — already holds the
    /// post-mint derive result.
    private func applyMintedAnchors(_ mints: [TaskDeriver.MintedAnchor]) {
        // Group by paragraph so we apply all mints to a paragraph in one
        // splice pass (line indices remain stable when we walk lines once).
        var byParagraph: [String: [TaskDeriver.MintedAnchor]] = [:]
        for mint in mints {
            byParagraph[mint.paragraphId, default: []].append(mint)
        }
        for (pid, group) in byParagraph {
            guard let current = paragraphs[pid] else { continue }
            var lines = current.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map(String.init)
            // Sort mints within a line by descending intraLineOffset so the
            // earlier insertion doesn't shift offsets for later ones on the
            // same line. Cross-line ordering doesn't matter because each
            // line is mutated independently.
            let sorted = group.sorted { a, b in
                if a.lineIndex != b.lineIndex { return a.lineIndex < b.lineIndex }
                let aOff = a.intraLineOffset ?? Int.max
                let bOff = b.intraLineOffset ?? Int.max
                return aOff > bOff
            }
            for mint in sorted {
                guard mint.lineIndex >= 0, mint.lineIndex < lines.count else {
                    continue
                }
                let comment = TaskAnchorID.formatComment(mint.anchorId)
                let line = lines[mint.lineIndex]
                if let intra = mint.intraLineOffset {
                    // Fountain inline: splice anchor at the UTF-16 offset.
                    let ns = line as NSString
                    if intra >= 0 && intra <= ns.length {
                        let head = ns.substring(with: NSRange(location: 0, length: intra))
                        let tail = ns.substring(from: intra)
                        lines[mint.lineIndex] = head + comment + tail
                    }
                } else {
                    // Markdown line-style: append at end-of-line with a space
                    // separator (matches the format the deriver expects).
                    lines[mint.lineIndex] = "\(line) \(comment)"
                }
            }
            let priorText = paragraphs[pid]
            let nextText = lines.joined(separator: "\n")
            paragraphs[pid] = nextText
            // Record into pending so the next typing_burst carries the
            // anchored form. Without this, reload-from-log replays the
            // un-anchored prior text into paragraphs and strips the anchor.
            pending.recordChange(
                paragraphId: pid, prior: priorText, next: nextText)
            burstScheduler.recordActivity()
        }
    }

    /// Sync helper for task-lifecycle and rebalance ops. Updates the
    /// in-memory mirror immediately so the next `tasks(filter:)` reflects
    /// the change without waiting for the async disk append. Fires a
    /// fire-and-forget `opStore.append` so the op also lands in
    /// `.maugham/ops/<docId>.jsonl`. JSONLAppendStore dedupes by opId, so
    /// even pathological re-entry is safe on disk.
    internal func appendTaskOpInternal(_ op: Op) {
        // Decline atomically on a husked doc (whole-branch review, 2026-07-11):
        // a compound-undo hop resuming after `close()` husked would otherwise
        // append this op-side change to a cleared mirror / disk while its text
        // side no-ops (setParagraph/applyRestore are already isClosed-guarded) —
        // a torn op log. Matches the text-side guards so both sides no-op together.
        if rejectMutationIfClosed("appendTaskOpInternal") { return }
        appendToMirror(op)
        invalidateTasksCache()
        // Annotation cache only invalidates for annotation ops — task ops
        // don't change annotation derivation, so skip the bump.
        let store = opStore
        let docId = self.docId
        // Track the detached append so `close()` can drain it before husking
        // (E1). Without the drain, a prompt quit returns from `close()` before
        // this append lands, silently reverting the task op (and any ⌘Z
        // compensating op) on relaunch, since reload derives from disk — which
        // never got the op. The in-memory mirror keeps the live UI correct; the
        // mirror-first-then-durably-appended contract is what `drainTaskAppends`
        // makes good at close.
        let token = _nextTaskAppendToken
        _nextTaskAppendToken &+= 1
        inFlightTaskAppends[token] = Task { @MainActor [weak self] in
            if let delay = Document._testDelayTaskAppends {
                try? await Task.sleep(for: delay)
            }
            // LOG (can't propagate): this detached Task outlives the sync
            // `appendTaskOpInternal`, so there's no throwing surface to bubble
            // to. A swallowed `try?` would let a task op vanish from
            // `.maugham/ops/` with no signal while the in-memory mirror claims
            // success. Surface it so the drop leaves a trace.
            do { try await store.append(op) }
            catch {
                documentLog.error(
                    "task op append failed for doc \(docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            // Self-prune so the tracking set stays near-empty in steady state
            // (touching only this dict is husk-safe).
            self?.inFlightTaskAppends[token] = nil
        }
    }

    /// Await and clear every in-flight detached task-op disk append. Called
    /// from `Document.close()` BEFORE the burst flush so each append is durable
    /// once `close()` returns (E1). Idempotent — a second call finds an empty
    /// set. `flushBurstNow` only invalidates the tasks cache (lazy rebuild), so
    /// it spawns no new task appends after this drain.
    internal func drainTaskAppends() async {
        let inflight = Array(inFlightTaskAppends.values)
        inFlightTaskAppends.removeAll()
        for task in inflight { await task.value }
    }

    // MARK: - Task mutation API

    /// Create a new pane-anchored task on this document. Returns a synthetic
    /// preview `WriterTask`; the real derived task lands via the deriver on
    /// the next `tasks(filter:)` call (and matches this preview field-for-
    /// field by construction).
    @discardableResult
    public func createPaneTask(
        body: String, parentTaskId: String?, undoManager: UndoManager? = nil
    ) -> WriterTask {
        let opId = ULID.generate()
        let priority = lowestPriorityForDoc() + 1.0
        let parentField: String? = parentTaskId
        let op = Op(
            opId: opId,
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskCreate,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: opId,
                taskBody: body,
                taskPriority: priority,
                taskParentId: parentField,
                taskKind: TaskKind.paneCreated.rawValue))
        appendTaskOpInternal(op)
        let preview = WriterTask(
            id: opId, kind: .paneCreated,
            anchor: TaskAnchor(docId: docId, paragraphId: nil),
            body: body, status: .open, priority: priority,
            parentTaskId: parentTaskId,
            createdAt: op.at,
            createdBySession: session)

        // ⌘Z: undo archives the just-created task (the create-inverse is a
        // taskArchive carrying body + kind). The `preview` IS the pre-mutation
        // snapshot — the task didn't exist before, so its post-create derived
        // form matches this by construction. Redo re-creates via the forward
        // path, which mints a NEW task id (a fresh .taskCreate op); the original
        // id stays archived. That's acceptable per the spec — undo/redo of a
        // create is create/destroy, not identity-preserving resurrection.
        if let inverse = TaskInverse.inverse(
            undoing: .taskCreate, prior: preview,
            docId: docId, device: device, session: session, sessionId: session) {
            OpUndoRegistrar.register(
                undoManager, actionName: "New Task", target: self,
                workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
                undo: { doc in
                    // Fire-time guard: only archive if the task still exists and
                    // hasn't already been archived out from under this action.
                    // Deliberately looser than the other mutators' exact-value
                    // compare: create's "forward-written value" is the task's
                    // EXISTENCE, not any one field — later status/body edits
                    // don't invalidate undoing the creation itself.
                    guard let now = doc.freshTaskSnapshot(id: opId),
                          now.status != .archived else {
                        documentLog.error("createPaneTask undo: \(opId, privacy: .public) already gone/archived — ignoring")
                        return
                    }
                    doc.appendTaskOpInternal(inverse)
                },
                redo: { [weak undoManager] doc in
                    doc.createPaneTask(
                        body: body, parentTaskId: parentTaskId, undoManager: undoManager)
                })
        }
        return preview
    }

    /// Fresh, cache-rebuilt snapshot of a task on this doc by id. Task ops carry
    /// only NEW values, so undo registration must capture the PRE-mutation task
    /// from derived state — reading `_tasksCache` raw can be stale after an
    /// earlier mutation invalidated it, so we go through `tasks(filter:)` which
    /// rebuilds on demand. Also the fire-time drift check both undo and redo use.
    private func freshTaskSnapshot(id: String) -> WriterTask? {
        tasks(filter: TaskFilter(
            scope: .document(docId: docId),
            statuses: Set(TaskStatus.allCases))).first { $0.id == id }
    }

    public func setTaskStatus(
        id: String, status: TaskStatus, undoManager: UndoManager? = nil
    ) {
        let prior = freshTaskSnapshot(id: id)
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskStatusChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskStatus: status.rawValue))
        appendTaskOpInternal(op)

        guard let prior,
              let inverse = TaskInverse.inverse(
                undoing: .taskStatusChange, prior: prior,
                docId: docId, device: device, session: session, sessionId: session)
        else { return }
        OpUndoRegistrar.register(
            undoManager, actionName: "Change Task Status", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                // Fire-time guard: only revert if the task still holds the value
                // THIS action wrote; else a concurrent change would be clobbered.
                guard let now = doc.freshTaskSnapshot(id: id), now.status == status else {
                    documentLog.error("setTaskStatus undo: \(id, privacy: .public) drifted since change — ignoring")
                    return
                }
                doc.appendTaskOpInternal(inverse)
            },
            redo: { [weak undoManager] doc in
                doc.setTaskStatus(id: id, status: status, undoManager: undoManager)
            })
    }

    public func setTaskPriority(
        id: String, priority: Double, undoManager: UndoManager? = nil
    ) {
        let prior = freshTaskSnapshot(id: id)
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskPriorityChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskPriority: priority))
        appendTaskOpInternal(op)

        guard let prior,
              let inverse = TaskInverse.inverse(
                undoing: .taskPriorityChange, prior: prior,
                docId: docId, device: device, session: session, sessionId: session)
        else { return }
        OpUndoRegistrar.register(
            undoManager, actionName: "Reorder Task", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                guard let now = doc.freshTaskSnapshot(id: id), now.priority == priority else {
                    documentLog.error("setTaskPriority undo: \(id, privacy: .public) drifted since change — ignoring")
                    return
                }
                doc.appendTaskOpInternal(inverse)
            },
            redo: { [weak undoManager] doc in
                doc.setTaskPriority(id: id, priority: priority, undoManager: undoManager)
            })
    }

    public func setTaskParent(
        id: String, parentTaskId: String?, undoManager: UndoManager? = nil
    ) {
        // "" sentinel clears parent (matches TaskDeriver convention); any
        // non-empty value sets it. The deriver maps "" → nil on read.
        let parentField = parentTaskId ?? ""
        let prior = freshTaskSnapshot(id: id)
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskParentChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskParentId: parentField))
        appendTaskOpInternal(op)

        guard let prior,
              let inverse = TaskInverse.inverse(
                undoing: .taskParentChange, prior: prior,
                docId: docId, device: device, session: session, sessionId: session)
        else { return }
        OpUndoRegistrar.register(
            undoManager, actionName: "Nest Task", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                // Compare against the sentinel-normalized new value.
                guard let now = doc.freshTaskSnapshot(id: id),
                      (now.parentTaskId ?? "") == parentField else {
                    documentLog.error("setTaskParent undo: \(id, privacy: .public) drifted since change — ignoring")
                    return
                }
                doc.appendTaskOpInternal(inverse)
            },
            redo: { [weak undoManager] doc in
                doc.setTaskParent(id: id, parentTaskId: parentTaskId, undoManager: undoManager)
            })
    }

    public func editPaneTaskBody(
        id: String, body: String, undoManager: UndoManager? = nil
    ) {
        let prior = freshTaskSnapshot(id: id)
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskBodyEdit,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskBody: body))
        appendTaskOpInternal(op)

        guard let prior,
              let inverse = TaskInverse.inverse(
                undoing: .taskBodyEdit, prior: prior,
                docId: docId, device: device, session: session, sessionId: session)
        else { return }
        OpUndoRegistrar.register(
            undoManager, actionName: "Edit Task", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                guard let now = doc.freshTaskSnapshot(id: id), now.body == body else {
                    documentLog.error("editPaneTaskBody undo: \(id, privacy: .public) drifted since edit — ignoring")
                    return
                }
                doc.appendTaskOpInternal(inverse)
            },
            redo: { [weak undoManager] doc in
                doc.editPaneTaskBody(id: id, body: body, undoManager: undoManager)
            })
    }

    /// - Parameter suppressUndoStackClear: ONLY for batch callers that have
    ///   already performed the D1 `removeAllActions` themselves, BEFORE opening
    ///   their undo group (`TasksPane.archiveAllDone`). The per-call clear below
    ///   would otherwise fire INSIDE the caller's open `beginUndoGrouping` —
    ///   `removeAllActions` inside a manual group corrupts NSUndoManager (the
    ///   T5 crash class: unbalanced group, earlier inverses erased). A batch
    ///   caller passing `true` asserts "I cleared already, contiguously before
    ///   my group opened." Single-action callers must leave the default.
    public func archiveTask(
        id: String, undoManager: UndoManager? = nil,
        suppressUndoStackClear: Bool = false
    ) {
        // Capture body + kind BEFORE archiving so the .taskArchive op
        // carries enough info for the deriver to synthesize an entry in
        // the Archived filter. Inline tasks become derive-invisible after
        // archive (the anchor is spliced out of paragraph text); without
        // this metadata they'd vanish from the pane entirely, losing the
        // audit trail. Go through the cache-rebuilding snapshot (not raw
        // `_tasksCache`) so the pre-archive status the undo-inverse needs
        // is fresh even after an earlier mutation invalidated the cache.
        let archived = freshTaskSnapshot(id: id)

        // Branch: pane-created archive is a pure op-lifecycle change (the
        // op-side status inverse fully restores it). Inline archive ALSO
        // splices anchor text out of the paragraph, so its undo is COMPOUND —
        // it must restore both the paragraph text and the open status.
        let isPaneCreated = Self.extractAnchorId(fromTaskId: id) == nil

        // Compound-undo capture (inline branch only): the pre-archive derived
        // state (for `applyRestore` to rebuild the paragraph — cheap at
        // user-action frequency, not keystroke frequency) and the op-log tip
        // BEFORE any archive op, so the undo's foreign-op guard can confirm no
        // cross-device merge advanced the doc past our own appended ops.
        let preState: Deriver.DerivedState? =
            isPaneCreated ? nil : Deriver.derive(ops: _opLogMirror)
        let preTip: String? = isPaneCreated ? nil : _opLogMirror.last?.opId
        // The full op-id SET at capture, not just the tip: the fire-time
        // foreign-op guard computes "what landed since" by id-difference. A
        // positional drop(while:)-suffix walk keyed on `preTip` was vacuously
        // satisfied (empty suffix → allSatisfy true → fail OPEN) whenever the
        // mirror had been wholesale-replaced by a cross-device sync that no
        // longer contained `preTip` (Document+ExternalChange `_opLogMirror =
        // ops`). The set makes the difference exact and lets the guard fail
        // CLOSED when `preTip` itself is gone.
        let preOpIds: Set<String>? =
            isPaneCreated ? nil : Set(_opLogMirror.map(\.opId))
        // Open annotations anchored to a paragraph the archive COLLAPSES: the
        // orphan sweep the collapse flags (fired as a side effect of the undo's
        // `flushBurstNow` below) archives them, and — unlike the rewind path —
        // nothing here would reopen them, so ⌘Z brought back text + task but
        // left the note archived (A6). Captured at the collapse site below (the
        // sweep's exact predicate) so the undo can reopen them once the
        // paragraph is restored. Mirrors `Document+RewindUndo`'s
        // `sweepArchivedAnnotationIds` reopen — the shared reopen mechanism,
        // not a parallel one.
        var sweepArchivedAnnotationIds: [String] = []

        // Emit the .taskArchive op first so the lifecycle event lands in the
        // op log even when no anchor can be located (pane-created tasks, or
        // an inline anchor that's already been spliced out of the .md).
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskArchive,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskBody: archived?.body,
                taskKind: archived?.kind.rawValue))
        appendTaskOpInternal(op)

        // --- Text splice (inline branch only) ---
        // Locate + splice the anchor out of paragraph text. Follows accept's
        // D1/D2 choreography (InlineToggleUndo is the canonical non-accept
        // example) around the buffer-affecting mutation so the compound undo
        // registration below survives the editor's next apply pass.
        var didSplice = false
        if !isPaneCreated,
           let anchorId = Self.extractAnchorId(fromTaskId: id),
           let location = locateTaskAnchor(anchorId: anchorId),
           let para = paragraphs[location.paragraphId] {
            // D1: clear stale native typing actions BEFORE mutating so
            // clear→mutate→register is contiguous (a keystroke landing between
            // would otherwise leave a stale action the flag-preserved replace
            // never clears). Skipped mid-undo/redo (NSUndoManager forbids it),
            // and skipped for batch callers that cleared before opening their
            // undo group (see the `suppressUndoStackClear` doc comment — a
            // clear inside an open manual group corrupts NSUndoManager).
            if !suppressUndoStackClear,
               let um = undoManager, !um.isUndoing, !um.isRedoing {
                um.removeAllActions()
            }
            // D2: flag the splice's editor push undo-coherent so it preserves
            // the fresh registration below instead of wiping the stack.
            _undoCoherentApplyPending = true
            let mutated = Self.spliceArchivedTask(
                from: para,
                anchorRangeInLine: location.anchorRangeInLine,
                lineIndex: location.lineIndex)
            if mutated.isEmpty {
                // Sole task in the paragraph → paragraph collapses. The sweep
                // reason carries the removed id so annotations on it archive
                // through the normal path. Snapshot those about-to-be-swept
                // annotations BEFORE the delete (the sweep's exact predicate:
                // open, non-craftNote, anchored to this paragraph) so the
                // compound undo can reopen them once the paragraph is restored.
                sweepArchivedAnnotationIds = annotations(
                    filter: AnnotationFilter(statuses: nil))
                    .filter { $0.status == .open && $0.kind != .craftNote
                              && $0.paragraphId == location.paragraphId }
                    .map(\.id)
                deleteParagraph(id: location.paragraphId)
            } else {
                setParagraph(id: location.paragraphId, text: mutated)
            }
            didSplice = true
        }

        // --- Undo registration ---
        guard let archived else { return }
        if !didSplice {
            // Op-only (Task 4) registration: pane-created archive, or an inline
            // archive whose anchor couldn't be located (already spliced out /
            // stale pane row — no manuscript text changed). ⌘Z restores the
            // pre-archive status.
            guard let inverse = TaskInverse.inverse(
                undoing: .taskArchive, prior: archived,
                docId: docId, device: device, session: session, sessionId: session)
            else { return }
            OpUndoRegistrar.register(
                undoManager, actionName: "Archive Task", target: self,
                workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
                undo: { doc in
                    // Fire-time guard: only restore if the task is still archived.
                    guard let now = doc.freshTaskSnapshot(id: id),
                          now.status == .archived else {
                        documentLog.error("archiveTask undo: \(id, privacy: .public) no longer archived — ignoring")
                        return
                    }
                    doc.appendTaskOpInternal(inverse)
                },
                redo: { [weak undoManager] doc in
                    doc.archiveTask(id: id, undoManager: undoManager)
                })
            return
        }

        // Compound (text + op) registration: the inline archive spliced the
        // paragraph, so ⌘Z must restore BOTH the text and the open status.
        OpUndoRegistrar.register(
            undoManager, actionName: "Archive Task", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                guard let preState, let preTip, let preOpIds else { return }
                // Fire-time state guard (same as the op-only branch): only
                // proceed if the task still derives `.archived`. If it was
                // reopened out from under this action between the archive and
                // ⌘Z, restoring the captured snapshot would clobber that newer
                // state — decline as a loud no-op.
                guard let now = doc.freshTaskSnapshot(id: id),
                      now.status == .archived else {
                    documentLog.error("archiveTask compound undo: \(id, privacy: .public) no longer archived — ignoring")
                    return
                }
                // Drain the splice burst so `applyRestore` derives the current
                // (post-splice) paragraph text — setParagraph/deleteParagraph
                // record into the pending buffer, not `_opLogMirror`, until a
                // flush lands them.
                try? await doc.flushBurstNow()
                // Foreign-op guard: every op that landed since the captured
                // pre-archive state must be locally ours. A cross-device merge
                // landing in the window means the doc advanced past our
                // capture, so the paragraph-rebuild would restore a stale
                // snapshot — decline as a loud no-op. FAIL CLOSED first: if
                // the captured tip is no longer IN the mirror at all, the
                // mirror was wholesale-replaced (cross-device sync,
                // Document+ExternalChange) and the capture describes a log
                // that no longer exists — decline. (The old positional
                // suffix-walk was vacuously satisfied in exactly that case.)
                guard doc._opLogMirror.contains(where: { $0.opId == preTip })
                else {
                    documentLog.error("archiveTask compound undo: \(id, privacy: .public) — pre-archive tip absent from the op-log mirror (replaced by sync?); declining")
                    return
                }
                // The actual new-op set by id-difference, not positional
                // suffix — exact even if the merge reordered ops around the
                // tip. The rebalance exemption is KIND-shaped, not
                // origin-shaped: a changes-free `.taskPriorityChange` stamped
                // with the rebalance sentinel is safe because a text restore
                // CANNOT clobber it (priority-only payload, no paragraph
                // changes) — not because it's known to be local (a peer's
                // synced-in rebalance is indistinguishable, and equally
                // unclobberable). Anything else — including a rebalance-
                // flavored op that somehow carries changes — declines loudly.
                let appended = doc._opLogMirror
                    .filter { !preOpIds.contains($0.opId) }
                guard appended.allSatisfy({
                    ($0.device == doc.device && $0.session == doc.session)
                        || ($0.kind == .taskPriorityChange
                            && $0.device == TaskDeriver.rebalanceSentinel
                            && $0.changes.isEmpty)
                }) else {
                    documentLog.error("archiveTask compound undo: \(id, privacy: .public) — foreign op advanced doc past capture, ignoring")
                    return
                }
                // 1. Restore the paragraph text (handles the deleted-paragraph
                //    case via sequence-aware re-insertion). `.undoRewind` keeps
                //    this off TaskDeriver's rewind window so the taskArchive op
                //    below stays live for the status counter. D2 flag preserves
                //    the nested redo registration through the editor push.
                //    The status counter is gated on the restore SUCCEEDING —
                //    flipping status over un-restored text would leave a
                //    partial compound (open task, spliced text).
                doc._undoCoherentApplyPending = true
                let restoreOp: Op?
                do {
                    restoreOp = try await doc.applyRestore(
                        target: preState,
                        sourceCheckpoint: preTip,
                        synthesisSource: .undoRewind)
                } catch {
                    documentLog.error("archiveTask compound undo: \(id, privacy: .public) — text restore failed (\(error.localizedDescription, privacy: .public)); declining before status flip")
                    return
                }
                guard restoreOp != nil else {
                    // The splice changed text, so nil (target == current,
                    // nothing appended) means the capture no longer describes
                    // a real delta — decline rather than half-apply.
                    documentLog.error("archiveTask compound undo: \(id, privacy: .public) — restore produced no op despite the splice; declining before status flip")
                    return
                }
                // 2. Counter the archive's status override. The deriver folds
                //    later ops over earlier, so a fresh statusChange (the
                //    archive inverse) after the taskArchive op wins → the
                //    re-derived inline task reads its pre-archive status.
                if let inverse = TaskInverse.inverse(
                    undoing: .taskArchive, prior: archived,
                    docId: doc.docId, device: doc.device,
                    session: doc.session, sessionId: doc.session) {
                    doc.appendTaskOpInternal(inverse)
                }
                // 3. Reopen each annotation the collapse's orphan sweep
                //    archived — the paragraph is back (step 1), so its notes
                //    should be too. The sweep fired as a side effect of the
                //    `flushBurstNow` above; nothing else reopens them. Same
                //    mechanism as the rewind-undo path (`Document+RewindUndo`);
                //    `reopenAnnotation` is a loud no-op if the status drifted.
                //    Empty for the rewrite branch (no paragraph was removed).
                for src in sweepArchivedAnnotationIds {
                    do { try await doc.reopenAnnotation(id: src) }
                    catch {
                        documentLog.error("archiveTask compound undo: reopen failed for sweep-archived \(src, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            },
            redo: { [weak undoManager] doc in
                // Re-enter the forward path with the LIVE manager so ⌘Z/⇧⌘Z
                // cycles indefinitely (re-splices + re-registers a fresh pair).
                doc.archiveTask(id: id, undoManager: undoManager)
            })
    }

    /// Extract the 6-char anchor id from a task synth-id of the form
    /// `inline:<docId>:<anchorId>`. Returns nil for pane-created task ids
    /// (which are bare ULIDs with no `inline:` prefix).
    internal static func extractAnchorId(fromTaskId id: String) -> String? {
        guard id.hasPrefix("inline:") else { return nil }
        // docId can itself be arbitrary, but task synth-ids always end with
        // `:<anchorId>` and anchorId never contains `:`. Trailing component.
        guard let lastColon = id.lastIndex(of: ":") else { return nil }
        let anchor = String(id[id.index(after: lastColon)...])
        return TaskAnchorID.parseComment(TaskAnchorID.formatComment(anchor))
    }

    /// Find a task anchor across all paragraphs in `paragraphs` (not just
    /// those in `sequence` — defensive against orphan paragraphs that haven't
    /// been pruned yet). Returns the (paragraphId, 0-based line index within
    /// that paragraph, NSRange of the anchor span within that line).
    internal func locateTaskAnchor(
        anchorId: String
    ) -> (paragraphId: String, lineIndex: Int, anchorRangeInLine: NSRange)? {
        let target = TaskAnchorID.formatComment(anchorId)
        // Walk in sequence order first so the result is deterministic when
        // an orphan paragraph also happens to contain the anchor.
        var visited = Set<String>()
        for pid in sequence {
            visited.insert(pid)
            if let hit = Self.locateAnchor(target, in: paragraphs[pid] ?? "") {
                return (pid, hit.lineIndex, hit.range)
            }
        }
        for (pid, text) in paragraphs where !visited.contains(pid) {
            if let hit = Self.locateAnchor(target, in: text) {
                return (pid, hit.lineIndex, hit.range)
            }
        }
        return nil
    }

    private static func locateAnchor(
        _ target: String, in paragraph: String
    ) -> (lineIndex: Int, range: NSRange)? {
        let lines = paragraph.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let ns = line as NSString
            let r = ns.range(of: target)
            if r.location != NSNotFound {
                return (idx, r)
            }
        }
        return nil
    }

    /// Splice an archived task out of its paragraph text per spec §2.7.
    ///
    /// - Line-style (`- [ ] body <!--t-XXXXXX-->`): delete the whole line +
    ///   its terminating `\n` (or the leading `\n` if last line). If only
    ///   one line existed, returns "" so the caller can collapse the
    ///   paragraph.
    /// - Inline (`[[todo: body]]<!--t-XXXXXX-->` mid-prose): splice the
    ///   bracketed segment + its anchor; collapse one adjacent whitespace
    ///   when both sides are whitespace-bordered. When only one side is
    ///   whitespace, splice the segment + that one whitespace. When neither
    ///   side is whitespace (word-glue, rare), splice only the segment.
    internal static func spliceArchivedTask(
        from paragraph: String,
        anchorRangeInLine: NSRange,
        lineIndex: Int
    ) -> String {
        let lines = paragraph.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count else { return paragraph }
        let line = lines[lineIndex]
        let ns = line as NSString

        // Decide line-style vs inline by whether the line — once stripped of
        // the anchor — matches the markdown checkbox shape. The anchor sits
        // at the very end of a line-style task: anything between `]` and
        // the anchor is whitespace + body + optional trailing space.
        let checkboxPrefix = try! NSRegularExpression(
            pattern: #"^\s*- \[(?: |x)\] "#)
        let prefixMatch = checkboxPrefix.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length))
        let anchorAtLineEnd = (anchorRangeInLine.location
            + anchorRangeInLine.length == ns.length)
        let isLineStyle: Bool = {
            guard let m = prefixMatch else { return false }
            guard anchorAtLineEnd else { return false }
            // The anchor must be the only `<!--t-…-->` span on this line for
            // line-style treatment — multiple-anchors-per-line falls through
            // to the inline splice path. (Multi-anchor lines are unusual for
            // checkbox lines but possible if a writer types one inline.)
            let countRegex = try! NSRegularExpression(
                pattern: #"<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#)
            let count = countRegex.numberOfMatches(
                in: line, range: NSRange(location: 0, length: ns.length))
            _ = m  // suppress unused-warning when count != 1
            return count == 1
        }()

        if isLineStyle {
            // Delete the entire line, plus one surrounding `\n`. Joining the
            // remaining lines with "\n" handles both:
            //   - middle / first line: leading `\n` of next line is dropped
            //     implicitly by the join.
            //   - last line: the trailing `\n` before this line is dropped
            //     because we remove the array element before joining.
            var mutated = lines
            mutated.remove(at: lineIndex)
            return mutated.joined(separator: "\n")
        }

        // Inline splice. Find the full bracketed segment + anchor span. The
        // anchor span ends at `anchorRangeInLine.upperBound`; the segment
        // start is the leftmost `[[` before the anchor whose matched
        // `[[(todo|done): …]]<!--t-XXXXXX-->` ends exactly at the anchor.
        let segmentPattern = #"\[\[(?:todo|done):\s*.*?\]\]<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#
        // swiftlint:disable:next force_try
        let segmentRegex = try! NSRegularExpression(pattern: segmentPattern)
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = segmentRegex.matches(in: line, range: fullRange)
        guard let segment = matches.first(where: { match in
            // Match ends exactly at the anchor's end → this is the bracketed
            // segment that owns the target anchor.
            match.range.location + match.range.length
                == anchorRangeInLine.location + anchorRangeInLine.length
        }) else {
            // Couldn't pair a `[[…]]` to this anchor (malformed inline; e.g.
            // glued anchor with no preceding `[[`). Conservative: drop only
            // the anchor span itself.
            let mutatedLine = ns.replacingCharacters(
                in: anchorRangeInLine, with: "")
            return Self.replaceLine(lines, at: lineIndex, with: mutatedLine)
        }

        let segRange = segment.range
        let before = segRange.location == 0
            ? ""
            : ns.substring(with: NSRange(
                location: segRange.location - 1, length: 1))
        let afterStart = segRange.location + segRange.length
        let after = afterStart >= ns.length
            ? ""
            : ns.substring(with: NSRange(location: afterStart, length: 1))
        let leftIsWS = !before.isEmpty
            && before.rangeOfCharacter(from: .whitespaces) != nil
        let rightIsWS = !after.isEmpty
            && after.rangeOfCharacter(from: .whitespaces) != nil

        var spliceStart = segRange.location
        var spliceLength = segRange.length
        if leftIsWS && rightIsWS {
            // Both sides whitespace → consume the LEADING whitespace char
            // (collapses "X _seg_ Y" to "X Y").
            spliceStart -= 1
            spliceLength += 1
        } else if leftIsWS && !rightIsWS {
            // Only left whitespace → consume it (trailing-of-paragraph case
            // "X _seg_$" → "X$").
            spliceStart -= 1
            spliceLength += 1
        } else if !leftIsWS && rightIsWS {
            // Only right whitespace → consume it (start-of-paragraph case
            // "^_seg_ X" → "X").
            spliceLength += 1
        }
        // else: neither side whitespace (word-glue) → splice only the segment

        let spliceRange = NSRange(location: spliceStart, length: spliceLength)
        let mutatedLine = ns.replacingCharacters(in: spliceRange, with: "")
        return Self.replaceLine(lines, at: lineIndex, with: mutatedLine)
    }

    private static func replaceLine(
        _ lines: [String], at index: Int, with newLine: String
    ) -> String {
        var mutated = lines
        mutated[index] = newLine
        return mutated.joined(separator: "\n")
    }

    /// Lowest priority across the doc's currently-derived tasks. Pane-created
    /// tasks get `lowest + 1.0` so they land at the head of the list (the
    /// user's most-recent-first reading default). Returns 0.0 when there are
    /// no tasks yet.
    private func lowestPriorityForDoc() -> Double {
        // Use the cached projection; build it if necessary.
        if !_tasksCacheValid { rebuildTasksCache() }
        let priorities = _tasksCache
            .filter { $0.anchor?.docId == docId }
            .map(\.priority)
        return priorities.min() ?? 0.0
    }
}
