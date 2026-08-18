import Foundation
import MaughamCore

/// Thrown by `Document.acceptAnnotation` when the accept must be refused.
/// RULING-5: a suggestion whose quoted phrase can no longer be found in the
/// writer's paragraph MUST NOT be applied — it is refused, the writer is told
/// why, and they may ask again. The pane catches this and says so; a caller
/// that swallows it silently is an M5-AN-050 regression.
public enum AnnotationAcceptError: Error, Equatable {
    case suggestionAnchorLost
}

extension Document {

    internal static func isAnnotationOpKind(_ kind: OpKind) -> Bool {
        switch kind {
        case .claudeComment, .claudeSuggestion, .claudeQuery, .claudeCraftNote,
             .claudeAccept, .claudeReject, .claudeArchive, .claudeAcceptRevert,
             .annotationEdit, .annotationWithdraw, .annotationReopen,
             .annotationStet, .annotationTriage:
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
        // `AnnotationFilter.matches` rather than three inline lines: the
        // project-wide snapshot (M3 P2) is derived unfiltered and its readers
        // apply the same filter, so the predicate is shared substrate.
        return _annotationsCache.filter(filter.matches)
    }

    internal func invalidateAnnotationsCache() {
        _annotationsCacheValid = false
        annotationsVersion &+= 1
    }

    /// **Tell the project this document's notes moved** (M3 P2 Task 9).
    ///
    /// `annotationsVersion` above serves every surface HOLDING this document;
    /// this serves the ones that cannot hold it — the board's open-notes column
    /// and the queue's project scope, both of which count notes in documents
    /// that are closed. `MaughamEvent.postAnnotationsChanged` owns the scope
    /// (`.project`, `opStore.projectURL` — the same root `notifyWriter` uses).
    ///
    /// **Called from the APPEND sites, deliberately not from the invalidator
    /// above.** The invalidator fires on keystroke-adjacent paths (the burst
    /// flush's sweep among them) and every receiver walks the whole project;
    /// announcing from there would put that walk on the typing path
    /// (`AnnotationChangeEventTests`, both halves).
    internal func announceAnnotationsChanged() {
        MaughamEvent.postAnnotationsChanged(
            docId: docId, projectURL: opStore.projectURL)
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
        author: AnnotationAuthor? = nil,
        /// The `ReviewPass.id` the writer was working through when this note
        /// was made (M3 P2 Task 8), or nil for a note that belongs to no pass.
        /// Defaulted so every caller that has not been taught about passes
        /// keeps writing unstamped notes rather than inventing one — and an
        /// unstamped note appears in EVERY pass's queue, so nothing is hidden
        /// by the default. Resolution is each caller's: the editor asks the
        /// window, the MCP tools ask `activeReviewPassId`, and both go through
        /// `ActivePassMemory.validatedActivePass`.
        reviewPassId: String? = nil,
        /// **Which compiler run authored this note** (M4 P1 Task 3), threaded
        /// straight onto `Op.Provenance`'s four flat scalars: the run's id, the
        /// numbered round within its pass, whether that round was read cold,
        /// and the fingerprint of the finding it came from. Four parameters
        /// rather than one value type, because the wire shape IS four flat
        /// scalars (Task 2's own decision) and a struct here would be a second
        /// spelling of them.
        ///
        /// All defaulted nil, so every caller that is not a compiler run — the
        /// review toolbar, the MCP tools, the phone — writes exactly what it
        /// wrote before.
        compilerRunId: String? = nil,
        compilerRound: Int? = nil,
        compilerFreshEyes: Bool? = nil,
        compilerFingerprint: String? = nil,
        /// **The one seam in the announce contract**, on `appendLifecycleOp`'s
        /// rule and for exactly its reason: a caller that appends N ops for ONE
        /// writer-visible event passes `false` and announces ONCE after its
        /// loop — never to skip announcing altogether. Every receiver of
        /// `.maughamAnnotationsChanged` walks the whole project, so a round
        /// minting a dozen notes posting a dozen times is a dozen project walks
        /// for a single act. Today the batching caller is the compiler's mint
        /// (`CompilerEnvironment+Project`'s `mintAnnotations`).
        /// `AnnotationChangeEventTests` polices both halves.
        announcing: Bool = true
    ) async throws -> String {
        // Owes the caller an annotation id, so it throws rather than
        // fabricating one for an annotation that was never persisted.
        // Recovery-arm only: M5-AN-048 pins craft-note creation as appending to
        // a CLOSED doc (see `rejectMutationIfReadOnlyRecovery`).
        try requireNotReadOnlyRecovery("addAnnotation")
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
                spanPosHint: span?.posHint,
                reviewPassId: reviewPassId,
                compilerRunId: compilerRunId,
                compilerRound: compilerRound,
                compilerFreshEyes: compilerFreshEyes,
                compilerFingerprint: compilerFingerprint))
        try await opStore.append(op)
        appendToMirror(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
        if announcing { announceAnnotationsChanged() }
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
        authorId: String? = nil,
        /// See `addAnnotation`'s own parameter — this wrapper only carries it.
        reviewPassId: String? = nil
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
                collaboratorId: authorId),
            reviewPassId: reviewPassId)
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
        // prior suggested replacement); redo re-invokes the forward edit with
        // the LIVE undo manager so ⇧⌘Z re-arms a fresh undo pair (accept's
        // precedent — indefinite ⌘Z/⇧⌘Z cycling). These ops never touch
        // manuscript text, so no removeAllActions / coherent-flag choreography
        // (unlike accept).
        OpUndoRegistrar.register(
            undoManager, actionName: "Edit Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                // Fire-time drift guard: only revert if the annotation still
                // shows the values THIS action wrote. A concurrent edit
                // (cross-device merge, second local edit) since registration
                // would otherwise be silently clobbered by capture-time state.
                let live = doc.annotations(filter: AnnotationFilter(statuses: nil))
                    .first { $0.id == id }
                guard let live,
                      live.body == newBody,
                      newSuggestedText == nil || live.suggestedText == newSuggestedText
                else {
                    // RULING-22 / M5-AN-019. The guard is right — it stops a
                    // concurrent edit being clobbered by capture-time state —
                    // but the Edit menu said "Undo Edit Annotation" and the
                    // writer pressed it. Declining to `documentLog` and to
                    // nobody else is the control not doing what it says.
                    documentLog.error("editReviewerAnnotation undo: \(id, privacy: .public) drifted since edit — ignoring")
                    doc.notifyWriter(
                        "Couldn't undo the annotation edit — it changed on another device.")
                    return
                }
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
            redo: { [weak undoManager] doc in
                try? await doc.editReviewerAnnotation(
                    id: id, newBody: newBody, newSuggestedText: newSuggestedText,
                    authorName: authorName, authorId: authorId,
                    undoManager: undoManager)
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
        // RULING-22 / M5-AN-036: capture the status this annotation had BEFORE
        // the withdraw, so ⌘Z can put it back. `annotationReopen` is one op
        // kind serving two inverses and `AnnotationDeriver` honours it through
        // both its passes, so the reopen that undoes a withdrawal also cancels
        // an archive or a rejection the writer made separately and never asked
        // to undo — one ⌘Z taking two of their decisions, the shape tripwire 32
        // records on the canvas. The fix is here rather than in
        // `AnnotationInverse.reopenOp`: the factory is cross-surface (tripwire
        // 19) and the phone's Reopen means "reopen this", which is exactly what
        // it does today. What differs is the UNDO's obligation, and the undo is
        // the Mac's.
        let priorStatus = annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }?.status
        let priorResponse = annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }?.userResponse
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

        // ⌘Z: undo reopens (annotationReopen restores it to the projection),
        // then puts back the resolution the withdraw was sitting on top of —
        // a status-only lifecycle op, the same shape the rewind undo's
        // re-accept uses. Undoing "delete my annotation" returns the
        // annotation, and nothing else. `.open` needs no second op; that is
        // what the reopen already leaves.
        // Redo re-withdraws with the LIVE undo manager so ⇧⌘Z re-arms a fresh
        // undo pair (accept's precedent).
        OpUndoRegistrar.register(
            undoManager, actionName: "Withdraw Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                try? await doc.reopenAnnotation(id: id)
                switch priorStatus {
                case .archived, .rejected, .accepted, .stetted:
                    // The reopen may itself have declined (a peer already
                    // reopened it, the doc husked) — re-applying the prior
                    // status regardless is still right: it is the status the
                    // writer had, and the deriver takes the latest lifecycle
                    // op either way.
                    let kind: OpKind = switch priorStatus {
                    case .archived: .claudeArchive
                    case .rejected: .claudeReject
                    case .stetted:  .annotationStet
                    default:        .claudeAccept
                    }
                    do {
                        try await doc.appendLifecycleOp(
                            kind: kind, sourceAnnotationId: id,
                            userResponse: priorResponse)
                    } catch {
                        documentLog.error("withdrawReviewerAnnotation undo: restoring the prior \(String(describing: priorStatus), privacy: .public) status for \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public) — the note is back but open")
                    }
                case .open, nil:
                    break
                }
            },
            redo: { [weak undoManager] doc in
                try? await doc.withdrawReviewerAnnotation(
                    id: id, authorName: authorName, authorId: authorId,
                    undoManager: undoManager)
            })
    }

    public func acceptAnnotation(
        id: String,
        userResponse: String? = nil,
        undoManager: UndoManager? = nil
    ) async throws {
        // Accept SPLICES the suggestion into the manuscript and appends the
        // accept op — two writes, neither reachable on a doc that must not
        // write. (It reaches `opStore.append` directly, so the funnel guards
        // below do not cover it.)
        if rejectMutationIfNotWritable("acceptAnnotation") { return }
        guard let creation = _opLogMirror.first(where: { $0.opId == id }),
              let kind = AnnotationKind.fromOpKind(creation.kind) else {
            return  // unknown id or non-annotation op — no-op
        }
        // RULING-22 / M5-AN-028: a WITHDRAWN annotation is one the writer
        // deleted, and that instruction has duration. Accepting it anyway used
        // to splice its replacement into the manuscript while the annotation
        // stayed absent from every surface — no row to notice it, no Revert to
        // reach for. The reachable path is a merge race (a second Mac's pane,
        // rendered before the withdraw arrived, still offering Accept), so the
        // guard belongs here rather than in the pane that can be stale.
        // Silent to the writer by design: on the device that clicked, nothing
        // they can see said this annotation existed.
        if isWithdrawn(annotationId: id) {
            documentLog.error("acceptAnnotation: \(id, privacy: .public) was withdrawn — refusing to rewrite the manuscript for a deleted annotation")
            return
        }

        // Determine the changes payload. Only suggestedChange mutates the
        // manuscript on accept. The creation op stores the BARE suggested text;
        // the full paragraph is produced HERE by splicing the bare text into the
        // span (re-resolved against the CURRENT paragraph) so a one-word
        // suggestion replaces one word, not the whole paragraph. A paragraph-
        // level suggestion (no span) replaces the whole paragraph. The accept
        // op carries the resulting full paragraph as `next`, so replay
        // (`Materializer`) applies it unchanged. See `SuggestionSplice`.
        //
        // A span whose quoted phrase is GONE from the current paragraph is
        // REFUSED before anything is appended (RULING-5: Maugham never guesses
        // where an AI-authored change belongs; the writer is told and may ask
        // again). This throw is the layer that actually protects the prose —
        // the pane's staleness gate is advisory and its cache can lag a typing
        // edit (M5-AN-005/050).
        let changes: [Op.ParagraphChange]
        switch kind {
        case .suggestedChange:
            guard let orig = creation.changes.first else { changes = []; break }
            let pid = orig.paragraphId
            let current = paragraphs[pid] ?? orig.prior ?? ""
            switch SuggestionSplice.attempt(
                suggestion: orig.next ?? "",
                span: SuggestionSplice.spanAnchor(from: creation.provenance),
                to: current) {
            case .applied(let next):
                changes = [.init(paragraphId: pid, prior: current, next: next)]
            case .anchorLost:
                throw AnnotationAcceptError.suggestionAnchorLost
            }
        case .comment, .query, .craftNote:
            changes = []
        }

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
        appendToMirror(acceptOp)
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

        // ⌘Z for the OTHER kinds — a comment, a query, a craft note (Denver's
        // 2026-08-18 ruling). Accepting one moves no manuscript text, so this
        // is reject's and stet's shape exactly rather than accept's: a
        // compensating reopen through `OpUndoRegistrar` (ADR 0023 — append,
        // never truncate), a fire-time re-check with a LOUD decline
        // (RULING-22), and a redo forwarding the LIVE undo manager so ⌘Z/⇧⌘Z
        // cycles indefinitely. None of the suggestion path's text choreography
        // applies (`removeAllActions`, `_undoCoherentApplyPending`): there is
        // no buffer replace here to make the native stack unsound.
        //
        // **What this fixes.** Until now these kinds registered NOTHING, so
        // after "Got it" the top of the writer's undo stack was still whatever
        // they had typed before pressing it — one ⌘Z aimed at the note took a
        // sentence instead, silently. Carried from the M3 handoff and surfaced
        // three times before it was ruled.
        if kind != .suggestedChange {
            OpUndoRegistrar.register(
                undoManager, actionName: "Accept Note", target: self,
                workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
                undo: { doc in
                    // Unfiltered query — an `.accepted` note is invisible to
                    // the default `[.open]` filter (M5-AN-002).
                    let live = doc.annotations(filter: AnnotationFilter(statuses: nil))
                        .first { $0.id == id }
                    guard live?.status == .accepted else {
                        documentLog.error("acceptAnnotation undo: \(id, privacy: .public) drifted (\(String(describing: live?.status), privacy: .public)) — ignoring")
                        doc.notifyWriter(
                            "Couldn't undo accepting the note — it changed on another device.")
                        return
                    }
                    try? await doc.reopenAcceptedTextlessAnnotation(id: id)
                },
                redo: { [weak undoManager] doc in
                    try? await doc.acceptAnnotation(
                        id: id, userResponse: userResponse, undoManager: undoManager)
                })
        }

        invalidateAnnotationsCache()
        invalidateTasksCache()   // accept may have changed paragraph text → inline tasks
        announceAnnotationsChanged()
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
        // The mirror of accept: restores the paragraph text and appends the
        // revert op. Same two writes, same refusal.
        if rejectMutationIfNotWritable("revertAcceptedAnnotation") { return }
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
        appendToMirror(op)
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
        announceAnnotationsChanged()
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
        // forwarding the original userResponse (fdbf12f precedent) AND the
        // LIVE undo manager so ⇧⌘Z re-arms a fresh undo pair (accept's
        // precedent — indefinite ⌘Z/⇧⌘Z cycling; `[weak undoManager]` because
        // NSUndoManager retains the closure). Lifecycle ops never touch
        // manuscript text, so no coherent-flag choreography.
        OpUndoRegistrar.register(
            undoManager, actionName: "Reject Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in try? await doc.reopenAnnotation(id: id) },
            redo: { [weak undoManager] doc in
                try? await doc.rejectAnnotation(
                    id: id, userResponse: userResponse, undoManager: undoManager)
            })
    }

    /// **Stet** — the fourth resolution (spec §5): the note was read,
    /// considered, and the words stand. Not an accept (nothing is applied),
    /// not a reject (nothing is refused), not an archive (it was not set aside
    /// unread) — the writer answered it, and the answer was no change.
    ///
    /// Status-only, exactly like reject and archive: no manuscript text moves,
    /// so none of accept's `removeAllActions` / `_undoCoherentApplyPending`
    /// choreography applies (ADR 0023's D1 is about undo stacks that reference
    /// pre-replace text storage; there is no replace here).
    ///
    /// Like reject, it refuses nothing on the way in: the deriver's
    /// latest-lifecycle-op-wins rule settles a stet over an earlier
    /// resolution. Which notes the queue OFFERS Stet on is the pane's business.
    public func stetAnnotation(
        id: String, userResponse: String? = nil,
        undoManager: UndoManager? = nil
    ) async throws {
        try await appendLifecycleOp(
            kind: .annotationStet,
            sourceAnnotationId: id,
            userResponse: userResponse)

        // ⌘Z: undo reopens (annotationReopen → .open); redo re-stets,
        // forwarding the original userResponse AND the LIVE undo manager so
        // ⇧⌘Z re-arms a fresh undo pair (reject's precedent — indefinite
        // ⌘Z/⇧⌘Z cycling; `[weak undoManager]` because NSUndoManager retains
        // the closure).
        OpUndoRegistrar.register(
            undoManager, actionName: "Stet Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                // Fire-time re-check with a LOUD decline (RULING-22,
                // `editReviewerAnnotation`'s shape). Reject and archive lean on
                // `reopenAnnotation`'s own drift guard, which declines to
                // `documentLog` and to nobody else; the Edit menu still read
                // "Undo Stet Annotation" and the writer pressed it. Unfiltered
                // query — a `.stetted` note is invisible to the default
                // `[.open]` filter (M5-AN-002).
                let live = doc.annotations(filter: AnnotationFilter(statuses: nil))
                    .first { $0.id == id }
                guard live?.status == .stetted else {
                    documentLog.error("stetAnnotation undo: \(id, privacy: .public) drifted (\(String(describing: live?.status), privacy: .public)) — ignoring")
                    doc.notifyWriter(
                        "Couldn't undo stetting the note — it changed on another device.")
                    return
                }
                try? await doc.reopenAnnotation(id: id)
            },
            redo: { [weak undoManager] doc in
                try? await doc.stetAnnotation(
                    id: id, userResponse: userResponse, undoManager: undoManager)
            })
    }

    public func archiveAnnotation(
        id: String, undoManager: UndoManager? = nil
    ) async throws {
        try await appendLifecycleOp(
            kind: .claudeArchive,
            sourceAnnotationId: id,
            userResponse: nil)

        // ⌘Z: undo reopens; redo re-archives with the LIVE undo manager so
        // ⇧⌘Z re-arms a fresh undo pair (accept's precedent).
        OpUndoRegistrar.register(
            undoManager, actionName: "Archive Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in try? await doc.reopenAnnotation(id: id) },
            redo: { [weak undoManager] doc in
                try? await doc.archiveAnnotation(id: id, undoManager: undoManager)
            })
    }

    // MARK: - Triage (the mark, not a resolution)

    /// **Triage** — what the writer intends to DO about a note they are still
    /// holding (spec §5): `do`, `decline`, `discuss`, or `nil` for untriaged.
    /// This is how a writer plans a pass over a queue rather than answering it
    /// note by note in arrival order.
    ///
    /// It is NOT a resolution and must never read as one. `.annotationTriage`
    /// is outside `lifecycleOpKinds` (Task 1's deriver indexes marks
    /// separately), so a mark can neither displace a resolution nor be
    /// displaced by one, and a triaged note stays exactly as open as it was.
    ///
    /// A RESOLVED note takes a mark too, deliberately: the mark is metadata,
    /// and a note the writer let stand can still be worth marking `discuss`
    /// for the conversation that follows. Refusing here would make them reopen
    /// a note they had already settled just to label it.
    ///
    /// Loud no-op when the projection does not hold the id (unknown, or
    /// withdrawn) — a mark op naming a note nobody can see would sit in the
    /// log forever marking nothing.
    public func triageAnnotation(
        id: String, mark: TriageMark?, undoManager: UndoManager? = nil
    ) async throws {
        // Unfiltered: `annotations()` defaults to `[.open]`, and a resolved
        // note is a legitimate target (M5-AN-002, the documented footgun).
        // This query is doing two jobs — the existence guard, and reading the
        // mark ⌘Z has to put back.
        let current = annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }
        guard let current else {
            documentLog.error("triageAnnotation: \(id, privacy: .public) is not in the projection — ignoring")
            return
        }
        let priorMark = current.triage

        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .annotationTriage, changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: id,
                triageMark: mark?.rawValue))
        try await appendAnnotationOpInternal(op)

        // ⌘Z: undo appends another triage carrying the mark the note had
        // BEFORE this one — not a clear. Marking `do`, changing your mind to
        // `discuss` and pressing ⌘Z must leave `do` standing; blanket-clearing
        // would take a decision the writer never asked to undo (M5-AN-036's
        // lesson in the mark's own key). `nil` is a legitimate prior state and
        // the factory writes it as one.
        //
        // Redo re-marks with the LIVE undo manager so ⇧⌘Z re-arms a fresh
        // pair (reject's precedent — indefinite cycling; `[weak undoManager]`
        // because NSUndoManager retains the closure).
        OpUndoRegistrar.register(
            undoManager, actionName: "Triage Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                // Fire-time re-check with a LOUD decline (RULING-22,
                // `stetAnnotation`'s shape): if a peer has re-marked the note
                // since, reverting would overwrite their mark with
                // capture-time state, and declining silently is the Edit menu
                // saying "Undo Triage Annotation" and doing nothing.
                let live = doc.annotations(filter: AnnotationFilter(statuses: nil))
                    .first { $0.id == id }
                guard let live, live.triage == mark else {
                    documentLog.error("triageAnnotation undo: \(id, privacy: .public) drifted (\(String(describing: live?.triage), privacy: .public)) — ignoring")
                    doc.notifyWriter(
                        "Couldn't undo the triage mark — it changed on another device.")
                    return
                }
                let revert = AnnotationInverse.triageRevertOp(
                    annotationId: id, priorMark: priorMark,
                    docId: doc.docId, device: doc.device, session: doc.session)
                try? await doc.appendAnnotationOpInternal(revert)
            },
            redo: { [weak undoManager] doc in
                try? await doc.triageAnnotation(
                    id: id, mark: mark, undoManager: undoManager)
            })
    }

    /// Appends the compensating reopen for a rejected / archived / withdrawn
    /// annotation. Loud no-op (log + return, never throw/crash) when the current
    /// derived status no longer matches what's being undone — a stale ⌘Z after
    /// another device already acted. The reopen decision lives in the shared
    /// `AnnotationInverse` factory (cross-surface contract, tripwire 19); this
    /// method owns only the current-status query the factory is fed.
    public func reopenAnnotation(id: String) async throws {
        // Decline atomically on a husked doc (whole-branch review, 2026-07-11):
        // a compound-undo hop resuming after `close()` husked must not append a
        // reopen op-side while the paired text restore no-ops (isClosed-guarded).
        // Sibling of the `appendTaskOpInternal` guard.
        if rejectMutationIfNotWritable("reopenAnnotation") { return }
        let current = annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }
        let undoneKind: OpKind
        switch current?.status {
        case .rejected: undoneKind = .claudeReject
        case .archived: undoneKind = .claudeArchive
        case .stetted:  undoneKind = .annotationStet
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

    /// The compensating reopen for an *accepted* annotation that moved no
    /// manuscript text — a comment, a query, a craft note (Denver's 2026-08-18
    /// ruling). ⌘Z's alone: `acceptAnnotation`'s registration is the only
    /// caller, and it has already re-checked the live status by the time it
    /// gets here.
    ///
    /// **Deliberately NOT folded into `reopenAnnotation(id:)`.** That verb is
    /// the annotations pane's Reopen and the phone's as well as ⌘Z's, and
    /// widening its status switch to `.accepted` would offer Reopen on an
    /// accepted *suggestion*, whose inverse must also restore the spliced
    /// prose (`revertAcceptedAnnotation`). This caller knows it is holding a
    /// textless kind; that verb's callers do not — so M5-AN-034 ("reopen acts
    /// only from .rejected, .archived and withdrawn") stays exactly as true as
    /// it was.
    ///
    /// Loud no-op rather than a throw on every refusal, `reopenAnnotation`'s
    /// contract: an undo action can outlive the state it captured.
    internal func reopenAcceptedTextlessAnnotation(id: String) async throws {
        // The husk decline, atomically — `reopenAnnotation`'s sibling guard.
        if rejectMutationIfNotWritable("reopenAcceptedTextlessAnnotation") { return }
        let current = annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }
        guard case .op(let op) = AnnotationInverse.reopenOp(
            undoing: .claudeAccept, annotationId: id, currentStatus: current?.status,
            acceptSplicedManuscriptText: false,
            docId: docId, device: device, session: session) else {
            documentLog.error("reopenAcceptedTextlessAnnotation: factory declined for \(id, privacy: .public) (status \(String(describing: current?.status), privacy: .public)) — ignoring")
            return
        }
        try await appendAnnotationOpInternal(op)
    }

    /// The Deleted view's content (RULING-34): annotations the writer
    /// withdrew, recoverable later via `reopenAnnotation`. Derived from the
    /// live mirror on each call — the list is small and the view is cold.
    public func withdrawnAnnotations() -> [AnnotationDeriver.WithdrawnAnnotation] {
        AnnotationDeriver.deriveWithdrawn(ops: _opLogMirror)
    }

    /// The pane's Reopen (RULING-29): `reopenAnnotation` wrapped in a ⌘Z pair.
    /// Undo re-applies the PRIOR resolution whole — a reject returns with its
    /// written reason, and so does a stet (RULING-31's history is the
    /// projection's job; undo's job is fidelity). Statuses without a clean
    /// prior resolution to re-apply (withdrawn) fall through to the plain
    /// reopen, un-registered.
    public func reopenAnnotation(id: String, undoManager: UndoManager?) async throws {
        let prior = annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }
        try await reopenAnnotation(id: id)
        guard let priorStatus = prior?.status,
              priorStatus == .rejected || priorStatus == .archived
                || priorStatus == .stetted else { return }
        let priorResponse = prior?.userResponse
        OpUndoRegistrar.register(
            undoManager, actionName: "Reopen Annotation", target: self,
            workTaskSink: { [weak self] in self?._lastUndoWorkTask = $0 },
            undo: { doc in
                switch priorStatus {
                case .rejected:
                    try? await doc.rejectAnnotation(id: id, userResponse: priorResponse)
                case .archived:
                    try? await doc.archiveAnnotation(id: id)
                case .stetted:
                    try? await doc.stetAnnotation(id: id, userResponse: priorResponse)
                default:
                    break
                }
            },
            redo: { [weak undoManager] doc in
                try? await doc.reopenAnnotation(id: id, undoManager: undoManager)
            })
    }

    /// Shared tail for annotation-only ops (reopen, edit-revert): persist,
    /// mirror, mark the sticky flag, invalidate caches. Never touches manuscript
    /// text — the manuscript-mutating accept path keeps its own bespoke tail.
    internal func appendAnnotationOpInternal(_ op: Op) async throws {
        // The funnel guards, so every public verb that reaches the op log
        // through it (reopen, edit-revert, withdraw…) is covered at one place
        // rather than each remembering. Recovery arm only: M5-AN-048 pins
        // withdraw and edit as appending to a CLOSED doc.
        if rejectMutationIfReadOnlyRecovery("appendAnnotationOpInternal") { return }
        try await opStore.append(op)
        appendToMirror(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
        announceAnnotationsChanged()
    }

    /// Shared helper for reject/archive (and the paragraph-deletion sweep in
    /// T12, which uses `synthesisSource = "paragraph_deleted"`).
    ///
    /// `internal` (not `private`) so `restoreToOpUndoable`'s undo closure can
    /// append a status-only re-accept (`.claudeAccept` with empty `changes`) —
    /// the deriver folds only `changes` for text, so an empty-changes accept is
    /// a pure status transition back to `.accepted`, the exact mirror of D3's
    /// empty-changes `claudeAcceptRevert` reopen.
    ///
    /// `changes` defaults to empty, which is what every writer-issued
    /// resolution passes and what "status-only" means. The one caller that
    /// supplies a payload is `repairRejectedButSplicedAnnotations` (RULING-33),
    /// whose repair reject has to be both the newest lifecycle op and the
    /// newest changes-carrying op to make status and manuscript agree.
    ///
    /// `announcing` is the one seam in the announce contract, and it exists for
    /// a caller that appends N ops for ONE writer-visible event: the deletion
    /// sweep, which archives every note orphaned by a burst of paragraph
    /// deletions. Every receiver of `.maughamAnnotationsChanged` walks the
    /// whole project, so a sweep of a dozen notes posting a dozen times is a
    /// dozen project walks for a single act. Pass `false` and announce ONCE
    /// after the loop — never to skip announcing altogether.
    /// `AnnotationChangeEventTests` polices both halves: the funnel still
    /// announces by default, and the sweep is the only site that suppresses it.
    internal func appendLifecycleOp(
        kind: OpKind,
        sourceAnnotationId: String,
        userResponse: String?,
        synthesisSource: SynthesisSource? = nil,
        changes: [Op.ParagraphChange] = [],
        announcing: Bool = true
    ) async throws {
        // The other annotation funnel (reject / archive / the deletion sweep).
        // Recovery arm only: M5-AN-048 pins archive and reject as appending to
        // a CLOSED doc.
        if rejectMutationIfReadOnlyRecovery("appendLifecycleOp") { return }
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: kind, changes: changes, sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                synthesisSource: synthesisSource,
                sourceAnnotationId: sourceAnnotationId,
                userResponse: userResponse))
        try await opStore.append(op)
        appendToMirror(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
        if announcing { announceAnnotationsChanged() }
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
        var archived = 0
        for orphan in orphans {
            do {
                // `announcing: false` — one deletion burst is ONE event to
                // every surface counting this project's notes, and each of
                // them walks the whole project to answer it. The announce is
                // batched below rather than skipped.
                try await appendLifecycleOp(
                    kind: .claudeArchive,
                    sourceAnnotationId: orphan.id,
                    userResponse: nil,
                    synthesisSource: reason.cause,
                    announcing: false)
                // RULING-32: count what was actually archived, so the summary
                // at the next burst boundary reports a number the log agrees
                // with. Incremented on SUCCESS only — a swallowed append that
                // still bumped the count would tell the writer a note went
                // away that is still open in front of them.
                _sweptSinceLastReport += 1
                archived += 1
            } catch {
                documentLog.error("sweepOrphanedAnnotations: archive append failed for \(orphan.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // appendLifecycleOp already invalidates the cache on each call;
        // no extra invalidation needed here. The announce is the one thing it
        // did NOT do, and it is owed exactly once — and only if something was
        // really archived, on the same rule as `_sweptSinceLastReport`: a
        // sweep that swallowed every append changed nothing to hear about.
        if archived > 0 { announceAnnotationsChanged() }
    }

    // MARK: - Convergence: status and manuscript may not disagree (RULING-33)

    /// True iff the writer has withdrawn (deleted) this annotation and not
    /// reopened it — i.e. it is absent from the projection by their own
    /// instruction rather than because the id is unknown. Latest-by-opId
    /// between the withdraw/reopen pair, the same rule `AnnotationDeriver`'s
    /// `withdrawState` pass uses; kept here rather than derived from
    /// `annotations()` because a withdrawn annotation has no row to read.
    internal func isWithdrawn(annotationId id: String) -> Bool {
        AnnotationDeriver.isWithdrawn(annotationId: id, in: _opLogMirror)
    }

    /// Undo the splice of an accept that a reject beat across a merge, so the
    /// note's status and the manuscript stop disagreeing (RULING-33).
    ///
    /// THE RACE, from `formal/AnnotationRace.tla`: status derives from the
    /// single latest LIFECYCLE op, text from a fold of every op's `changes`.
    /// The two never consult each other. Accept on one Mac, reject on another
    /// before it merged, reject wins the opId order — the annotation settles
    /// `rejected` and the suggestion is in the manuscript anyway. TLC calls it
    /// `NoRejectedButSpliced` and it is not transient: no amount of further
    /// syncing repairs it, because neither reject nor reopen can move text.
    ///
    /// The ruling: THE STATUS WINNER ALSO DECIDES THE TEXT. So the repair is a
    /// fresh `.claudeReject` carrying the inverse changes — one op that is
    /// both the newest lifecycle op (status stays `rejected`, and the writer's
    /// reason rides along) and the newest changes-carrying op (the text goes
    /// back). That is why `Deriver.appliesToManuscript` now admits
    /// `.claudeReject`; every reject a writer issues still carries nothing.
    ///
    /// Runs after a merge, which is the only thing that can create the state.
    /// Idempotent by construction: once the repair op is the newest
    /// changes-carrying op for the annotation, the `latestChange.kind ==
    /// .claudeAccept` test is false and it never fires again — including when
    /// both devices repair independently and the two repairs then merge, since
    /// they write identical `next` text.
    ///
    /// DECLINES, loudly, when the paragraph has drifted since the accept.
    /// Removing the suggestion then would mean writing over sentences the
    /// writer has typed on top of it, and no convergence rule is worth that
    /// (RULING-5's refusal-rather-than-guess, and the constitution's first
    /// must). The disagreement survives, visibly, with a row to act on.
    ///
    /// Does NOT recompute display text — the merge path that calls it does
    /// that once for everything, and its pure-append test wants the
    /// pre-merge `displayText` intact until then.
    @discardableResult
    internal func repairRejectedButSplicedAnnotations() async -> Int {
        var repaired = 0
        for creation in _opLogMirror
        where AnnotationKind.fromOpKind(creation.kind) == .suggestedChange {
            let id = creation.opId
            let forThis = _opLogMirror.filter {
                $0.provenance?.sourceAnnotationId == id
            }
            // The status side: latest lifecycle op wins (AnnotationDeriver).
            guard let latestLifecycle = forThis
                    .filter({ Document.isLifecycleOpKind($0.kind) })
                    .max(by: { $0.opId < $1.opId }),
                  latestLifecycle.kind == .claudeReject else { continue }
            // The text side: latest op carrying a payload for this annotation.
            // A `.claudeAcceptRevert` or an earlier repair here means the text
            // is already back and there is nothing to disagree about.
            guard let latestChange = forThis
                    .filter({ !$0.changes.isEmpty
                              && Document.isLifecycleOpKind($0.kind) })
                    .max(by: { $0.opId < $1.opId }),
                  latestChange.kind == .claudeAccept,
                  let applied = latestChange.changes.first else { continue }
            let pid = applied.paragraphId
            guard sequence.contains(pid) else {
                documentLog.error("repairRejectedButSpliced: paragraph \(pid, privacy: .public) for \(id, privacy: .public) is gone — leaving the log alone")
                continue
            }
            let live = paragraphs[pid] ?? ""
            guard live == (applied.next ?? "") else {
                documentLog.error("repairRejectedButSpliced: \(pid, privacy: .public) drifted since the accept for \(id, privacy: .public) — declining rather than writing over the writer's edit")
                continue
            }
            let restored = applied.prior ?? ""
            do {
                try await appendLifecycleOp(
                    kind: .claudeReject,
                    sourceAnnotationId: id,
                    // The winning reject's reason, carried onto the repair so
                    // the row still shows why the writer said no. Dropping it
                    // would make the repair look like a second, silent refusal.
                    userResponse: latestLifecycle.provenance?.userResponse,
                    synthesisSource: .rejectConvergence,
                    changes: [.init(paragraphId: pid, prior: live, next: restored)])
            } catch {
                documentLog.error("repairRejectedButSpliced: append failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public) — the disagreement stands")
                continue
            }
            paragraphs[pid] = restored
            // Deliberately NOT `pending.recordChange` (which the sibling
            // `revertAcceptedAnnotation` does): the repair op is already the
            // durable record of this text, so a pending entry would re-emit it
            // at the next burst as a `.typingBurst` — a change attributed to
            // the writer that the writer did not make. Crash safety is
            // unaffected for the same reason; the op is on disk before this
            // line runs. The autosave is still scheduled so the derived `.md`
            // catches up with `paragraphs`.
            autosaveScheduler.schedule(())
            repaired += 1
        }
        return repaired
    }

    /// The kinds `AnnotationDeriver` reads as lifecycle — the ops that can move
    /// an annotation's status. Mirrors its `isLifecycleKind`, which is internal
    /// to MaughamCore and so unreachable from here; the two are read together
    /// by `repairRejectedButSplicedAnnotations`, whose whole correctness is
    /// that it applies the deriver's own rule rather than a second opinion
    /// about which op wins. `AnnotationStetTests`' census binds the restatement
    /// case by case — `.annotationStet` is exactly the member one list gains
    /// and the other silently does not.
    ///
    /// `.annotationTriage` is deliberately NOT here: a triage is a MARK on a
    /// note the writer is still holding, and a mark that could displace a
    /// resolution would take notes out of the queue for being labelled.
    internal nonisolated static func isLifecycleOpKind(_ kind: OpKind) -> Bool {
        switch kind {
        case .claudeAccept, .claudeReject, .claudeArchive, .claudeAcceptRevert,
             .annotationReopen, .annotationStet:
            return true
        default:
            return false
        }
    }

    /// The same rule as a `Set`, for the two rewind sites that test membership
    /// over an op stream rather than filtering with a predicate
    /// (`RewindImpact.preview` and `restoreToOp`'s step-9 return journey).
    /// Each carried its own literal copy until M3 P2 — four spellings of one
    /// rule, none of them tested. Derived from the predicate so there is
    /// nothing left to keep in step.
    ///
    /// `nonisolated` because `RewindImpact.preview` is a pure function with no
    /// isolation of its own; an immutable `Set<OpKind>` is `Sendable`, so the
    /// only thing `Document`'s `@MainActor` would buy here is a Swift 6 error.
    internal nonisolated static let lifecycleOpKinds: Set<OpKind> =
        Set(OpKind.allCases.filter(Document.isLifecycleOpKind))
}
