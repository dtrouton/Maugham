import Foundation
import MaughamCore

extension Document {

    internal static func isAnnotationOpKind(_ kind: OpKind) -> Bool {
        switch kind {
        case .claudeComment, .claudeSuggestion, .claudeQuery, .claudeCraftNote,
             .claudeAccept, .claudeReject, .claudeArchive, .claudeAcceptRevert,
             .annotationEdit, .annotationWithdraw, .annotationReopen:
            return true
        default:
            return false
        }
    }

    // MARK: - Annotation read API

    public func annotations(
        filter: AnnotationFilter = AnnotationFilter()
    ) -> [Annotation] {
        if !_annotationsCacheValid {
            rebuildAnnotationsCache()
        }
        return _annotationsCache.filter { ann in
            if let kinds = filter.kinds, !kinds.contains(ann.kind) { return false }
            if let statuses = filter.statuses, !statuses.contains(ann.status) { return false }
            if let pid = filter.paragraphId, ann.paragraphId != pid { return false }
            return true
        }
    }

    internal func invalidateAnnotationsCache() {
        _annotationsCacheValid = false
        annotationsVersion &+= 1
    }

    private func rebuildAnnotationsCache() {
        _annotationsCache = AnnotationDeriver.derive(
            ops: _opLogMirror, paragraphs: paragraphs)
        _annotationsCacheValid = true
    }

    // MARK: - Annotation mutation API

    @discardableResult
    public func addAnnotation(
        kind: AnnotationKind,
        paragraphId: String?,
        body: String,
        suggestedText: String? = nil,
        prompt: String? = nil,
        toolArgs: String? = nil,
        span: SpanAnchor? = nil,
        author: AnnotationAuthor? = nil
    ) async throws -> String {
        let opKind: OpKind = {
            switch kind {
            case .comment:         return .claudeComment
            case .suggestedChange: return .claudeSuggestion
            case .query:           return .claudeQuery
            case .craftNote:       return .claudeCraftNote
            }
        }()
        // Validate the paragraph anchor before persisting. For paragraph-
        // scoped kinds (comment/query/suggested_change), the caller must
        // supply a paragraph_id that exists in the current sequence. A
        // stale id (from an old read_document response that the caller
        // didn't refresh after the user edited) would otherwise silently
        // persist as an orphan annotation with prior_text=null — the
        // staleness check has nothing to compare against, the annotation
        // can never be acted on meaningfully, and the row clutters the
        // history with no path to recovery.
        //
        // Throws a structured tool error (MCPError.paragraphNotFound) so
        // MCP clients receive a tools/call result with isError=true and a
        // machine-readable body `{"error":"paragraph_not_found",...}`
        // rather than a generic JSON-RPC failure they surface as "Tool
        // execution failed."
        if kind != .craftNote {
            guard let pid = paragraphId else {
                throw MCPError.paragraphNotFound(
                    paragraphId: "<nil>", currentCount: sequence.count)
            }
            if !sequence.contains(pid) {
                throw MCPError.paragraphNotFound(
                    paragraphId: pid, currentCount: sequence.count)
            }
            // sequence said pid is present but paragraphs map is missing
            // the text — defensive check for an internal inconsistency
            // that shouldn't happen with current code paths but would
            // otherwise persist as a null prior_text again.
            if paragraphs[pid] == nil {
                throw MCPError.priorTextCaptureFailed(paragraphId: pid)
            }
        }
        let changes: [Op.ParagraphChange] = {
            switch kind {
            case .craftNote:
                return []
            case .suggestedChange:
                guard let pid = paragraphId else { return [] }
                // Store the BARE suggested text (so the review UI shows just the
                // replacement, not the whole resulting paragraph). The splice
                // into the span happens at ACCEPT (`acceptAnnotation`), via the
                // shared `SuggestionSplice`. The span is carried on provenance.
                return [.init(paragraphId: pid,
                              prior: paragraphs[pid],
                              next: suggestedText ?? "")]
            case .comment, .query:
                guard let pid = paragraphId else { return [] }
                let prior = paragraphs[pid]
                return [.init(paragraphId: pid, prior: prior, next: "")]
            }
        }()
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: opKind, changes: changes, sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                prompt: prompt,
                toolArgs: toolArgs,
                annotationBody: body,
                authorSourceKind: author?.sourceKind.rawValue,
                authorDisplayName: author?.displayName,
                authorCollaboratorId: author?.collaboratorId,
                spanQuote: span?.quote,
                spanPrefix: span?.prefix,
                spanSuffix: span?.suffix,
                spanPosHint: span?.posHint))
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
        return op.opId
    }

    /// Create a human-authored annotation (review toolbar / collaborator
    /// review). Thin wrapper over `addAnnotation` that stamps the provenance
    /// author as `.human` with the reviewer's display name + optional
    /// collaborator id. Span-anchored to a sub-paragraph quote when supplied.
    @discardableResult
    public func addReviewerAnnotation(
        kind: AnnotationKind,
        paragraphId: String,
        span: SpanAnchor?,
        body: String,
        suggestedText: String? = nil,
        authorName: String,
        authorId: String? = nil
    ) async throws -> String {
        try await addAnnotation(
            kind: kind,
            paragraphId: paragraphId,
            body: body,
            suggestedText: suggestedText,
            span: span,
            author: AnnotationAuthor(
                sourceKind: .human,
                displayName: authorName,
                collaboratorId: authorId))
    }

    /// Author self-service: edit YOUR OWN annotation's body (and, for a
    /// suggested change, the replacement text). Appends an `annotationEdit` op
    /// referencing the creation op via `sourceAnnotationId`; the creation op is
    /// never mutated (append-only). The deriver applies the latest edit by
    /// opId. Stamps the local human author identically to
    /// `addReviewerAnnotation` so the forensic record carries who edited it.
    ///
    /// Ownership is enforced at the UI layer (`AnnotationOwnership.isOwn`): the
    /// Edit affordance only appears on the reviewer's own rows. This method
    /// trusts that gate — there are no accounts in WF1-local.
    public func editReviewerAnnotation(
        id: String,
        newBody: String,
        newSuggestedText: String?,
        authorName: String,
        authorId: String? = nil,
        undoManager: UndoManager? = nil
    ) async throws {
        // Snapshot the pre-edit derived state BEFORE appending, so ⌘Z can
        // append a compensating edit that restores it (append-only; the edit
        // op is never mutated). Unfiltered query — the annotation may be in
        // any status. A suggestion's prior replacement rides the same bare-text
        // channel as the forward edit.
        let priorAnnotation = annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }
        let priorBody = priorAnnotation?.body ?? ""
        let priorSuggested: (paragraphId: String, prior: String?, next: String)? = {
            // Only capture a suggested-text inverse when the forward edit
            // actually changes it (newSuggestedText != nil) and the creation is
            // a suggestion — otherwise the deriver leaves the suggestion intact.
            guard newSuggestedText != nil,
                  let creation = _opLogMirror.first(where: { $0.opId == id }),
                  AnnotationKind.fromOpKind(creation.kind) == .suggestedChange,
                  let pid = creation.changes.first?.paragraphId else { return nil }
            return (paragraphId: pid,
                    prior: creation.changes.first?.prior,
                    next: priorAnnotation?.suggestedText ?? "")
        }()

        // Carry the new suggested replacement through the same channel the
        // original suggestion uses: ParagraphChange.next holds the BARE text.
        // Only attach it when the caller supplied one (editing a suggestion);
        // a nil leaves the original suggestion intact in the deriver. The splice
        // into the span happens at accept (`SuggestionSplice`), not here.
        let changes: [Op.ParagraphChange] = {
            guard let suggested = newSuggestedText,
                  let creation = _opLogMirror.first(where: { $0.opId == id }),
                  let pid = creation.changes.first?.paragraphId else { return [] }
            return [.init(paragraphId: pid,
                          prior: creation.changes.first?.prior,
                          next: suggested)]
        }()
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .annotationEdit, changes: changes, sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                annotationBody: newBody,
                sourceAnnotationId: id,
                authorSourceKind: AnnotationAuthor.SourceKind.human.rawValue,
                authorDisplayName: authorName,
                authorCollaboratorId: authorId))
        try await appendAnnotationOpInternal(op)

        // ⌘Z: undo appends a compensating edit carrying the pre-edit body (and
        // prior suggested replacement); redo re-applies the new values. These
        // ops never touch manuscript text, so no removeAllActions / coherent-
        // flag choreography (unlike accept).
        OpUndoRegistrar.register(
            undoManager, actionName: "Edit Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                let revert = AnnotationInverse.editRevertOp(
                    annotationId: id,
                    priorBody: priorBody,
                    priorSuggested: priorSuggested,
                    authorSourceKind: AnnotationAuthor.SourceKind.human.rawValue,
                    authorDisplayName: authorName,
                    authorCollaboratorId: authorId,
                    docId: doc.docId, device: doc.device, session: doc.session)
                try? await doc.appendAnnotationOpInternal(revert)
            },
            redo: { doc in
                try? await doc.editReviewerAnnotation(
                    id: id, newBody: newBody, newSuggestedText: newSuggestedText,
                    authorName: authorName, authorId: authorId, undoManager: nil)
            })
    }

    /// Author self-service: withdraw (delete) YOUR OWN annotation. Appends an
    /// `annotationWithdraw` op referencing the creation op; the deriver drops
    /// the annotation from the projection entirely. The op stays in the log
    /// (append-only / audit / rewind). Ownership gated at the UI layer.
    public func withdrawReviewerAnnotation(
        id: String,
        authorName: String,
        authorId: String? = nil,
        undoManager: UndoManager? = nil
    ) async throws {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .annotationWithdraw, changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: id,
                authorSourceKind: AnnotationAuthor.SourceKind.human.rawValue,
                authorDisplayName: authorName,
                authorCollaboratorId: authorId))
        try await appendAnnotationOpInternal(op)

        // ⌘Z: undo reopens (annotationReopen restores it to the projection);
        // redo re-withdraws.
        OpUndoRegistrar.register(
            undoManager, actionName: "Withdraw Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in try? await doc.reopenAnnotation(id: id) },
            redo: { doc in
                try? await doc.withdrawReviewerAnnotation(
                    id: id, authorName: authorName, authorId: authorId,
                    undoManager: nil)
            })
    }

    public func acceptAnnotation(
        id: String,
        userResponse: String? = nil,
        undoManager: UndoManager? = nil
    ) async throws {
        guard let creation = _opLogMirror.first(where: { $0.opId == id }),
              let kind = AnnotationKind.fromOpKind(creation.kind) else {
            return  // unknown id or non-annotation op — no-op
        }

        // Determine the changes payload. Only suggestedChange mutates the
        // manuscript on accept. The creation op stores the BARE suggested text;
        // the full paragraph is produced HERE by splicing the bare text into the
        // span (re-resolved against the CURRENT paragraph) so a one-word
        // suggestion replaces one word, not the whole paragraph. A paragraph-
        // level suggestion (no span) replaces the whole paragraph. The accept
        // op carries the resulting full paragraph as `next`, so replay
        // (`Materializer`) applies it unchanged. See `SuggestionSplice`.
        let changes: [Op.ParagraphChange] = {
            switch kind {
            case .suggestedChange:
                guard let orig = creation.changes.first else { return [] }
                let pid = orig.paragraphId
                let current = paragraphs[pid] ?? orig.prior ?? ""
                let next = SuggestionSplice.apply(
                    suggestion: orig.next ?? "",
                    span: SuggestionSplice.spanAnchor(from: creation.provenance),
                    to: current)
                return [.init(paragraphId: pid, prior: current, next: next)]
            case .comment, .query, .craftNote:
                return []
            }
        }()

        let acceptOp = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .claudeAccept,
            changes: changes,
            sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: id,
                userResponse: userResponse))
        try await opStore.append(acceptOp)
        _opLogMirror.append(acceptOp)
        _hasAnyAnnotationOps = true

        // ⌘Z contract: the buffer replace that follows this accept invalidates
        // every native typing-undo action (they reference the pre-replace text
        // storage — the ⌘Z segfault class). Clear them, then register the
        // revert action, then flag the editor's next external apply as
        // undo-coherent so it doesn't wipe the fresh registration. The clear
        // sits AFTER the async op append so clear→mutate→register is
        // contiguous — a keystroke landing during the append would otherwise
        // register a typing action the flag-preserved replace then leaves
        // stale on the stack. Skipped mid-undo/redo: NSUndoManager forbids
        // removeAllActions during undo/redo, and the stacks are coherent in
        // that flow anyway.
        if kind == .suggestedChange, let um = undoManager,
           !um.isUndoing, !um.isRedoing {
            um.removeAllActions()
        }

        // Apply manuscript mutation for suggestedChange. This is the
        // "two effects, one op" case: the same op resolves the annotation
        // AND mutates `paragraphs` + writes `_displayText`. The single-
        // observable-write rule still holds because annotationsVersion and
        // displayText are distinct surfaces driving distinct views.
        if kind == .suggestedChange, let change = changes.first {
            paragraphs[change.paragraphId] = change.next
            pending.recordChange(
                paragraphId: change.paragraphId,
                prior: change.prior, next: change.next)
            burstScheduler.recordActivity()
            autosaveScheduler.schedule(())

            if let um = undoManager {
                um.registerUndo(withTarget: self) { [weak um] doc in
                    // Nested registration runs SYNCHRONOUSLY inside undo, so
                    // NSUndoManager routes it to the REDO stack. The actual
                    // re-accept / revert hops to a task (op append is async).
                    // `[weak um]`: NSUndoManager retains the registered handler,
                    // and the handler re-registers onto `um`, so a strong capture
                    // is a retain cycle that leaks the manager (and, transitively,
                    // the Document) — XCTMemoryChecker aborts on it, and in
                    // production it strands both across the window's lifetime.
                    //
                    // Known dead-redo edge: the nested redo registers here,
                    // BEFORE the async revert's guards run — if the revert
                    // no-ops (annotation no longer .accepted, paragraph gone),
                    // the redo action would re-accept something that was never
                    // reverted. Bounded: any intervening external buffer
                    // replace clears the stack, and the re-accept itself is a
                    // legal op-log append, never a crash.
                    guard let um else { return }
                    um.registerUndo(withTarget: doc) { [weak um] d2 in
                        guard let um else { return }
                        // `[weak d2]`: the async hop must not keep a closed
                        // document alive past its window. `d2` is the live target;
                        // the handle lets tests await the re-accept's completion.
                        // Forward the ORIGINAL accept's userResponse: the redo
                        // re-accept appends a fresh claudeAccept op, and the
                        // deriver reads userResponse off the latest lifecycle op
                        // — dropping it here would erase the writer's recorded
                        // reply after ⌘Z + ⇧⌘Z.
                        d2._lastUndoWorkTask = Task.detached { [weak d2] in
                            guard let d2 else { return }
                            try? await d2.acceptAnnotation(
                                id: id, userResponse: userResponse, undoManager: um)
                        }
                    }
                    doc._lastUndoWorkTask = Task.detached { [weak doc] in
                        guard let doc else { return }
                        try? await doc.revertAcceptedAnnotation(id: id, undoManager: nil)
                    }
                }
                um.setActionName("Accept Suggestion")
                _undoCoherentApplyPending = true
            }

            recomputeDisplayText()
        }

        invalidateAnnotationsCache()
        invalidateTasksCache()   // accept may have changed paragraph text → inline tasks
    }

    /// True iff the paragraph's live text has DRIFTED since this annotation's
    /// accept — i.e. it no longer matches the latest changes-carrying
    /// `claudeAccept` op's `next` (whitespace-exact, same as the data). The
    /// Annotations pane gates its Revert button behind a confirm when true:
    /// `revertAcceptedAnnotation` restores the PRE-accept text over whatever
    /// the paragraph now holds, so a drifted revert clobbers the intervening
    /// edits (mirror of the accept path's `isStale` → staleConfirm gate).
    /// False when there's no accept op / no change / no live paragraph — the
    /// revert itself loud-no-ops those, so there's nothing to confirm.
    public func acceptedTextDrifted(annotationId: String) -> Bool {
        guard let acceptOp = _opLogMirror.last(where: {
                  $0.kind == .claudeAccept
                      && $0.provenance?.sourceAnnotationId == annotationId
              }),
              let acceptChange = acceptOp.changes.first,
              let liveText = paragraphs[acceptChange.paragraphId] else {
            return false
        }
        return liveText != (acceptChange.next ?? "")
    }

    /// Inverse of an accepted suggestion — the ⌘Z path. Appends a
    /// `claudeAcceptRevert` op carrying the restore (prior = post-accept text,
    /// next = pre-accept text) and returns the annotation to `.open`
    /// (AnnotationDeriver). Append-only: the accept op is never touched.
    ///
    /// Loud no-op (log, no throw) when the annotation isn't currently
    /// `.accepted` or its paragraph no longer exists — an undo action can
    /// outlive the state it captured (e.g. a rewind in between); never crash.
    ///
    /// `undoManager` semantics mirror `acceptAnnotation`'s: a DIRECT revert
    /// (Annotations-pane "Revert" button) passes the window's manager and gets
    /// a ⌘Z re-accept registered; the ⌘Z undo closure passes nil (its nested
    /// redo registration already covers re-accept — registering here too would
    /// double up).
    public func revertAcceptedAnnotation(
        id: String, undoManager: UndoManager? = nil
    ) async throws {
        guard let creation = _opLogMirror.first(where: { $0.opId == id }),
              AnnotationKind.fromOpKind(creation.kind) == .suggestedChange else {
            documentLog.error("revertAcceptedAnnotation: \(id, privacy: .public) is not a suggestion creation op — ignoring")
            return
        }
        // Query with an explicit status filter: `annotations()` defaults to
        // `statuses: [.open]` (AnnotationFilter), which would EXCLUDE the very
        // `.accepted` annotation we're reverting and make this a silent no-op.
        let current = annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }
        guard current?.status == .accepted else {
            documentLog.error("revertAcceptedAnnotation: \(id, privacy: .public) is not accepted (\(String(describing: current?.status), privacy: .public)) — ignoring")
            return
        }
        // Latest accept op for this annotation carries the definitive
        // prior (pre-accept) / next (post-accept) pair.
        guard let acceptOp = _opLogMirror.last(where: {
                  $0.kind == .claudeAccept
                      && $0.provenance?.sourceAnnotationId == id
              }),
              let acceptChange = acceptOp.changes.first else {
            documentLog.error("revertAcceptedAnnotation: no claudeAccept op with changes for \(id, privacy: .public) — ignoring")
            return
        }
        let pid = acceptChange.paragraphId
        guard sequence.contains(pid) else {
            documentLog.error("revertAcceptedAnnotation: paragraph \(pid, privacy: .public) no longer exists — ignoring")
            return
        }
        let currentText = paragraphs[pid] ?? ""
        let restored = acceptChange.prior ?? ""
        let change = Op.ParagraphChange(
            paragraphId: pid, prior: currentText, next: restored)

        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .claudeAcceptRevert,
            changes: [change],
            sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: id))
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true

        // Direct pane-revert: same ⌘Z contract as accept — the buffer replace
        // that follows invalidates every native typing-undo action, so clear
        // them AFTER the async append (contiguous clear→mutate→register, same
        // await-gap rationale as acceptAnnotation) and register a re-accept.
        // Skipped when called FROM the ⌘Z undo closure: that path passes
        // undoManager == nil (redo is its nested registration), and the
        // isUndoing/isRedoing guard covers a direct call landing mid-undo.
        let registerUndo = undoManager.map {
            !$0.isUndoing && !$0.isRedoing } ?? false
        if registerUndo, let um = undoManager {
            um.removeAllActions()
        }

        paragraphs[pid] = restored
        pending.recordChange(paragraphId: pid, prior: currentText, next: restored)
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())

        if registerUndo, let um = undoManager {
            // Undo of a pane-revert = re-accept, carrying the reverted accept
            // op's ORIGINAL userResponse so the writer's recorded reply
            // survives the round trip (same provenance rule as redo's
            // re-accept in acceptAnnotation). Weak-capture pattern identical
            // to accept's registration.
            let originalUserResponse = acceptOp.provenance?.userResponse
            um.registerUndo(withTarget: self) { [weak um] doc in
                guard let um else { return }
                doc._lastUndoWorkTask = Task.detached { [weak doc] in
                    guard let doc else { return }
                    try? await doc.acceptAnnotation(
                        id: id, userResponse: originalUserResponse,
                        undoManager: um)
                }
            }
            um.setActionName("Revert Suggestion")
        }

        _undoCoherentApplyPending = true
        recomputeDisplayText()

        invalidateAnnotationsCache()
        invalidateTasksCache()
    }

    public func rejectAnnotation(
        id: String, userResponse: String? = nil,
        undoManager: UndoManager? = nil
    ) async throws {
        try await appendLifecycleOp(
            kind: .claudeReject,
            sourceAnnotationId: id,
            userResponse: userResponse)

        // ⌘Z: undo reopens (annotationReopen → .open); redo re-rejects,
        // forwarding the original userResponse (fdbf12f precedent). Lifecycle
        // ops never touch manuscript text, so no coherent-flag choreography.
        OpUndoRegistrar.register(
            undoManager, actionName: "Reject Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in try? await doc.reopenAnnotation(id: id) },
            redo: { doc in
                try? await doc.rejectAnnotation(
                    id: id, userResponse: userResponse, undoManager: nil)
            })
    }

    public func archiveAnnotation(
        id: String, undoManager: UndoManager? = nil
    ) async throws {
        try await appendLifecycleOp(
            kind: .claudeArchive,
            sourceAnnotationId: id,
            userResponse: nil)

        // ⌘Z: undo reopens; redo re-archives.
        OpUndoRegistrar.register(
            undoManager, actionName: "Archive Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in try? await doc.reopenAnnotation(id: id) },
            redo: { doc in try? await doc.archiveAnnotation(id: id, undoManager: nil) })
    }

    /// Appends the compensating reopen for a rejected / archived / withdrawn
    /// annotation. Loud no-op (log + return, never throw/crash) when the current
    /// derived status no longer matches what's being undone — a stale ⌘Z after
    /// another device already acted. The reopen decision lives in the shared
    /// `AnnotationInverse` factory (cross-surface contract, tripwire 19); this
    /// method owns only the current-status query the factory is fed.
    public func reopenAnnotation(id: String) async throws {
        let current = annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }
        let undoneKind: OpKind
        switch current?.status {
        case .rejected: undoneKind = .claudeReject
        case .archived: undoneKind = .claudeArchive
        case nil:
            // Absent from the projection — withdrawn iff the latest
            // withdraw/reopen op for this id is a withdraw; otherwise the id is
            // unknown (never existed, or already reopened by another device).
            let latest = _opLogMirror
                .filter { ($0.kind == .annotationWithdraw || $0.kind == .annotationReopen)
                          && $0.provenance?.sourceAnnotationId == id }
                .max { $0.opId < $1.opId }
            guard latest?.kind == .annotationWithdraw else {
                documentLog.error("reopenAnnotation: \(id, privacy: .public) unknown or not withdrawn — ignoring")
                return
            }
            undoneKind = .annotationWithdraw
        default:
            documentLog.error("reopenAnnotation: \(id, privacy: .public) status drifted (\(String(describing: current?.status), privacy: .public)) — ignoring")
            return
        }
        guard case .op(let op) = AnnotationInverse.reopenOp(
            undoing: undoneKind, annotationId: id, currentStatus: current?.status,
            docId: docId, device: device, session: session) else {
            documentLog.error("reopenAnnotation: factory declined for \(id, privacy: .public) — ignoring")
            return
        }
        try await appendAnnotationOpInternal(op)
    }

    /// Shared tail for annotation-only ops (reopen, edit-revert): persist,
    /// mirror, mark the sticky flag, invalidate caches. Never touches manuscript
    /// text — the manuscript-mutating accept path keeps its own bespoke tail.
    internal func appendAnnotationOpInternal(_ op: Op) async throws {
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
    }

    /// Shared helper for reject/archive (and the paragraph-deletion sweep in
    /// T12, which uses `synthesisSource = "paragraph_deleted"`).
    private func appendLifecycleOp(
        kind: OpKind,
        sourceAnnotationId: String,
        userResponse: String?,
        synthesisSource: SynthesisSource? = nil
    ) async throws {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: kind, changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                synthesisSource: synthesisSource,
                sourceAnnotationId: sourceAnnotationId,
                userResponse: userResponse))
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
    }

    /// Merge a fresh sweep reason into any pending one. The merge unions
    /// the removed sets so multiple deletion paths between two
    /// `flushBurstNow` runs accumulate correctly.
    internal func flagSweep(_ reason: SweepReason) {
        if let existing = _pendingSweep {
            _pendingSweep = existing.merging(reason)
        } else {
            _pendingSweep = reason
        }
    }

    /// Auto-archive any open annotations anchored to paragraphs that the
    /// caller observed being removed. Synthesizes `claude_archive` lifecycle
    /// ops with `provenance.synthesisSource = "paragraph_deleted"` for
    /// forensic context.
    ///
    /// The `reason.removed` set is the *exact* group of paragraph ids
    /// whose annotations should be archived — not "anything not in
    /// `sequence`." This matters for transient `Document` instances loaded
    /// by `withAnnotationDocument`: their reconstructed sequence can be a
    /// strict subset of the live Document's in-memory sequence, and
    /// archiving every annotation not in the reconstruction would falsely
    /// vanish open annotations the live editor is still working on.
    ///
    /// Runs from flushBurstNow (every 30s idle / 90s max during typing)
    /// and from external-change handlers. NOT scheduled from per-keystroke
    /// paragraph mutation — see setFullText for the cycle/reentrancy
    /// rationale.
    internal func sweepOrphanedAnnotations(reason: SweepReason) async {
        if !_annotationsCacheValid {
            rebuildAnnotationsCache()
        }
        let removed = reason.removed
        let orphans = _annotationsCache.filter { ann in
            ann.status == .open
                && ann.kind != .craftNote
                && (ann.paragraphId.map { removed.contains($0) } ?? false)
        }
        for orphan in orphans {
            try? await appendLifecycleOp(
                kind: .claudeArchive,
                sourceAnnotationId: orphan.id,
                userResponse: nil,
                synthesisSource: reason.cause)
        }
        // appendLifecycleOp already invalidates the cache on each call;
        // no extra invalidation needed here.
    }
}
